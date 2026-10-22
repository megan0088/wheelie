// SPIKE — throwaway. Prototipe alur desain "Dari": Jelajah → Detail tempat → Pratinjau rute → Navigasi
// → Detail hambatan → Kontribusi.
// Data tempat dari OSM/situs resmi; rating, ulasan, dan foto TIDAK dikarang — tampil kosong bila belum ada.

import SwiftUI
import MapKit
import AVFoundation
import Combine
import PhotosUI

// MARK: - Model

@Observable
final class AppModel {
    let conditions = ConditionStore(graph: WorldData.bsd.graph)
    let location = LocationService(origin: WorldData.bsd.origin)
    let reviews = ReviewStore()
    private(set) var saved: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "tersimpan") ?? [])

    static let graph = WorldData.bsd.graph
    static let demoStart = SIMD2(WorldData.bsd.route[0][0], WorldData.bsd.route[0][1])
    private static let origin = (lat: WorldData.bsd.origin[0], lon: WorldData.bsd.origin[1])

    func toggleSave(_ p: Place) {
        if saved.contains(p.name) { saved.remove(p.name) } else { saved.insert(p.name) }
        UserDefaults.standard.set(Array(saved), forKey: "tersimpan")
    }

    /// Posisi pengguna untuk routing: GPS kalau berada di area GOP, selain itu titik demo (BSD Marketing Office).
    /// GPS asli dipakai kalau posisi berada di area peta (dengan kelonggaran 300 m). Tidak ada titik demo/simulasi.
    var gpsInArea: Bool {
        guard let p = location.local else { return false }
        let s = WorldData.bsd.snapshot, m: Float = 300
        return p.x > s.min[0] - m && p.x < s.max[0] + m && p.y > s.min[1] - m && p.y < s.max[1] + m
    }
    /// Untuk menghitung jarak di daftar. Sebelum GPS didapat, jarak dihitung dari pusat area.
    var userPoint: SIMD2<Float> { location.local ?? Self.demoStart }
    var userLabel: String {
        if gpsInArea { return "Lokasi Saya" }
        return location.local == nil ? "Menunggu lokasi GPS…" : "Anda di luar area peta"
    }

    static func coordinate(_ p: SIMD2<Float>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.lat - Double(p.y) / 110_540,
                               longitude: origin.lon + Double(p.x) / (111_320 * cos(origin.lat * .pi / 180)))
    }
    static func coordinate(_ p: SIMD3<Float>) -> CLLocationCoordinate2D { coordinate(SIMD2(p.x, p.z)) }

    /// Jarak dari GPS asli; nil sebelum GPS didapat (jangan tampilkan jarak dari titik demo).
    func distanceText(to place: Place) -> String? {
        guard let here = location.local else { return nil }
        let m = simd_distance(place.point, here)
        return m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m)) m"
    }
}

enum Category: String, CaseIterable, Identifiable {
    case kuliner = "Kuliner", belanja = "Belanja", rekreasi = "Rekreasi", kesehatan = "Kesehatan", ibadah = "Ibadah", transportasi = "Transportasi", fasilitas = "Fasilitas"
    var id: String { rawValue }
    var kinds: Set<String> {
        switch self {
        case .kuliner: ["Kafe", "Restoran"]
        case .belanja: ["Toko", "Mall", "Mall terbuka", "Supermarket", "Toko buku"]
        case .rekreasi: ["Taman", "Gedung pameran", "Hotel", "Barbershop", "Kampus", "Museum"]
        case .kesehatan: ["Rumah sakit", "Apotek"]
        case .ibadah: ["Tempat ibadah"]
        case .transportasi: ["Stasiun", "Halte"]
        case .fasilitas: ["Toilet umum", "Sekolah", "Pasar", "Perpustakaan", "Gedung kantor"]
        }
    }
}

enum Facility: String, CaseIterable {
    case kursiRoda = "Akses kursi roda", ramp = "Ramp", lift = "Lift", toilet = "Toilet disabilitas", parkir = "Parkir disabilitas"
    var symbol: String {
        switch self {
        case .kursiRoda: "figure.roll"
        case .ramp: "road.lanes"
        case .lift: "arrow.up.arrow.down.square"
        case .toilet: "toilet"
        case .parkir: "parkingsign"
        }
    }
    /// Hanya mengisi dari data yang ada; sisanya jujur "Belum diverifikasi".
    func status(_ p: Place) -> (text: String, color: Color) {
        let raw: String = switch self {
        case .kursiRoda: p.wheelchair
        case .lift: p.lift
        case .toilet: p.toilet
        case .ramp, .parkir: "unknown"
        }
        switch raw {
        case "yes", "designated": return ("Ada", .green)
        case "limited": return ("Sebagian", .orange)
        case "no": return ("Tidak ada", .red)
        default: return ("Belum diverifikasi", .secondary)
        }
    }
}

/// Satu pilihan rute (Terbaik / Termudah / Tercepat) dari graf jalur GOP.
struct RouteOption: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case terbaik = "Terbaik", termudah = "Termudah", tercepat = "Tercepat" }
    let kind: Kind
    let plan: WalkGraph.Plan
    let safeMeters: Float
    var id: Kind { kind }
    var minutes: Int { max(1, Int((plan.route.length / 1.1 / 60).rounded(.up))) }

    static func == (a: RouteOption, b: RouteOption) -> Bool { a.kind == b.kind && a.plan.route.length == b.plan.route.length }
    func hash(into h: inout Hasher) { h.combine(kind); h.combine(plan.route.length) }

    var summary: String {
        switch kind {
        case .terbaik: "Seimbang: aman dan cukup cepat"
        case .termudah: "Paling sedikit segmen hati-hati"
        case .tercepat: "Paling pendek, bisa lewat jalan mobil"
        }
    }

    static func options(from start: SIMD2<Float>, to place: Place, model: AppModel, avoiding blocked: Set<Int> = []) -> [RouteOption] {
        Kind.allCases.compactMap { kind in
            let plan = AppModel.graph.plan(from: start, to: place.point, cost: { e in
                if blocked.contains(e) { return nil }
                let c = model.conditions.report(e).condition
                guard let base = c.cost else { return nil }
                switch kind {
                case .terbaik: return model.conditions.cost(e)
                case .termudah: return c == .hatiHati ? 6 : (c == .belumDicek ? 2.5 : base)
                case .tercepat: return 1
                }
            }, condition: { model.conditions.report($0).condition })
            guard let plan else { return nil }
            let safe = plan.edges.filter { model.conditions.report($0).condition == .aman }
                .reduce(Float(0)) { $0 + AppModel.graph.length($1) }
            return RouteOption(kind: kind, plan: plan, safeMeters: safe)
        }
    }
}

extension WalkGraph.Plan: Hashable {
    static func == (a: Self, b: Self) -> Bool { a.edges == b.edges }
    func hash(into h: inout Hasher) { h.combine(edges) }
}

/// Hambatan di sepanjang rute: segmen kuning/merah beserta jaraknya dari titik mulai.
struct Hazard: Identifiable, Hashable {
    let edge: Int
    let at: Float
    let condition: Condition
    let title: String
    let point: SIMD2<Float>
    var id: Int { edge }

    static func along(_ plan: WalkGraph.Plan, model: AppModel) -> [Hazard] {
        var out: [Hazard] = []
        var lastEnd: Float = -.infinity
        for e in plan.edges {
            let r = model.conditions.report(e)
            let mid = (AppModel.graph.point(AppModel.graph.edges[e][0]) + AppModel.graph.point(AppModel.graph.edges[e][1])) / 2
            let at = plan.route.project(mid).along
            guard r.condition == .hatiHati || r.condition == .tidakBisa else { continue }
            let title = r.reasons.first ?? r.condition.title
            // Segmen bersambung dengan alasan sama = satu hambatan (mis. satu ruas jalan mobil).
            if let last = out.last, last.title == title, at - lastEnd < 60 { lastEnd = at; continue }
            out.append(Hazard(edge: e, at: at, condition: r.condition, title: title, point: mid))
            lastEnd = at
        }
        return out
    }
}

