// SPIKE — throwaway. Navigasi AR: panah rute ditempel di tanah lewat kamera.
// Sumbu ARKit dengan .gravityAndHeading: x = timur, z = selatan — sama dengan dunia 3D kita,
// jadi titik rute cukup digeser relatif terhadap posisi pengguna saat kalibrasi.

import SwiftUI
import RealityKit
import ARKit
import Observation

@Observable
final class ARNavController: NSObject, ARSessionDelegate {
    private(set) var headline = "Arahkan kamera ke jalan di depanmu"
    private(set) var subline = "Gerakkan HP pelan-pelan supaya permukaan tanah terdeteksi"
    private(set) var groundFound = false

    @ObservationIgnored let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    @ObservationIgnored private var anchor: AnchorEntity?
    @ObservationIgnored private var route: Route?
    /// Posisi pengguna (koordinat dunia peta) dan posisi kamera AR saat kalibrasi.
    @ObservationIgnored private var userAtCalibration = SIMD2<Float>.zero
    @ObservationIgnored private var cameraAtCalibration = SIMD3<Float>.zero
    /// Tinggi HP dari tanah. Pengguna kursi roda memegang HP lebih rendah dari pejalan kaki.
    @ObservationIgnored private var groundOffset: Float = 1.0
    @ObservationIgnored private var lastHUD = Date.distantPast
    @ObservationIgnored private var lastLog = Date.distantPast
    /// Semua objek rute beserta jaraknya dari titik mulai, supaya hanya bagian di depan yang tampil.
    @ObservationIgnored private var items: [(entity: Entity, at: Float, ahead: Float)] = []
    private(set) var placed = false
    /// Panah 3D yang melayang di depan kamera dan selalu menunjuk ke arah rute.
    @ObservationIgnored private let guide = AnchorEntity(world: .zero)
    @ObservationIgnored private let guideArrow = Entity()
    @ObservationIgnored private var guideLabel = Entity()
    @ObservationIgnored private var guideText = ""

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = [.horizontal]
        arView.session.delegate = self
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { arView.session.pause() }

    /// Letakkan rute di sekitar pengguna. `user` = posisi pengguna di peta (GPS, atau titik mulai saat mode uji).
    @ObservationIgnored private var destinationName = AreaConfig.current.defaultDestination

    func place(plan: WalkGraph.Plan, user: SIMD2<Float>, destination: String, graph: WalkGraph, condition: (Int) -> Condition) {
        destinationName = destination
        anchor?.removeFromParent()
        let cam = arView.cameraTransform.translation
        userAtCalibration = user
        cameraAtCalibration = cam
        route = plan.route

        let root = AnchorEntity(world: [cam.x - user.x, cam.y - groundOffset, cam.z - user.y])
        // Mulai sekarang, titik peta (x, z) cukup ditaruh di (x, 0, z) relatif terhadap root.

        items = []
        func add(_ e: Entity, at: Float, ahead: Float) { root.addChild(e); items.append((e, at, ahead)) }

        // Garis lintasan menyambung + panah chevron tiap 2,5 m sepanjang rute.
        let r = plan.route
        var d: Float = 0
        while d < r.length {
            let a = r.position(at: d), b = r.position(at: min(r.length, d + 1.25))
            add(Self.ribbon(from: a, to: b), at: d, ahead: 40)
            d += 1.25
        }
        d = 1.5
        while d < r.length {
            let p = r.position(at: d), q = r.position(at: d + 0.5)
            add(Self.chevron(at: p, toward: q), at: d, ahead: 40)
            d += 2.5
        }
        // Belokan: rambu berdiri, terlihat dari lebih jauh.
        for m in r.maneuvers {
            let p = r.position(at: m.at)
            add(Self.sign(m.left ? "⬅︎ Belok kiri" : "Belok kanan ➡︎", color: .systemBlue, at: p, height: 1.6), at: m.at, ahead: 70)
        }
        // Hambatan di sekitar rute (merah = tidak bisa, kuning = hati-hati).
        for (i, e) in graph.edges.enumerated() {
            let c = condition(i)
            guard c == .tidakBisa || c == .hatiHati else { continue }
            let mid = (graph.point(e[0]) + graph.point(e[1])) / 2
            guard r.project(mid).off < 25 else { continue }
            let text = c == .tidakBisa ? "⛔︎ Tidak bisa" : "⚠︎ Hati-hati"
            add(Self.sign(text, color: c.color, at: SIMD3(mid.x, 0, mid.y), height: 1.2), at: r.project(mid).along, ahead: 50)
        }
        add(Self.sign("🏁 \(destination)", color: .systemGreen, at: r.points.last!, height: 2.4), at: r.length, ahead: 120)

        arView.scene.addAnchor(root)
        anchor = root
        if guide.scene == nil { buildGuide(); arView.scene.addAnchor(guide) }
        placed = true
        updateVisibility(along: r.project(user).along)
        wlog("[AR] rute diletakkan: \(Int(r.length)) m ke \(destination), \(items.count) objek, tanah \(groundFound ? "terdeteksi" : "perkiraan")")
    }

