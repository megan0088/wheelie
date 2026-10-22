// SPIKE — throwaway. Viewer foto jalanan ala Mapillary: foto besar, ◀ ▶ ▷, peta mini, tanggal.
// Daftar foto (ID + lokasi) diambil dari vector tile Mapillary lewat data/the-breeze; fotonya ditampilkan
// dengan embed resmi Mapillary (tanpa token di aplikasi, kredit kontributor tampil dari Mapillary sendiri).

import SwiftUI
import MapKit
import WebKit
import Combine
import simd

struct StreetPhoto: Decodable, Identifiable, Hashable {
    let id: String
    let lon: Double
    let lat: Double
    let date: String
    let pano: Bool
    let foot: Bool
    let heading: Double?
    let sequence: String?

    static let all: [StreetPhoto] = {
        guard let url = Bundle.main.url(forResource: "streetview", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StreetPhoto].self, from: data)) ?? []
    }()

    private static let origin = (lat: WorldData.bsd.origin[0], lon: WorldData.bsd.origin[1])

    var point: SIMD2<Float> {
        SIMD2(Float((lon - Self.origin.lon) * 111_320 * cos(Self.origin.lat * .pi / 180)),
              Float(-(lat - Self.origin.lat) * 110_540))
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var embedURL: URL { URL(string: "https://www.mapillary.com/embed?image_key=\(id)&style=photo")! }
    var dateText: String {
        guard let d = try? Date(date, strategy: .iso8601.year().month().day()) else { return date }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Foto terdekat dalam radius tertentu; foto terbaru dan foto pejalan kaki didahulukan bila jaraknya mirip.
    static func near(_ p: SIMD2<Float>, within r: Float) -> [StreetPhoto] {
        all.map { ($0, simd_distance($0.point, p)) }
            .filter { $0.1 <= r }
            .sorted { a, b in
                let da = a.1 - (a.0.foot ? 3 : 0) - (a.0.date >= "2024" ? 5 : 0)
                let db = b.1 - (b.0.foot ? 3 : 0) - (b.0.date >= "2024" ? 5 : 0)
                return da < db
            }
            .map(\.0)
    }

    /// Foto berurutan sepanjang rute: tiap 8 m dicari foto terdekat (≤ 15 m), tanpa duplikat.
    static func along(_ route: Route) -> [StreetPhoto] {
        var out: [StreetPhoto] = [], seen = Set<String>()
        var d: Float = 0
        while d <= route.length {
            let p = route.position(at: d)
            if let best = near(SIMD2(p.x, p.z), within: 15).first, seen.insert(best.id).inserted { out.append(best) }
            d += 8
        }
        return out
    }
}

/// Embed resmi Mapillary di WebView.
struct MapillaryEmbed: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url != url { web.load(URLRequest(url: url)) }
    }
}

struct StreetViewer: View {
    let photos: [StreetPhoto]
    var route: Route?
    var title = "Foto jalanan"
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var playing = false
    private let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    private var current: StreetPhoto? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let photo = current {
                MapillaryEmbed(url: photo.embedURL).ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                    Text("Belum ada foto jalanan di sekitar sini").font(.headline)
                    Text("Foto akan bertambah dari survei lapangan").font(.caption)
                }
                .foregroundStyle(.white)
            }
        }
        .safeAreaInset(edge: .top) { topBar }
        .overlay(alignment: .bottomLeading) { if current != nil { minimap } }
        .onReceive(timer) { _ in
            guard playing else { return }
            if index < photos.count - 1 { index += 1 } else { playing = false }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            }
            Spacer()
            if photos.count > 1 {
                HStack(spacing: 18) {
                    Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    Button { index = min(photos.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                    Text("\(index + 1)/\(photos.count)").font(.caption.monospacedDigit())
                }
                .font(.headline)
                .padding(.horizontal, 16).frame(height: 44)
                .background(.regularMaterial, in: Capsule())
            } else {
                Text(title).font(.headline)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.black)
    }

    private var minimap: some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(position: .constant(.camera(MapCamera(centerCoordinate: current!.coordinate, distance: 350)))) {
                if let route {
                    MapPolyline(coordinates: route.points.map(AppModel.coordinate))
                        .stroke(.pink, lineWidth: 4)
                }
                ForEach(photos) { p in
                    Annotation("", coordinate: p.coordinate) {
                        Circle().fill(p.id == current?.id ? Color.orange : Color.green)
                            .frame(width: p.id == current?.id ? 14 : 7, height: p.id == current?.id ? 14 : 7)
                            .overlay(Circle().stroke(.white, lineWidth: p.id == current?.id ? 2 : 0))
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .frame(width: 200, height: 130)
            HStack {
                Text("Mapillary · CC BY-SA")
                Spacer()
                Text(current!.dateText + (current!.pano ? " · 360°" : ""))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: 200)
            .background(.black.opacity(0.75))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
        .padding(.bottom, 44)
    }
}

/// Header detail tempat / hambatan: tombol foto Mapillary terdekat kalau ada, kalau tidak Apple Look Around (atau keterangan kosong).
struct StreetHeader: View {
    let point: SIMD2<Float>
    var radius: Float = 40
    var route: Route?
    @State private var showViewer = false

    private var photos: [StreetPhoto] { StreetPhoto.near(point, within: radius) }

    var body: some View {
        if let first = photos.first {
            ZStack {
                MapillaryEmbed(url: first.embedURL).allowsHitTesting(false)
                VStack {
                    Spacer()
                    Button { showViewer = true } label: {
                        Label("Lihat foto jalanan (\(photos.count)) · \(first.dateText)", systemImage: "photo.on.rectangle")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .padding(12)
                }
            }
            .fullScreenCover(isPresented: $showViewer) { StreetViewer(photos: photos, route: route) }
        } else {
            StreetView(coordinate: AppModel.coordinate(point))
        }
    }
}