enum Screen: Hashable {
    case search
    case place(Place)
    case routes(Place)
    case navigate(Place, RouteOption)
    case contribute(Place)
}

extension RouteOption {
    /// Seberapa yakin rute ini aksesibel: porsi rute yang belum dicek atau perlu hati-hati.
    enum Confidence {
        case tinggi, sedang, rendah
        var title: String { switch self { case .tinggi: "Tinggi"; case .sedang: "Sedang"; case .rendah: "Rendah" } }
        var tint: Color { switch self { case .tinggi: .dariAccess; case .sedang: .dariCaution; case .rendah: .dariUrgent } }
    }
    var confidence: Confidence {
        let risky = (plan.unknownMeters + plan.cautionMeters) / max(plan.route.length, 1)
        return risky < 0.2 ? .tinggi : (risky < 0.5 ? .sedang : .rendah)
    }
}

/// Tanggal data untuk label "Diperbarui …": tanggal cek tempat (OSM) kalau ada, kalau tidak tanggal bundel peta.
private func dataDate(_ place: Place? = nil) -> String? {
    tanggalPendek(place?.updated ?? AreaConfig.current.dataUpdated)
}

private func cameraRect(_ route: Route?, pad factor: Double = 0.25) -> MapCameraPosition {
    guard let route, !route.points.isEmpty else { return .automatic }
    let pts = route.points.map { MKMapPoint(AppModel.coordinate($0)) }
    var rect = MKMapRect(origin: pts[0], size: .init(width: 0, height: 0))
    for p in pts { rect = rect.union(MKMapRect(origin: p, size: .init(width: 0, height: 0))) }
    let pad = max(rect.width, rect.height) * factor + 60
    return .rect(rect.insetBy(dx: -pad, dy: -pad))
}

private func accessChip(_ p: Place) -> DariChip {
    switch p.wheelchair {
    case "yes", "designated": DariChip(text: "Aksesibel", symbol: "checkmark.circle.fill", tint: .dariAccess)
    case "limited": DariChip(text: "Sebagian", symbol: "exclamationmark.circle.fill", tint: .dariCaution)
    case "no": DariChip(text: "Tidak aksesibel", symbol: "xmark.circle.fill", tint: .dariUrgent)
    default: DariChip(text: "Belum diverifikasi", symbol: "questionmark.circle")
    }
}

// MARK: - Root

enum RootTab: CaseIterable {
    case jelajah, kontribusi, profil
    var title: String { switch self { case .jelajah: "Jelajah"; case .kontribusi: "Kontribusi"; case .profil: "Profil" } }
    var symbol: String { switch self { case .jelajah: "safari"; case .kontribusi: "plus.circle"; case .profil: "person" } }
}

struct WheelieRoot: View {
    @State private var model = AppModel()
    @State private var path: [Screen] = []
    @State private var tab: RootTab = .jelajah

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                switch tab {
                case .jelajah: HomeView(model: model, path: $path)
                case .kontribusi: ContributeView(model: model, place: nil)
                case .profil: ProfileView(model: model, path: $path)
                }
                tabBar
            }
            .background(Color.dariBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .search: SearchView(model: model, path: $path)
                case .place(let p): PlaceDetailView(model: model, place: p, path: $path)
                case .routes(let p): RoutePickerView(model: model, place: p, path: $path)
                case .navigate(let p, let o): NavigationScreen(model: model, place: p, option: o, path: $path)
                case .contribute(let p): ContributeView(model: model, place: p)
                }
            }
        }
        .tint(.dariAction)
        .onAppear { model.location.start() }
    }

    private var tabBar: some View {
        HStack {
            ForEach(RootTab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab == t && t != .jelajah ? t.symbol + ".fill" : t.symbol).font(.title3)
                        Text(t.title).font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(tab == t ? Color.dariAction : Color.dariMuted)
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 28)
        .background(Color.white.shadow(.drop(color: .black.opacity(0.06), radius: 8, y: -2)))
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - 1 · Jelajah

struct HomeView: View {
    let model: AppModel
    @Binding var path: [Screen]
    @State private var category: Category?
    @State private var locationCardDismissed = false

    /// Destinasi unggulan: tempat rekreasi di area yang bisa dirute, yang punya data aksesibilitas didahulukan.
    private var featured: [Place] {
        let kinds: [String] = ["Taman", "Perpustakaan", "Mall", "Mall terbuka", "Museum", "Gedung pameran", "Rekreasi"]
        return Place.all.filter { $0.inArea && kinds.contains($0.kind) }
            .sorted { a, b in
                func rank(_ p: Place) -> Int { ["yes": 0, "designated": 0, "limited": 1, "no": 3][p.wheelchair] ?? 2 }
                let ka = rank(a), kb = rank(b)
                return ka != kb ? ka < kb : (kinds.firstIndex(of: a.kind)!, a.name) < (kinds.firstIndex(of: b.kind)!, b.name)
            }
            .prefix(4).map { $0 }
    }

    private var listed: [Place] {
        // Pintu masuk MRT bernama satu huruf ("A", "D") tidak berarti tanpa nama stasiunnya.
        let base = Place.all.filter { $0.name.count > 2 && (category == nil || category!.kinds.contains($0.kind)) }
        return base.sorted { simd_distance($0.point, model.userPoint) < simd_distance($1.point, model.userPoint) }.prefix(40).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jelajahi tempat").font(.largeTitle.bold()).foregroundStyle(Color.dariPrimary)
                    Text("Temukan rute aksesibel ke tempat favoritmu di \(AreaConfig.current.name).")
                        .font(.subheadline).foregroundStyle(Color.dariMuted)
                }
                .padding(.top, 8)

                Button { path.append(.search) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        Text("Cari tujuan atau tempat")
                        Spacer()
                    }
                    .font(.subheadline).foregroundStyle(Color.dariMuted)
                    .padding(14)
                    .background(Color.dariLine.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                }

                if (model.location.local == nil || model.location.denied || model.location.reduced) && !locationCardDismissed { locationCard }

                Text("Destinasi unggulan").font(.headline).foregroundStyle(Color.dariPrimary)
                ForEach(featured) { p in
                    Button { path.append(.place(p)) } label: { FeaturedCard(model: model, place: p) }
                        .buttonStyle(.plain)
                }

                Text("Semua tempat").font(.headline).foregroundStyle(Color.dariPrimary).padding(.top, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Category.allCases) { c in
                            Button { withAnimation { category = category == c ? nil : c } } label: {
                                Text(c.rawValue).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .foregroundStyle(category == c ? .white : Color.dariPrimary)
                                    .background(category == c ? Color.dariAction : Color.white, in: Capsule())
                                    .overlay(Capsule().stroke(Color.dariLine, lineWidth: category == c ? 0 : 1))
                            }
                        }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(listed) { p in
                        Button { path.append(.place(p)) } label: {
                            PlaceRow(place: p, detail: [model.distanceText(to: p), p.kind].compactMap { $0 }.joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                        if p != listed.last { Divider().padding(.leading, 66) }
                    }
                }
                .dariCard(padding: 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .background(Color.dariBackground)
    }

    private var locationCard: some View {
        HStack(alignment: .top, spacing: 12) {
            let problem = model.location.denied || model.location.reduced
            IconDot(symbol: "location.slash.fill", tint: problem ? .dariUrgent : .dariAction, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.location.denied ? "Izin lokasi ditolak"
                     : (model.location.reduced ? "Lokasi Tepat belum aktif" : "Menunggu sinyal GPS…"))
                    .font(.subheadline.bold()).foregroundStyle(Color.dariPrimary)
                Text(model.location.denied ? "Rute dimulai dari posisi GPS-mu. Izinkan lokasi di Pengaturan."
                     : (model.location.reduced ? "Nyalakan \"Lokasi Tepat\" di Pengaturan supaya rute dan peringatan hambatan akurat."
                        : "Rute dimulai dari posisimu. Di luar ruangan biasanya butuh beberapa detik."))
                    .font(.caption).foregroundStyle(Color.dariMuted)
                HStack(spacing: 16) {
                    if problem {
                        Button("Buka Pengaturan") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.subheadline.bold())
                    } else {
                        Button("Aktifkan") { model.location.start() }.font(.subheadline.bold())
                    }
                    Button("Nanti") { locationCardDismissed = true }.font(.subheadline).foregroundStyle(Color.dariMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .dariCard()
    }
}

/// Peta statis miring sebagai "foto" tempat; aplikasi belum punya foto tempat dan tidak mengarangnya.
struct PlaceMapThumb: View {
    let place: Place
    var distance: Double = 650
    var body: some View {
        MapSnapshot(center: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon), distance: distance, pitch: 50)
    }
}

struct FeaturedCard: View {
    let model: AppModel
    let place: Place
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlaceMapThumb(place: place).frame(height: 130)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(place.name).font(.headline).foregroundStyle(Color.dariPrimary).lineLimit(1)
                    Spacer()
                    if let r = model.reviews.rating(for: place) {
                        Label(String(format: "%.1f", r.value), systemImage: "star.fill")
                            .font(.subheadline.bold()).foregroundStyle(Color.dariAction)
                    }
                }
                RouteAvailability(place: place)
                if let d = dataDate(place) {
                    Text("Diperbarui \(d)").font(.caption).foregroundStyle(Color.dariMuted)
                }
            }
            .padding(14)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

struct RouteAvailability: View {
    let place: Place
    var body: some View {
        if place.inArea {
            Label("Rute aksesibel tersedia", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(Color.dariAccess)
        } else {
            Label("Rute belum tersedia", systemImage: "minus.circle")
                .font(.caption.weight(.medium)).foregroundStyle(Color.dariMuted)
        }
    }
}

struct PlaceRow: View {
    let place: Place
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            KindTile(kind: place.kind, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.dariPrimary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Color.dariMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.dariMuted)
        }
        .padding(8)
        .contentShape(Rectangle())
    }
}

// MARK: - Cari

struct SearchView: View {
    let model: AppModel
    @Binding var path: [Screen]
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Place] {
        // "GOP 1" = "Green Office Park 1".
        let q = query.lowercased().replacingOccurrences(of: "gop", with: "green office park")
        return Place.all.filter { $0.name.lowercased().contains(q) || $0.kind.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CircleButton(symbol: "chevron.left") { path.removeLast() }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.dariMuted)
                    TextField("Mau ke mana?", text: $query).focused($focused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(Color.dariMuted)
                    }
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }
            Label(model.userLabel, systemImage: "location.fill").font(.caption).foregroundStyle(Color.dariMuted)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if query.isEmpty {
                        section("Saran tujuan", Place.all.filter { $0.inArea && $0.wheelchair != "no" }
                            .sorted { ($0 == .breeze ? 0 : ($0.wheelchair == "yes" ? 1 : 2)) < ($1 == .breeze ? 0 : ($1.wheelchair == "yes" ? 1 : 2)) }
                            .prefix(12).map { $0 })
                    } else if results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.title).foregroundStyle(Color.dariMuted)
                            Text("Tidak ada hasil").font(.headline).foregroundStyle(Color.dariPrimary)
                            Text("Tidak ditemukan \"\(query)\" di area \(AreaConfig.current.name).")
                                .font(.caption).foregroundStyle(Color.dariMuted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        section("Hasil di \(AreaConfig.current.name)", results)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .background(Color.dariBackground)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
    }

    private func section(_ title: String, _ places: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Color.dariPrimary)
            VStack(spacing: 0) {
                ForEach(places) { p in
                    Button { path.append(.place(p)) } label: {
                        PlaceRow(place: p, detail: [p.kind, model.distanceText(to: p)].compactMap { $0 }.joined(separator: " · "))
                    }
                    .buttonStyle(.plain)
                }
            }
            .dariCard(padding: 6)
        }
    }
}