    // MARK: Panah penunjuk arah

    private func buildGuide() {
        let blue = SimpleMaterial(color: UIColor(red: 0.16, green: 0.55, blue: 1, alpha: 1), roughness: 0.25, isMetallic: false)
        let white = SimpleMaterial(color: .white, roughness: 0.3, isMetallic: false)
        // Batang + kepala panah, menunjuk ke -Z (arah "depan" untuk look(at:)).
        let shaft = ModelEntity(mesh: .generateBox(width: 0.07, height: 0.04, depth: 0.32, cornerRadius: 0.02), materials: [blue])
        shaft.position = [0, 0, 0.06]
        let head = ModelEntity(mesh: .generateCone(height: 0.2, radius: 0.12), materials: [blue])
        head.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        head.position = [0, 0, -0.18]
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: 0.24), materials: [white])
        ring.position = [0, -0.04, 0]
        ring.components.set(OpacityComponent(opacity: 0.35))
        for e in [ring, shaft, head] { guideArrow.addChild(e) }
        guide.addChild(guideArrow)
    }

    /// Tiap frame: panah ditaruh ±1,3 m di depan kamera (sedikit di bawah pandangan),
    /// lalu diputar menghadap titik rute 6 m di depan posisi pengguna.
    private func updateGuide(frame: ARFrame, route: Route, anchor: AnchorEntity, along: Float, remaining: Float) {
        let t = frame.camera.transform
        let camPos = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var forward = -SIMD3(t.columns.2.x, 0, t.columns.2.z)
        if simd_length(forward) < 0.01 { forward = [0, 0, -1] }
        forward = simd_normalize(forward)
        let pos = camPos + forward * 1.3 + [0, -0.35, 0]

        let lookAhead = remaining < 6 ? route.length : along + 6
        let local = route.position(at: lookAhead)
        let target = anchor.convert(position: local, to: nil)
        let flatTarget = SIMD3(target.x, pos.y, target.z)

        guideArrow.position = pos
        if simd_distance(flatTarget, pos) > 0.05 {
            let wanted = guideArrow.orientation
            guideArrow.look(at: flatTarget, from: pos, relativeTo: nil)
            // Haluskan putaran supaya panah tidak bergetar.
            guideArrow.orientation = simd_slerp(wanted, guideArrow.orientation, 0.25)
        }

        // Label di atas panah: aksi berikutnya.
        let text: String
        if remaining < 3 { text = "Tiba" }
        else if let next = route.maneuvers.first(where: { $0.at > along + 1 }), next.at - along < 25 {
            text = "\(Int(next.at - along)) m · \(next.left ? "kiri" : "kanan")"
        } else { text = "Lurus \(Int(min(remaining, (route.maneuvers.first { $0.at > along + 1 }?.at ?? route.length) - along))) m" }
        if text != guideText {
            guideText = text
            guideLabel.removeFromParent()
            guideLabel = Self.floatingLabel(text)
            guide.addChild(guideLabel)
        }
        guideLabel.position = pos + [0, 0.2, 0]
    }

    private static func floatingLabel(_ text: String) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.003, font: .systemFont(ofSize: 0.07, weight: .heavy), alignment: .center)
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let b = label.visualBounds(relativeTo: nil)
        label.position = [-b.center.x, -b.center.y, 0.005]
        let plate = ModelEntity(mesh: .generatePlane(width: b.extents.x + 0.06, height: b.extents.y + 0.04, cornerRadius: 0.02),
                                materials: [UnlitMaterial(color: UIColor(red: 0.16, green: 0.55, blue: 1, alpha: 1))])
        let holder = Entity()
        holder.addChild(plate); holder.addChild(label)
        holder.components.set(BillboardComponent())
        return holder
    }

    /// Hanya bagian rute di depan pengguna yang tampil; yang jauh memudar.
    private func updateVisibility(along: Float) {
        for item in items {
            let delta = item.at - along
            let visible = delta > -3 && delta < item.ahead
            item.entity.isEnabled = visible
            if visible {
                let fade = max(0.25, min(1, 1 - (delta - item.ahead * 0.6) / (item.ahead * 0.4)))
                item.entity.components.set(OpacityComponent(opacity: fade))
            }
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Pakai bidang horizontal pertama di bawah kamera sebagai tanah.
        guard !groundFound, let frame = session.currentFrame else { return }
        let camY = frame.camera.transform.columns.3.y
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            if camY - y > 0.4 && camY - y < 2.0 {
                groundOffset = camY - y
                groundFound = true
                wlog(String(format: "[AR] tanah terdeteksi, HP %.2f m di atas tanah", groundOffset))
                if let anchor { anchor.position.y = y }
                break
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let route, let anchor else { return }
        let cam = frame.camera.transform.columns.3
        let moved = SIMD2(cam.x - cameraAtCalibration.x, cam.z - cameraAtCalibration.z)
        let user = userAtCalibration + moved
        let (along, off) = route.project(user)
        let remaining = max(0, route.length - along)
        updateGuide(frame: frame, route: route, anchor: anchor, along: along, remaining: remaining)

        guard Date.now.timeIntervalSince(lastHUD) > 0.25 else { return }
        lastHUD = .now

        if remaining < 3 {
            headline = "Sampai di \(destinationName)"
            subline = "Rute selesai"
        } else if let next = route.maneuvers.first(where: { $0.at > along + 1 }) {
            headline = "\(Int(next.at - along)) m · Belok \(next.left ? "kiri" : "kanan")"
            subline = "Sisa \(Int(remaining)) m" + (off > 6 ? " · kamu \(Int(off)) m di luar rute" : "")
        } else {
            headline = "Lurus \(Int(remaining)) m"
            subline = off > 6 ? "Kamu \(Int(off)) m di luar rute" : "Ikuti panah biru"
        }
        if frame.camera.trackingState != .normal { subline = "Pelacakan kamera lemah — gerakkan HP pelan-pelan" }
        updateVisibility(along: along)
        if Date.now.timeIntervalSince(lastLog) > 2 {
            lastLog = .now
            wlog("[AR] jalan \(Int(along)) m, sisa \(Int(remaining)) m, keluar rute \(Int(off)) m, tracking \(frame.camera.trackingState)")
        }
    }

    // MARK: Entities

    private static func chevron(at p: SIMD3<Float>, toward q: SIMD3<Float>) -> Entity {
        let holder = Entity()
        var material = UnlitMaterial(color: UIColor(red: 0.18, green: 0.48, blue: 1, alpha: 1))
        material.blending = .transparent(opacity: 0.85)
        for side: Float in [-1, 1] {
            let arm = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.02, depth: 0.55, cornerRadius: 0.01),
                                  materials: [material])
            arm.position = [side * 0.17, 0, 0.1]
            arm.orientation = simd_quatf(angle: side * .pi / 5, axis: [0, 1, 0])
            holder.addChild(arm)
        }
        holder.position = p + [0, 0.03, 0]
        holder.look(at: q + [0, 0.03, 0], from: holder.position, relativeTo: nil)
        return holder
    }

    private static func ribbon(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Entity {
        let len = simd_distance(a, b)
        var material = UnlitMaterial(color: UIColor(red: 0.18, green: 0.48, blue: 1, alpha: 1))
        material.blending = .transparent(opacity: 0.35)
        let seg = ModelEntity(mesh: .generateBox(width: 0.5, height: 0.01, depth: max(len, 0.05) + 0.05), materials: [material])
        seg.position = (a + b) / 2 + [0, 0.015, 0]
        if len > 0.01 { seg.look(at: b + [0, 0.015, 0], from: seg.position, relativeTo: nil) }
        return seg
    }

    private static func sign(_ text: String, color: UIColor, at p: SIMD3<Float>, height: Float) -> Entity {
        let holder = Entity()
        let pole = ModelEntity(mesh: .generateCylinder(height: height, radius: 0.025),
                               materials: [UnlitMaterial(color: .white)])
        pole.position.y = height / 2
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.005,
                                             font: .systemFont(ofSize: 0.14, weight: .heavy), alignment: .center)
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let b = label.visualBounds(relativeTo: nil)
        label.position = [-b.center.x, -b.center.y, 0.01]
        let plate = ModelEntity(mesh: .generatePlane(width: b.extents.x + 0.12, height: b.extents.y + 0.08, cornerRadius: 0.04),
                                materials: [UnlitMaterial(color: color)])
        let board = Entity()
        board.addChild(plate); board.addChild(label)
        board.position.y = height + 0.1
        board.components.set(BillboardComponent())
        holder.addChild(pole); holder.addChild(board)
        holder.position = p
        return holder
    }
}