// MARK: - 2 · Detail tempat

struct PlaceDetailView: View {
    let model: AppModel
    let place: Place
    @Binding var path: [Screen]

    private var nearby: [Place] {
        let kinds = Category.rekreasi.kinds.union(Category.belanja.kinds).union(Category.kuliner.kinds).union(["Perpustakaan"])
        return Place.all.filter { $0 != place && $0.inArea && kinds.contains($0.kind) }
            .sorted { simd_distance($0.point, place.point) < simd_distance($1.point, place.point) }
            .prefix(4).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PlaceHeader(place: place).frame(height: 270).clipped()

                VStack(alignment: .leading, spacing: 8) {
                    Text(place.name).font(.title.bold()).foregroundStyle(Color.dariPrimary)
                    ratingRow
                    if let d = dataDate(place) {
                        Label("Diperbarui \(d)", systemImage: "calendar").font(.caption).foregroundStyle(Color.dariMuted)
                    }
                    if let d = model.distanceText(to: place) {
                        Label("\(d) dari \(model.userLabel.lowercased())", systemImage: "location")
                            .font(.caption).foregroundStyle(Color.dariMuted)
                    }
                }
                .padding(.horizontal, 20)

                statusCard.padding(.horizontal, 20)
                facilities.padding(.horizontal, 20)

                if !nearby.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tempat rekreasi terdekat").font(.headline).foregroundStyle(Color.dariPrimary)
                        VStack(spacing: 0) {
                            ForEach(nearby) { p in
                                Button { path.append(.place(p)) } label: {
                                    PlaceRow(place: p, detail: "\(Int(simd_distance(p.point, place.point))) m")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .dariCard(padding: 6)
                    }
                    .padding(.horizontal, 20)
                }

                reviews.padding(.horizontal, 20)
                Spacer(minLength: 110)
            }
        }
        .background(Color.dariBackground)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) {
            HStack {
                CircleButton(symbol: "chevron.left") { path.removeLast() }
                Spacer()
                CircleButton(symbol: model.saved.contains(place.name) ? "heart.fill" : "heart", tint: .dariUrgent) {
                    model.toggleSave(place)
                }
            }
            .padding(.horizontal, 20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                DariButton(title: "Rencanakan rute aksesibel", enabled: place.inArea && model.gpsInArea) {
                    path.append(.routes(place))
                }
                if let hint = routeHint {
                    Text(hint).font(.caption).foregroundStyle(Color.dariMuted).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
            .background(Color.dariBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var routeHint: String? {
        if !place.inArea { return "Rute belum tersedia: peta jalur baru mencakup \(AreaConfig.current.coverage)." }
        if !model.gpsInArea {
            return model.location.local == nil ? "Rute dimulai dari lokasi GPS-mu. Aktifkan lokasi dan tunggu sinyal."
                : "Rute hanya tersedia saat kamu berada di area \(AreaConfig.current.name)."
        }
        return nil
    }

    @ViewBuilder private var ratingRow: some View {
        if let r = model.reviews.rating(for: place) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").foregroundStyle(Color.dariAction)
                Text(String(format: "%.1f", r.value)).font(.subheadline.bold()).foregroundStyle(Color.dariPrimary)
                Text("Rating aksesibilitas · \(r.count) ulasan").font(.caption).foregroundStyle(Color.dariMuted)
            }
        } else {
            Label("Belum ada penilaian aksesibilitas", systemImage: "star").font(.caption).foregroundStyle(Color.dariMuted)
        }
    }

    private var statusCard: some View {
        let (symbol, tint, title, body): (String, Color, String, String) = {
            if !place.inArea {
                return ("minus.circle.fill", .dariMuted, "Rute belum tersedia", "Peta jalur baru mencakup \(AreaConfig.current.coverage).")
            }
            switch place.wheelchair {
            case "yes", "designated":
                return ("checkmark.circle.fill", .dariAccess, "Rute aksesibel tersedia", "Tempat tercatat ramah kursi roda. Jalur dihitung dari peta OSM + BIG; sebagian belum disurvei.")
            case "limited":
                return ("exclamationmark.circle.fill", .dariCaution, "Aksesibel sebagian", "Sebagian area tercatat bisa diakses kursi roda. Cek hambatan di pratinjau rute.")
            case "no":
                return ("xmark.circle.fill", .dariUrgent, "Tercatat tidak aksesibel", "Menurut OpenStreetMap. Kalau sudah berubah, bantu perbarui lewat Kontribusi.")
            default:
                return ("checkmark.circle.fill", .dariAccess, "Rute aksesibel bisa dihitung", "Aksesibilitas tempatnya belum diverifikasi. Hambatan jalur ditandai di pratinjau rute.")
            }
        }()
        return HStack(alignment: .top, spacing: 12) {
            IconDot(symbol: symbol, tint: tint, size: 30, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold()).foregroundStyle(Color.dariPrimary)
                Text(body).font(.caption).foregroundStyle(Color.dariMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private var facilities: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fasilitas aksesibilitas").font(.headline).foregroundStyle(Color.dariPrimary)
            VStack(spacing: 0) {
                ForEach(Facility.allCases, id: \.self) { f in
                    let s = f.status(place)
                    HStack {
                        Image(systemName: f.symbol).foregroundStyle(Color.dariAccess).frame(width: 26)
                        Text(f.rawValue).font(.subheadline).foregroundStyle(Color.dariPrimary)
                        Spacer()
                        Text(s.text).font(.caption.weight(.semibold))
                            .foregroundStyle(s.text == "Ada" ? Color.dariAccess : (s.text == "Tidak ada" ? Color.dariUrgent : (s.text == "Sebagian" ? Color.dariCaution : Color.dariMuted)))
                    }
                    .padding(.vertical, 9)
                    if f != Facility.allCases.last { Divider() }
                }
            }
            .dariCard(padding: 12)
            Text("Sumber: \(place.source)").font(.caption2).foregroundStyle(Color.dariMuted)
        }
    }

    private var reviews: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pengalaman pengunjung").font(.headline).foregroundStyle(Color.dariPrimary)
                Spacer()
                Button("Bagikan") { path.append(.contribute(place)) }.font(.subheadline.bold())
            }
            let list = model.reviews.reviews(for: place)
            if list.isEmpty {
                Text("Belum ada ulasan. Jadilah yang pertama menilai jalur, pintu masuk, dan toilet tempat ini.")
                    .font(.caption).foregroundStyle(Color.dariMuted)
            }
            ForEach(list.reversed()) { r in
                HStack(alignment: .top, spacing: 10) {
                    if let img = model.reviews.image(r) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= r.rating ? "star.fill" : "star").font(.caption2)
                                    .foregroundStyle(i <= r.rating ? Color.dariAction : Color.dariLine)
                            }
                            Text("· \(tanggalPendek(r.date))").font(.caption2).foregroundStyle(Color.dariMuted)
                        }
                        if !r.text.isEmpty { Text(r.text).font(.caption).foregroundStyle(Color.dariPrimary) }
                    }
                    Spacer(minLength: 0)
                }
                .dariCard(padding: 10, radius: 14)
            }
        }
    }
}

/// Header detail tempat: peta 3D lokasi + tombol foto jalanan (viewer penuh baru dibuka saat ditekan).
struct PlaceHeader: View {
    let place: Place
    @State private var showPhotos = false
    private var photos: [StreetPhoto] { StreetPhoto.near(place.point, within: 40) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PlaceMapThumb(place: place, distance: 450)
            if !photos.isEmpty {
                Button { showPhotos = true } label: {
                    Label("Foto jalanan · \(photos.count)", systemImage: "photo.on.rectangle.angled")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white, in: Capsule())
                }
                .foregroundStyle(Color.dariPrimary)
                .padding(14)
            }
        }
        .fullScreenCover(isPresented: $showPhotos) { StreetViewer(photos: photos) }
    }
}

// MARK: - 3 · Pratinjau rute

struct HazardCard: View {
    let title: String
    let subtitle: String
    var tint: Color = .dariCaution
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconDot(symbol: "exclamationmark.triangle.fill", tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(Color.dariPrimary).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(Color.dariMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.dariMuted)
            }
            .padding(12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Foto 360° di satu titik: Mapillary kalau ada, kalau tidak Apple Look Around.
struct LookAroundCover: View {
    let point: SIMD2<Float>
    let title: String
    let onClose: () -> Void
    var body: some View {
        StreetHeader(point: point, radius: 30)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                HStack {
                    CircleButton(symbol: "xmark", action: onClose)
                    Text(title).font(.subheadline.bold()).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white, in: Capsule()).foregroundStyle(Color.dariPrimary)
                }
                .padding()
            }
    }
}

struct RoutePickerView: View {
    let model: AppModel
    let place: Place
    @Binding var path: [Screen]
    @State private var options: [RouteOption] = []
    @State private var selected: RouteOption.Kind = .terbaik
    @State private var blocked: Set<Int> = []
    @State private var detail: RouteOption?
    @State private var preview: Hazard?
    @State private var routePreview: [StreetPhoto]?
    @State private var lookAt: SIMD2<Float>?

    private var current: RouteOption? { options.first { $0.kind == selected } }
    private var hazards: [Hazard] { current.map { Hazard.along($0.plan, model: model) } ?? [] }