struct ARContainer: UIViewRepresentable {
    let controller: ARNavController
    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ view: ARView, context: Context) {}
}

struct ARNavView: View {
    private static let graph = WorldData.bsd.graph
    private static let simStart = SIMD2(WorldData.bsd.route[0][0], WorldData.bsd.route[0][1])

    @State private var controller = ARNavController()
    @State private var location = LocationService(origin: WorldData.bsd.origin)
    @State private var conditions = ConditionStore(graph: WorldData.bsd.graph)
    /// Mode uji: rute GOP → The Breeze diletakkan mulai dari tempatmu berdiri, di mana pun kamu berada.
    @State private var anywhere: Bool
    @State private var placed = false
    /// Posisi pengguna di peta saat AR dibuka dari peta 3D.
    private let start: SIMD2<Float>?
    private let destination: Place
    @Environment(\.dismiss) private var dismiss

    /// false = hanya GPS asli (dibuka dari navigasi lapangan); sakelar "Uji di mana saja" disembunyikan.
    private let allowTestMode: Bool

    init(start: SIMD2<Float>? = nil, destination: Place = .breeze, anywhere: Bool = true, allowTestMode: Bool = true) {
        self.start = start
        self.destination = destination
        self.allowTestMode = allowTestMode
        _anywhere = State(initialValue: anywhere && allowTestMode)
    }

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            ContentUnavailableView("AR butuh iPhone asli",
                                   systemImage: "arkit",
                                   description: Text("Simulator tidak punya kamera dan sensor gerak. Pasang aplikasi ini ke iPhone lewat Xcode untuk mencoba navigasi AR."))
            #else
            ARContainer(controller: controller).ignoresSafeArea()
            #endif
        }
        .overlay(alignment: .top) {
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Label("Kembali ke peta", systemImage: "map.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(.horizontal)
                hud
            }
        }
        .overlay(alignment: .bottom) { controls }
        .onAppear {
            #if !targetEnvironment(simulator)
            controller.start()
            location.start()
            wlog("[AR] dibuka, tujuan \(destination.name), mode \(anywhere ? "uji di mana saja" : "GPS")")
            #endif
        }
        .onDisappear {
            controller.pause()
            location.stop()
        }
        // Di area peta dengan GPS: rute diletakkan otomatis begitu tanah terdeteksi (atau setelah 4 detik).
        .onChange(of: controller.groundFound) { _, found in autoPlace(found) }
        .task {
            try? await Task.sleep(for: .seconds(4))
            autoPlace(true)
        }
    }

    private var hud: some View {
        HStack(spacing: 14) {
            Image(systemName: placed ? "arrow.up" : "viewfinder")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(placed ? controller.headline : "Siap meletakkan rute").font(.title3.bold())
                Text(placed ? controller.subline : startHint).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal)
    }

    private var startHint: String {
        if anywhere { return "Rute akan dimulai dari tempatmu berdiri, arah mengikuti kompas asli" }
        guard let p = location.local else { return "Mencari sinyal GPS…" }
        let s = WorldData.bsd.snapshot
        let inside = p.x > s.min[0] && p.x < s.max[0] && p.y > s.min[1] && p.y < s.max[1]
        return inside ? "Kamu di area \(AreaConfig.current.coverage)" : "Kamu di luar area demo — pakai mode uji"
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if allowTestMode {
                Toggle("Uji di mana saja", isOn: $anywhere)
                    .font(.subheadline.weight(.semibold))
            }
            Button {
                placeRoute()
            } label: {
                Label(placed ? "Kalibrasi ulang" : "Letakkan rute", systemImage: placed ? "scope" : "mappin.and.ellipse")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!anywhere && location.local == nil)
            Text("Pegang HP dengan aman. Saat mendorong kursi roda, cukup dengarkan instruksi; angkat HP hanya untuk mengintip.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func autoPlace(_ ready: Bool) {
        guard ready, !placed, !anywhere, location.local != nil else { return }
        placeRoute()
    }

    private func placeRoute() {
        // Mode uji: posisi diambil dari peta (atau titik mulai), jadi rute muncul di depanmu di mana pun kamu berada.
        let user = anywhere ? (start ?? Self.simStart) : (location.local ?? start ?? Self.simStart)
        let plan = Self.graph.plan(from: user, to: destination.point,
                                   cost: { conditions.cost($0) },
                                   condition: { conditions.report($0).condition })
        guard let plan else { return }
        controller.place(plan: plan, user: user, destination: destination.name, graph: Self.graph, condition: { conditions.report($0).condition })
        placed = true
    }
}

#Preview { ARNavView() }