    /// Pilihan yang menghasilkan rute sama digabung jadi satu ("Terbaik · Termudah").
    private var uniqueOptions: [(kinds: [RouteOption.Kind], option: RouteOption)] {
        var out: [(kinds: [RouteOption.Kind], option: RouteOption)] = []
        for o in options {
            if let i = out.firstIndex(where: { $0.option.plan.edges == o.plan.edges }) { out[i].kinds.append(o.kind) }
            else { out.append(([o.kind], o)) }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: .constant(cameraRect(current?.plan.route, pad: 0.12))) {
                if let r = current?.plan.route {
                    WalkLine(points: r.points.map(AppModel.coordinate))
                    Annotation("", coordinate: AppModel.coordinate(r.points[0])) { StartDot() }
                    Marker(place.name, coordinate: AppModel.coordinate(r.points.last!)).tint(Color.dariUrgent)
                    ForEach(hazards) { h in
                        Annotation("", coordinate: AppModel.coordinate(r.position(at: h.at))) {
                            HazardDot(condition: h.condition) { preview = h }
                        }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {}
            .safeAreaPadding(.top, 60)
            .safeAreaPadding(.bottom, 350)
            .ignoresSafeArea()

            routePanel
        }
        .overlay(alignment: .topLeading) {
            CircleButton(symbol: "chevron.left") { path.removeLast() }.padding(.leading, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: recompute)
        .onChange(of: model.gpsInArea) { recompute() }
        .sheet(item: $detail) { o in
            RouteDetailSheet(model: model, place: place, option: o) { hazard in
                detail = nil
                preview = hazard
            }
        }
        .fullScreenCover(isPresented: Binding(get: { routePreview != nil }, set: { if !$0 { routePreview = nil } })) {
            StreetViewer(photos: routePreview ?? [], route: current?.plan.route, title: "Pratinjau rute")
        }
        .fullScreenCover(isPresented: Binding(get: { lookAt != nil }, set: { if !$0 { lookAt = nil } })) {
            LookAroundCover(point: lookAt ?? .zero, title: "Pratinjau 360°") { lookAt = nil }
        }
        .fullScreenCover(item: $preview) { h in
            HazardPreview(model: model, hazard: h, place: place, start: model.location.local,
                          onContinue: { preview = nil },
                          onAlternative: {
                              blocked.insert(h.edge)
                              preview = nil
                              recompute()
                          })
        }
    }

    private func recompute() {
        guard model.gpsInArea, let start = model.location.local else { options = []; return }
        options = RouteOption.options(from: start, to: place, model: model, avoiding: blocked)
        wlog("[RUTE] \(place.name): \(options.map { "\($0.kind.rawValue) \(Int($0.plan.route.length)) m" })")
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(Color.dariLine).frame(width: 36, height: 5).frame(maxWidth: .infinity)
            if options.isEmpty {
                Label(model.gpsInArea ? "Menghitung rute…" : "Menunggu lokasi GPS…", systemImage: "location")
                    .font(.subheadline).foregroundStyle(Color.dariMuted).padding(.vertical, 24)
            }
            if uniqueOptions.count > 1 {
                HStack(spacing: 8) {
                    ForEach(uniqueOptions, id: \.option.kind) { item in
                        let on = item.kinds.contains(selected)
                        Button { selected = item.kinds[0] } label: {
                            Text(item.kinds.map(\.rawValue).joined(separator: " · "))
                                .font(.caption.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(on ? .white : Color.dariPrimary)
                                .background(on ? Color.dariAction : Color.dariLine.opacity(0.6), in: Capsule())
                        }
                    }
                }
            }
            if let o = current { summary(o) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28).fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private func summary(_ o: RouteOption) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(o.minutes) mnt").font(.title2.bold()).foregroundStyle(Color.dariAccess)
            Text("(\(Int(o.plan.route.length)) m)").font(.title3).foregroundStyle(Color.dariMuted)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                Text("Keyakinan \(o.confidence.title.lowercased())")
            }
            .font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5).background(o.confidence.tint, in: Capsule())
        }
        HStack(spacing: 0) {
            stat("figure.walk", "\(hazards.filter { $0.title.hasPrefix("Penyeberangan") }.count)", "penyeberangan")
            stat("car.fill", "\(Int(roadMeters(o))) m", "jalan mobil")
            stat("questionmark.circle", "\(Int(o.plan.unknownMeters)) m", "belum dicek")
        }
        if let h = hazards.first {
            HazardCard(title: h.title, subtitle: "\(Int(h.at)) m dari awal" + (hazards.count > 1 ? " · +\(hazards.count - 1) hambatan lain" : ""),
                       tint: Color(h.condition.color)) { preview = h }
        }
        HStack(spacing: 10) {
            Button {
                let photos = StreetPhoto.along(o.plan.route)
                if photos.isEmpty { lookAt = hazards.first?.point ?? SIMD2(o.plan.route.points[0].x, o.plan.route.points[0].z) }
                else { routePreview = photos }
            } label: {
                Image(systemName: "rotate.3d").font(.headline)
                    .frame(width: 50, height: 50).background(Color.dariAction.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Pratinjau 360°")
            Button { detail = o } label: {
                Image(systemName: "list.bullet").font(.headline)
                    .frame(width: 50, height: 50).background(Color.dariAction.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Detail langkah")
            DariButton(title: "Mulai", symbol: "location.north.fill") { path.append(.navigate(place, o)) }
        }
        if let d = dataDate() {
            Text("Data peta diperbarui \(d)").font(.caption2).foregroundStyle(Color.dariMuted)
        }
    }

    private func roadMeters(_ o: RouteOption) -> Float {
        o.plan.edges.filter { model.conditions.report($0).reasons.first?.hasPrefix("Jalan mobil") == true }
            .reduce(Float(0)) { $0 + AppModel.graph.length($1) }
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(Color.dariMuted)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.subheadline.bold()).foregroundStyle(Color.dariPrimary)
                Text(label).font(.caption2).foregroundStyle(Color.dariMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Garis rute jalan kaki ala Google Maps: titik-titik bulat biru.
struct WalkLine: MapContent {
    let points: [CLLocationCoordinate2D]
    var color: Color = .dariAction
    var body: some MapContent {
        MapPolyline(coordinates: points)
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [0.1, 6]))
    }
}

struct StartDot: View {
    var body: some View {
        Circle().fill(Color.dariAction).frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 2)
    }
}

/// Penanda hambatan kecil di atas rute; diketuk untuk membuka detail hambatan.
struct HazardDot: View {
    let condition: Condition
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color(condition.color), in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Hambatan: \(condition.title)")
    }
}

struct RouteDetailSheet: View {
    let model: AppModel
    let place: Place
    let option: RouteOption
    let onHazard: (Hazard) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Jarak", value: "\(Int(option.plan.route.length)) m")
                    LabeledContent("Waktu dorong", value: "±\(option.minutes) menit")
                    LabeledContent("Belum dicek", value: "\(Int(option.plan.unknownMeters)) m")
                    LabeledContent("Perlu hati-hati", value: "\(Int(option.plan.cautionMeters)) m")
                } footer: {
                    Text("Keyakinan \(option.confidence.title.lowercased()): dihitung dari porsi rute yang belum disurvei atau perlu hati-hati.")
                }
                Section("Langkah") {
                    Label("Mulai dari \(model.userLabel.lowercased())", systemImage: "circle.fill")
                    ForEach(Array(option.plan.route.maneuvers.enumerated()), id: \.offset) { _, m in
                        Label("Setelah \(Int(m.at)) m, belok \(m.left ? "kiri" : "kanan")",
                              systemImage: m.left ? "arrow.turn.up.left" : "arrow.turn.up.right")
                    }
                    Label("Tiba di \(place.name)", systemImage: "flag.checkered")
                }
                Section("Hambatan") {
                    let hazards = Hazard.along(option.plan, model: model)
                    if hazards.isEmpty { Text("Tidak ada hambatan tercatat. Segmen \"belum dicek\" belum tentu aman.").font(.subheadline) }
                    ForEach(hazards) { h in
                        Button { onHazard(h) } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(h.condition.color))
                                VStack(alignment: .leading) {
                                    Text(h.title).foregroundStyle(Color.dariPrimary)
                                    Text("\(Int(h.at)) m dari titik mulai · \(h.condition.title)").font(.caption).foregroundStyle(Color.dariMuted)
                                }
                                Spacer()
                                Text("Lihat").font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Detail rute · \(option.kind.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 5 · Detail hambatan

struct HazardPreview: View {
    let model: AppModel
    let hazard: Hazard
    let place: Place
    let start: SIMD2<Float>?
    let onContinue: () -> Void
    let onAlternative: () -> Void
    @State private var alternative: Route?
    @State private var computed = false
    @State private var showReport = false

    private var report: SegmentReport { model.conditions.report(hazard.edge) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleButton(symbol: "chevron.left", action: onContinue)
                Spacer()
                Text("Detail hambatan").font(.headline).foregroundStyle(Color.dariPrimary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StreetHeader(point: hazard.point, radius: 25)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .bottomTrailing) {
                            if !StreetPhoto.near(hazard.point, within: 25).isEmpty { Text("360°").font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule()).padding(10) }
                        }

                    HStack(spacing: 12) {
                        IconDot(symbol: "exclamationmark.triangle.fill", tint: Color(hazard.condition.color), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hazard.title).font(.headline).foregroundStyle(Color.dariPrimary)
                            Text(report.source == "survei"
                                 ? "Dilaporkan \(report.updated.map(tanggalPendek) ?? "")"
                                 : "Perkiraan dari peta OSM + BIG · belum disurvei")
                                .font(.caption).foregroundStyle(Color.dariMuted)
                        }
                    }

                    FlowChips(chips: chips)

                    Text("\(Int(hazard.at)) m dari titik mulai. Nilai apakah masih bisa kamu lewati.")
                        .font(.subheadline).foregroundStyle(Color.dariMuted)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rute alternatif").font(.headline).foregroundStyle(Color.dariPrimary)
                        if let alternative {
                            MapSnapshot(center: AppModel.coordinate(alternative.points[0]),
                                        path: alternative.points.map(AppModel.coordinate))
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            Text("\(Int(alternative.length)) m tanpa melewati hambatan ini").font(.caption).foregroundStyle(Color.dariMuted)
                        } else {
                            Text(computed ? "Tidak ada rute lain yang menghindari segmen ini." : "Mencari rute alternatif…")
                                .font(.caption).foregroundStyle(Color.dariMuted)
                        }
                    }

                    DariButton(title: "Lihat rute alternatif", enabled: alternative != nil, action: onAlternative)
                    if hazard.condition != .tidakBisa {
                        DariButton(title: "Lanjutkan rute ini", style: .outline, action: onContinue)
                    }
                    DariButton(title: "Laporkan hambatan lain", symbol: "exclamationmark.bubble", style: .soft) { showReport = true }
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
        .background(Color.dariBackground)
        .sheet(isPresented: $showReport) {
            ReportSheet { reason, condition in model.conditions.set(hazard.edge, condition, reasons: [reason]) }
        }
        .task {
            if let start {
                alternative = RouteOption.options(from: start, to: place, model: model, avoiding: [hazard.edge]).first?.plan.route
            }
            computed = true
        }
    }

    private var chips: [DariChip] {
        var out = [report.source == "survei"
                   ? DariChip(text: "Terverifikasi", symbol: "checkmark.circle.fill", tint: .dariAccess)
                   : DariChip(text: "Belum diverifikasi", symbol: "questionmark.circle")]
        out.append(DariChip(text: hazard.condition.title, tint: Color(hazard.condition.color)))
        for r in report.reasons.dropFirst() { out.append(DariChip(text: r)) }
        return out
    }
}

/// Chip berbaris yang turun ke baris berikutnya kalau tidak muat.
struct FlowChips: View {
    let chips: [DariChip]
    var body: some View {
        FlowLayout(spacing: 8) { ForEach(Array(chips.enumerated()), id: \.offset) { $0.element } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, arrange(bounds.width, subviews).points) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0, pts: [CGPoint] = []
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += size.width + spacing; row = max(row, size.height); maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + row), pts)
    }
}

// MARK: - Street View (Apple Look Around)

/// Foto jalanan 360° dari Apple Look Around. Kalau Apple belum memotret lokasi ini, tampilkan keterangan jujur.
struct StreetView: View {
    let coordinate: CLLocationCoordinate2D
    @State private var scene: MKLookAroundScene?
    @State private var loaded = false

    var body: some View {
        ZStack {
            if let scene {
                LookAroundPreview(initialScene: scene, allowsNavigation: true, showsRoadLabels: true)
            } else {
                LinearGradient(colors: [Color.dariPrimary.opacity(0.75), Color.dariPrimary], startPoint: .top, endPoint: .bottom)
                    .overlay(VStack(spacing: 6) {
                        if loaded {
                            Image(systemName: "binoculars").font(.largeTitle)
                            Text("Look Around belum tersedia di lokasi ini").font(.subheadline.bold())
                            Text("Foto 360° akan diisi dari survei lapangan").font(.caption)
                        } else {
                            ProgressView().tint(.white)
                            Text("Mencari foto jalanan…").font(.caption)
                        }
                    }.foregroundStyle(.white).multilineTextAlignment(.center).padding())
            }
        }
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            scene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
            loaded = true
            print("LookAround \(coordinate.latitude),\(coordinate.longitude): \(scene == nil ? "TIDAK ADA" : "ADA")")
        }
    }
}

// MARK: - 4 · Navigasi (gaya Google Maps mode jalan kaki)

private extension Color {
    static let navGreen = Color(hex: 0x0F7A3E)
    static let navGreenDark = Color(hex: 0x0B5E30)
}

struct NavigationScreen: View {
    let model: AppModel
    let place: Place
    @Binding var path: [Screen]

    @State private var plan: WalkGraph.Plan
    @State private var travelled: Float = 0
    @State private var voiceOn = true
    @State private var lastSpoken = -1
    @State private var lastHazardSpoken = -1
    @State private var lastReroute = Date.distantPast
    @State private var following = true
    @State private var camera: MapCameraPosition = .automatic
    /// Arah kamera yang dihaluskan (derajat), supaya peta berputar pelan, tidak patah-patah.
    @State private var smoothHeading: Double?
    /// Hambatan yang sudah dinilai pengguna ("Lanjutkan") tidak ditampilkan lagi sebagai kartu.
    @State private var acknowledged: Set<Int> = []
    @State private var show3D = false
    @State private var showAR = false
    @State private var showReport = false
    @State private var preview: Hazard?

    private let speech = AVSpeechSynthesizer()
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    init(model: AppModel, place: Place, option: RouteOption, path: Binding<[Screen]>) {
        self.model = model
        self.place = place
        _path = path
        _plan = State(initialValue: option.plan)
    }

    private var route: Route { plan.route }
    private var remaining: Float { max(0, route.length - travelled) }
    private var arrived: Bool { remaining < 1 }
    private var next: Route.Maneuver? { route.maneuvers.first { $0.at > travelled + 0.5 } }
    private var afterNext: Route.Maneuver? { route.maneuvers.first { $0.at > (next?.at ?? .infinity) + 0.5 } }
    private var hazards: [Hazard] { Hazard.along(plan, model: model) }
    private var upcomingHazard: Hazard? { hazards.first { $0.at > travelled - 2 && $0.at - travelled < 40 } }
    private var hazardCard: Hazard? { upcomingHazard.flatMap { acknowledged.contains($0.edge) ? nil : $0 } }
    private var here: SIMD3<Float> { route.position(at: travelled) }

    /// Nama jalan per segmen rute, diurutkan menurut jarak dari awal rute.
    private var streets: [(at: Float, name: String)] {
        guard let names = AppModel.graph.names else { return [] }
        let g = AppModel.graph
        return plan.edges.compactMap { e in
            let name = names[e]
            guard !name.isEmpty else { return nil }
            let mid = (g.point(g.edges[e][0]) + g.point(g.edges[e][1])) / 2
            return (route.project(mid).along, name)
        }
    }
    /// Jalan yang dimasuki setelah titik `d` (dipakai untuk "Belok kiri ke Jalan …").
    private func street(after d: Float) -> String? { streets.first { $0.at > d + 1 }?.name }
    private var currentStreet: String? { streets.last { $0.at <= travelled + 5 }?.name ?? streets.first?.name }

    // MARK: Peta

    var body: some View {
        ZStack {
            Map(position: $camera) {
                WalkLine(points: travelledPoints, color: Color(hex: 0x9AA0A6))
                WalkLine(points: remainingPoints)
                ForEach(hazards) { h in
                    Annotation("", coordinate: AppModel.coordinate(route.position(at: h.at))) {
                        HazardDot(condition: h.condition) { preview = h }
                    }
                }
                Marker(place.name, coordinate: AppModel.coordinate(route.points.last!)).tint(Color.dariUrgent)
                // Titik biru bawaan iOS dengan kerucut arah hadap (kompas HP).
                UserAnnotation()
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls { MapCompass() }
            .safeAreaPadding(.top, 170)
            .safeAreaPadding(.bottom, 130)
            .ignoresSafeArea()
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in following = false })

            VStack(spacing: 8) {
                banner
                if let h = hazardCard { hazardAlert(h) }
                Spacer()
                HStack(alignment: .bottom) {
                    if !following {
                        Button { follow() } label: {
                            Label("Pusatkan ulang", systemImage: "location.north.fill")
                                .font(.subheadline.bold()).foregroundStyle(Color.dariAction)
                                .padding(.horizontal, 16).frame(height: 44)
                                .background(.white, in: Capsule()).shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        }
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        floatingButton(voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill", voiceOn ? "Suara aktif" : "Suara mati") {
                            voiceOn.toggle()
                            if !voiceOn { speech.stopSpeaking(at: .immediate) }
                        }
                        floatingButton("exclamationmark.bubble.fill", "Laporkan hambatan") { showReport = true }
                        if AreaConfig.current.has3D ?? true { floatingText("3D") { show3D = true } }
                        floatingText("AR") { showAR = true }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 140)

            VStack { Spacer(); bottomBar }
                .ignoresSafeArea(edges: .bottom)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(timer) { tick($0) }
        .onAppear {
            // Layar tetap menyala selama navigasi: HP di kursi roda, tangan dipakai mendorong.
            UIApplication.shared.isIdleTimerDisabled = true
            follow()
            say("Mulai. Menuju \(place.name).")
            wlog("[NAV] mulai ke \(place.name), \(Int(route.length)) m")
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .fullScreenCover(isPresented: $show3D) {
            World3DView(style: .biasa, destination: place, gpsOnly: true)
                .overlay(alignment: .topTrailing) {
                    Button { show3D = false } label: {
                        Label("2D", systemImage: "map").font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial, in: Capsule())
                    }
                    .padding(.top, 54).padding(.trailing)
                }
        }
        .fullScreenCover(isPresented: $showAR) {
            ARNavView(start: SIMD2(here.x, here.z), destination: place, anywhere: false, allowTestMode: false)
        }
        .fullScreenCover(item: $preview) { h in
            HazardPreview(model: model, hazard: h, place: place, start: model.location.local ?? SIMD2(here.x, here.z),
                          onContinue: { acknowledged.insert(h.edge); preview = nil },
                          onAlternative: { preview = nil; reroute(avoiding: [h.edge]) })
        }
        .sheet(isPresented: $showReport) { ReportSheet(onSubmit: report) }
    }

    /// Bagian rute yang sudah dilewati (abu-abu) dan yang tersisa (biru), dipotong di posisi sekarang.
    private var travelledPoints: [CLLocationCoordinate2D] {
        let past = zip(route.points, route.cumulative).filter { $0.1 < travelled }.map(\.0)
        return (past + [here]).map(AppModel.coordinate)
    }
    private var remainingPoints: [CLLocationCoordinate2D] {
        let ahead = zip(route.points, route.cumulative).filter { $0.1 > travelled }.map(\.0)
        return ([here] + ahead).map(AppModel.coordinate)
    }

    // MARK: Kamera

    /// Kamera mengikuti pengguna seperti Google Maps: miring, berputar searah jalan, titik posisi di bagian bawah layar.
    private func follow() {
        following = true
        withAnimation(.easeInOut(duration: 0.6)) { moveCamera() }
    }

    private func moveCamera() {
        let p = model.gpsInArea ? (model.location.local ?? SIMD2(here.x, here.z)) : SIMD2(here.x, here.z)
        let target = model.location.heading ?? model.location.course ?? routeBearing
        smoothHeading = smoothHeading.map { blend($0, target, 0.35) } ?? target
        let h = smoothHeading ?? 0
        // Pusat kamera digeser ±45 m ke depan, jadi titik biru berada di sepertiga bawah layar.
        let rad = Float(h * .pi / 180)
        let ahead = p + SIMD2(sin(rad), -cos(rad)) * 45
        camera = .camera(MapCamera(centerCoordinate: AppModel.coordinate(ahead), distance: 280, heading: h, pitch: 55))
    }

    /// Arah rute di posisi sekarang (dipakai kalau kompas/GPS belum memberi arah).
    private var routeBearing: Double {
        let a = route.position(at: travelled), b = route.position(at: travelled + 15)
        let d = SIMD2(b.x - a.x, b.z - a.z)
        guard simd_length(d) > 0.1 else { return 0 }
        return (atan2(Double(d.x), Double(-d.y)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Interpolasi sudut lewat jalur terpendek (359° → 1° tidak berputar sekeliling).
    private func blend(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let diff = ((to - from + 540).truncatingRemainder(dividingBy: 360)) - 180
        return (from + diff * t + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: Banner & bar bawah

    private var maneuverSymbol: String {
        if arrived { return "flag.checkered" }
        guard let n = next, n.at - travelled < 200 else { return "arrow.up" }
        return n.sharp ? (n.left ? "arrow.uturn.left" : "arrow.uturn.right") : (n.left ? "arrow.turn.up.left" : "arrow.turn.up.right")
    }

    private var banner: some View {
        let toNext = Int((next?.at ?? route.length) - travelled)
        let turning = next.map { $0.at - travelled < 200 } ?? false
        let title: String = {
            if arrived { return place.name }
            if turning, let n = next { return street(after: n.at).map { "Belok \(n.left ? "kiri" : "kanan") ke \($0)" } ?? "Belok \(n.left ? "kiri" : "kanan")" }
            if next == nil { return "Menuju \(place.name)" }
            return currentStreet.map { "Lurus di \($0)" } ?? "Lurus terus"
        }()
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 2) {
                    Image(systemName: maneuverSymbol).font(.system(size: 34, weight: .bold))
                    if !arrived { Text("\(toNext) m").font(.headline) }
                }
                .frame(width: 70)
                Text(arrived ? "Kamu sudah sampai di \(title)" : title)
                    .font(.title3.bold()).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(Color.navGreen)

            if let a = afterNext, let n = next, a.at - n.at < 120, !arrived {
                HStack(spacing: 6) {
                    Text("Lalu").font(.subheadline.weight(.semibold))
                    Image(systemName: a.left ? "arrow.turn.up.left" : "arrow.turn.up.right").font(.subheadline.bold())
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.navGreenDark)
            }
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func hazardAlert(_ h: Hazard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { preview = h } label: {
                HStack(spacing: 10) {
                    IconDot(symbol: "exclamationmark.triangle.fill", tint: Color(h.condition.color), size: 34, filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.subheadline.bold()).foregroundStyle(Color.dariPrimary).lineLimit(2)
                        Text(h.at > travelled ? "\(Int(h.at - travelled)) m di depan" : "Sedang kamu lewati")
                            .font(.caption).foregroundStyle(Color.dariMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.dariMuted)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Button("Cari alternatif") { reroute(avoiding: [h.edge]) }
                    .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 38)
                    .overlay(Capsule().stroke(Color.dariAction, lineWidth: 1.5))
                Button("Lanjutkan") { acknowledged.insert(h.edge) }
                    .font(.subheadline.bold()).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 38)
                    .background(Color.dariAction, in: Capsule())
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16).fill(Color(h.condition.color)).frame(width: 5)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func floatingButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.white, in: Circle()).shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .foregroundStyle(Color.dariPrimary)
        .accessibilityLabel(label)
    }

    private func floatingText(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(width: 48, height: 48)
                .background(.white, in: Circle()).shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .foregroundStyle(Color.dariPrimary)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if arrived {
                Text("Kamu sudah sampai").font(.title3.bold()).foregroundStyle(Color.navGreen)
                HStack(spacing: 10) {
                    DariButton(title: "Bagikan", style: .outline) { path.append(.contribute(place)) }
                    DariButton(title: "Selesai") { finish() }
                }
            } else {
                HStack(spacing: 14) {
                    Button { finish() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(Color.dariPrimary)
                            .frame(width: 48, height: 48).background(Color.dariLine.opacity(0.7), in: Circle())
                    }
                    .accessibilityLabel("Akhiri navigasi")
                    Spacer()
                    VStack(spacing: 2) {
                        let minutes = max(1, Int((remaining / 1.1 / 60).rounded(.up)))
                        Text("\(minutes) mnt").font(.title2.bold()).foregroundStyle(Color.navGreen)
                        HStack(spacing: 6) {
                            Text("\(Int(remaining)) m")
                            Text("·")
                            Text(Date.now.addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened))
                        }
                        .font(.subheadline).foregroundStyle(Color.dariMuted)
                        gpsLabel
                    }
                    Spacer()
                    Button {
                        following = false
                        withAnimation(.easeInOut(duration: 0.6)) { camera = cameraRect(route, pad: 0.15) }
                    } label: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.headline)
                            .foregroundStyle(Color.dariPrimary)
                            .frame(width: 48, height: 48).background(Color.dariLine.opacity(0.7), in: Circle())
                    }
                    .accessibilityLabel("Lihat seluruh rute")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
    }

    @ViewBuilder private var gpsLabel: some View {
        if !model.gpsInArea {
            Label(model.location.local == nil ? "Menunggu GPS…" : "Di luar area peta", systemImage: "location.slash")
                .font(.caption2.weight(.semibold)).foregroundStyle(Color.dariCaution)
        } else if let a = model.location.accuracy, a > 20 {
            Label("Sinyal GPS lemah (±\(Int(a)) m)", systemImage: "location")
                .font(.caption2.weight(.semibold)).foregroundStyle(Color.dariCaution)
        }
    }

    private func finish() {
        speech.stopSpeaking(at: .immediate)
        path.removeAll()
    }

    // MARK: Logic

    private func tick(_ now: Date) {
        let wasArrived = arrived
        // Hanya GPS asli: posisi ditempel ke rute; keluar > 12 m → rute dihitung ulang dari posisi sekarang.
        if model.gpsInArea, let p = model.location.local {
            let (along, off) = route.project(p)
            // Titik GPS yang lompat jauh (akurasi buruk, mis. di antara gedung tinggi) tidak boleh memicu rute ulang.
            let precise = (model.location.accuracy ?? 99) <= 25
            if off > 12, precise, now.timeIntervalSince(lastReroute) > 5 { lastReroute = now; reroute(from: p); return }
            travelled = along
        }
        if following { withAnimation(.linear(duration: 0.25)) { moveCamera() } }
        if arrived && !wasArrived { say("Kamu sudah sampai di \(place.name).") }
        if let i = route.maneuvers.firstIndex(where: { $0.at > travelled + 0.5 }), i != lastSpoken,
           route.maneuvers[i].at - travelled < 15 {
            lastSpoken = i
            let m = route.maneuvers[i]
            let onto = street(after: m.at).map { " ke \($0)" } ?? ""
            say("Dalam \(Int(m.at - travelled)) meter, belok \(m.left ? "kiri" : "kanan")\(onto).")
        }
        if let h = upcomingHazard, h.edge != lastHazardSpoken, h.at > travelled {
            lastHazardSpoken = h.edge
            say("Perhatian, \(h.title.lowercased()) \(Int(h.at - travelled)) meter di depan.")
        }
    }

    private func reroute(avoiding edges: Set<Int> = [], from gps: SIMD2<Float>? = nil) {
        let start = gps ?? model.location.local ?? SIMD2(here.x, here.z)
        let options = RouteOption.options(from: start, to: place, model: model, avoiding: edges)
        guard let best = options.first else { return }
        plan = best.plan
        travelled = 0
        lastSpoken = -1
        say("Rute diperbarui.")
    }

    /// Laporan hambatan langsung menandai segmen terdekat; "Tidak bisa" memicu rute baru.
    private func report(_ reason: String, _ condition: Condition) {
        let p = SIMD2(here.x, here.z)
        let g = AppModel.graph
        let nearest = g.edges.indices.min { a, b in
            func d(_ e: Int) -> Float {
                let s = g.point(g.edges[e][0]), t = g.point(g.edges[e][1]), st = t - s
                let k = simd_clamp(simd_dot(p - s, st) / max(simd_length_squared(st), 0.0001), 0, 1)
                return simd_distance(p, s + st * k)
            }
            return d(a) < d(b)
        }
        guard let nearest else { return }
        model.conditions.set(nearest, condition, reasons: [reason])
        say("Terima kasih, laporan disimpan.")
        if condition == .tidakBisa { reroute(avoiding: []) }
    }

    private func say(_ text: String) {
        guard voiceOn else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "id-ID")
        speech.speak(u)
    }
}

struct ReportSheet: View {
    let onSubmit: (String, Condition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "Terhalang"
    @State private var severity: Condition = .hatiHati

    var body: some View {
        NavigationStack {
            Form {
                Section("Apa yang kamu temui?") {
                    Picker("Hambatan", selection: $reason) {
                        ForEach(["Terhalang", "Pohon mempersempit trotoar", "Tanjakan curam", "Trotoar tinggi", "Tanpa ramp",
                                 "Paving rusak", "Jalur sempit", "Tangga"], id: \.self) {
                            Text($0)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Masih bisa dilewati?") {
                    Picker("Tingkat", selection: $severity) {
                        Text("Bisa, hati-hati").tag(Condition.hatiHati)
                        Text("Tidak bisa").tag(Condition.tidakBisa)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Laporan menandai ruas jalan di dekatmu dan langsung dipakai untuk rute berikutnya.")
                        .font(.caption).foregroundStyle(Color.dariMuted)
                }
            }
            .navigationTitle("Laporkan hambatan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kirim") { onSubmit(reason, severity); dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - 6 · Kontribusi

struct ContributeView: View {
    let model: AppModel
    @State var place: Place?
    @State private var rating = 0
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Bagikan pengalamanmu").font(.title.bold()).foregroundStyle(Color.dariPrimary).padding(.top, 8)

                Text("Tempat yang dikunjungi").font(.headline).foregroundStyle(Color.dariPrimary)
                Menu {
                    ForEach(Place.all.filter(\.inArea)) { p in Button(p.name) { place = p } }
                } label: {
                    HStack(spacing: 12) {
                        KindTile(kind: place?.kind ?? "", size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place?.name ?? "Pilih tempat").font(.subheadline.bold()).foregroundStyle(Color.dariPrimary)
                            Text(AreaConfig.current.name).font(.caption).foregroundStyle(Color.dariMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.dariMuted)
                    }
                    .dariCard(padding: 10)
                }

                Text("Rating aksesibilitas").font(.headline).foregroundStyle(Color.dariPrimary)
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { i in
                        Button { rating = i } label: {
                            Image(systemName: i <= rating ? "star.fill" : "star").font(.title)
                                .foregroundStyle(i <= rating ? Color.dariAction : Color.dariLine)
                        }
                        .accessibilityLabel("\(i) bintang")
                    }
                    Spacer()
                    Text(rating > 0 ? "\(rating).0" : "–").font(.headline).foregroundStyle(Color.dariPrimary)
                }

                Text("Tambah foto").font(.headline).foregroundStyle(Color.dariPrimary)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 160).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "camera").font(.title2)
                            Text("Ketuk untuk menambah foto").font(.caption)
                        }
                        .foregroundStyle(Color.dariMuted)
                        .frame(maxWidth: .infinity).frame(height: 120)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dariLine, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                    }
                }

                Text("Bagaimana kunjunganmu?").font(.headline).foregroundStyle(Color.dariPrimary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text).focused($typing).frame(height: 120).scrollContentBackground(.hidden)
                    if text.isEmpty {
                        Text("Ceritakan aksesibilitas, hambatan, atau tips untuk pengguna lain…")
                            .font(.subheadline).foregroundStyle(Color.dariMuted).padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dariLine))
                Text("\(text.count)/500").font(.caption2).foregroundStyle(Color.dariMuted).frame(maxWidth: .infinity, alignment: .trailing)

                if sent {
                    Label("Terima kasih! Ulasanmu tersimpan di HP ini.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(Color.dariAccess)
                }
                DariButton(title: "Kirim", enabled: place != nil && rating > 0) { submit() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.dariBackground)
        .onChange(of: text) { if text.count > 500 { text = String(text.prefix(500)) } }
        .onChange(of: photoItem) {
            Task {
                if let data = try? await photoItem?.loadTransferable(type: Data.self) { image = UIImage(data: data) }
            }
        }
    }

    private func submit() {
        guard let place else { return }
        model.reviews.add(place: place, rating: rating, text: text, image: image)
        typing = false
        rating = 0; text = ""; image = nil; photoItem = nil
        sent = true
    }
}

// MARK: - Profil

struct ProfileView: View {
    let model: AppModel
    @Binding var path: [Screen]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Profil").font(.largeTitle.bold()).foregroundStyle(Color.dariPrimary).padding(.top, 8)

                HStack(spacing: 10) {
                    stat("\(model.conditions.surveyedCount)", "ruas disurvei")
                    stat("\(model.reviews.reviews.count)", "ulasan")
                    stat("\(model.saved.count)", "tersimpan")
                }

                Text("Tersimpan").font(.headline).foregroundStyle(Color.dariPrimary)
                let saved = Place.all.filter { model.saved.contains($0.name) }
                if saved.isEmpty {
                    Text("Belum ada tempat tersimpan. Ketuk ♡ di halaman tempat.").font(.caption).foregroundStyle(Color.dariMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(saved) { p in
                            Button { path.append(.place(p)) } label: { PlaceRow(place: p, detail: model.distanceText(to: p) ?? p.kind) }
                                .buttonStyle(.plain)
                        }
                    }
                    .dariCard(padding: 6)
                }

                Text("Sumber data").font(.headline).foregroundStyle(Color.dariPrimary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Peta jalur: © OpenStreetMap contributors (ODbL)")
                    Text("Kelas jalan: Badan Informasi Geospasial, Rupabumi Indonesia 25K")
                    Text("Area: \(AreaConfig.current.coverage)" + (dataDate().map { " · data \($0)" } ?? ""))
                    Text("Status jalur adalah perkiraan sampai disurvei. Hasil survei & ulasan tersimpan di HP ini.")
                        .foregroundStyle(Color.dariMuted)
                }
                .font(.caption).foregroundStyle(Color.dariPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dariCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .background(Color.dariBackground)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).foregroundStyle(Color.dariAction)
            Text(label).font(.caption).foregroundStyle(Color.dariMuted)
        }
        .frame(maxWidth: .infinity)
        .dariCard(padding: 12)
    }
}

#Preview { WheelieRoot() }
