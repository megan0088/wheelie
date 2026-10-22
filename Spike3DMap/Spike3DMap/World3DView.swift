// SPIKE — throwaway. Dunia 3D bergaya Pokémon GO di RealityKit:
// tanah digambar ulang jadi warna kartun (rumput/plaza/air) dari foto satelit,
// pohon low-poly ditaruh di area hijau, gedung OSM pastel, avatar kursi roda chibi.

import SwiftUI
import RealityKit
import MapKit
import AVFoundation
import Combine

// MARK: - Data

struct WorldData: Decodable {
    struct Building: Decodable { let name: String; let h: Float; let pts: [[Float]] }
    struct Way: Decodable { let kind: String; let pts: [[Float]] }
    struct POI: Decodable { let name: String; let kind: String; let p: [Float] }
    struct Snapshot: Decodable {
        let minLat, maxLat, minLon, maxLon: Double
        let min: [Float]; let max: [Float]
    }
    let snapshot: Snapshot
    let buildings: [Building]
    let paths: [Way]
    let areas: [Way]
    let pois: [POI]
    let route: [[Float]]
    let origin: [Double]
    let graph: WalkGraph

    static let bsd: WorldData = {
        let url = Bundle.main.url(forResource: "bsd", withExtension: "json")!
        return try! JSONDecoder().decode(WorldData.self, from: Data(contentsOf: url))
    }()
}

/// Pengaturan area demo (BSD/GOP atau Bogor), dibundel per target sebagai area.json.
struct AreaConfig: Decodable {
    let name: String
    let center: [Double]
    let span: Double
    let defaultDestination: String
    let startLabel: String
    let coverage: String
    /// Dunia 3D dimatikan untuk area besar (terlalu berat di HP).
    let has3D: Bool?
    /// Tanggal data peta (OSM) saat bundel dibuat, "yyyy-MM-dd".
    let dataUpdated: String?

    static let current: AreaConfig = {
        let url = Bundle.main.url(forResource: "area", withExtension: "json")!
        return try! JSONDecoder().decode(AreaConfig.self, from: Data(contentsOf: url))
    }()
}

/// Tempat yang tercatat ramah kursi roda (OSM / sumber resmi). `inArea` = bisa dirute di peta GOP.
struct Place: Decodable, Identifiable, Hashable {
    let name: String
    let kind: String
    let wheelchair: String
    let source: String
    let p: [Float]
    let inArea: Bool
    let lat: Double
    let lon: Double
    let toilet: String
    let lift: String
    let hours: String?
    let street: String?
    let updated: String?
    var id: String { name }
    var point: SIMD2<Float> { SIMD2(p[0], p[1]) }

    static let all: [Place] = {
        let url = Bundle.main.url(forResource: "tempat", withExtension: "json")!
        return try! JSONDecoder().decode([Place].self, from: Data(contentsOf: url))
    }()
    /// Tujuan bawaan area (The Breeze di BSD, Taman Kencana di Bogor).
    static let breeze = all.first { $0.name == AreaConfig.current.defaultDestination } ?? all[0]

    var statusText: String {
        switch wheelchair {
        case "yes", "designated": "Aksesibel"
        case "limited": "Aksesibel sebagian"
        default: "Belum ada data"
        }
    }
}

/// Rute yang sudah diukur: titik-titik + jarak kumulatif + daftar belokan.
struct Route {
    struct Maneuver { let at: Float; let left: Bool; let sharp: Bool }

    let points: [SIMD3<Float>]
    let cumulative: [Float]
    let maneuvers: [Maneuver]
    var length: Float { cumulative.last ?? 0 }

    init(_ raw: [[Float]]) {
        points = raw.map { SIMD3($0[0], 0, $0[1]) }
        var c: [Float] = [0]
        for (a, b) in zip(points, points.dropFirst()) { c.append(c.last! + simd_distance(a, b)) }
        cumulative = c

        // Belokan = perubahan arah > 35° di satu titik. x = timur, z = selatan.
        var m: [Maneuver] = []
        for i in 1..<max(1, points.count - 1) {
            let d1 = points[i] - points[i - 1], d2 = points[i + 1] - points[i]
            let e1 = SIMD2(d1.x, -d1.z), e2 = SIMD2(d2.x, -d2.z)
            let angle = atan2(e1.x * e2.y - e1.y * e2.x, simd_dot(e1, e2)) * 180 / .pi
            if abs(angle) > 35 { m.append(.init(at: c[i], left: angle > 0, sharp: abs(angle) > 100)) }
        }
        maneuvers = m
    }

    /// Titik terdekat di rute: jarak dari awal rute, dan seberapa jauh kita keluar dari rute.
    func project(_ p: SIMD2<Float>) -> (along: Float, off: Float) {
        var best = (along: Float(0), off: Float.greatestFiniteMagnitude)
        for i in 0..<(points.count - 1) {
            let a = SIMD2(points[i].x, points[i].z), b = SIMD2(points[i + 1].x, points[i + 1].z)
            let ab = b - a, t = simd_clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 0.0001), 0, 1)
            let off = simd_distance(p, a + ab * t)
            if off < best.off { best = (cumulative[i] + t * simd_length(ab), off) }
        }
        return best
    }

    func position(at d: Float) -> SIMD3<Float> {
        let d = min(max(d, 0), length)
        let i = max(0, (cumulative.firstIndex { $0 >= d } ?? cumulative.count - 1) - 1)
        let span = cumulative[i + 1] - cumulative[i]
        return simd_mix(points[i], points[i + 1], SIMD3(repeating: span > 0 ? (d - cumulative[i]) / span : 0))
    }
}

/// Seluruh segmen jalur dari OSM, termasuk tangga dan jalan mobil.
struct WalkGraph: Decodable {
    let nodes: [[Float]]
    let edges: [[Int]]
    let kinds: [String]
    let goal: Int
    // Opsional (area yang dibuat export_aplikasi.py, mis. Blok M): perkiraan status dari OSM + BIG per segmen.
    let status: [String]?
    let factor: [Float?]?
    let reasons: [String]?
    /// Id way OSM per segmen — kunci hasil survei supaya tetap menempel saat graf dibuat ulang.
    let osmWay: [Int]?
    /// Nama jalan per segmen (kosong kalau tidak bernama), untuk banner navigasi.
    let names: [String]?

    static let roadKinds: Set<String> = ["service", "residential", "tertiary", "unclassified", "secondary", "primary"]

    struct Plan {
        let route: Route
        let edges: [Int]
        let unknownMeters: Float
        let cautionMeters: Float
    }

    func point(_ i: Int) -> SIMD2<Float> { SIMD2(nodes[i][0], nodes[i][1]) }
    func length(_ e: Int) -> Float { simd_distance(point(edges[e][0]), point(edges[e][1])) }

    /// Dijkstra dari node terdekat ke `p` menuju node terdekat ke `target`. `cost` = pengali jarak per segmen, nil = tertutup.
    func plan(from p: SIMD2<Float>, to target: SIMD2<Float>, cost: (Int) -> Float?, condition: (Int) -> Condition) -> Plan? {
        var adj = [[(node: Int, edge: Int, w: Float)]](repeating: [], count: nodes.count)
        for (i, e) in edges.enumerated() {
            guard let c = cost(i) else { continue }
            let w = length(i) * c
            adj[e[0]].append((e[1], i, w)); adj[e[1]].append((e[0], i, w))
        }
        let reachable = nodes.indices.filter { !adj[$0].isEmpty }
        guard !reachable.isEmpty else { return nil }

        func dijkstra(_ from: Int) -> (dist: [Float], via: [(node: Int, edge: Int)?]) {
            var dist = [Float](repeating: .infinity, count: nodes.count)
            var via = [(node: Int, edge: Int)?](repeating: nil, count: nodes.count)
            var done = [Bool](repeating: false, count: nodes.count)
            var heap = MinHeap()
            heap.push(0, from)
            dist[from] = 0
            while let (d, u) = heap.pop() {
                if done[u] || d > dist[u] { continue }
                done[u] = true
                for n in adj[u] where d + n.w < dist[n.node] {
                    dist[n.node] = d + n.w; via[n.node] = (u, n.edge)
                    heap.push(dist[n.node], n.node)
                }
            }
            return (dist, via)
        }

        // Titik jalur terdekat bisa saja potongan jalan yang tidak tersambung (data OSM terputus).
        // Coba beberapa titik terdekat sampai ada yang tersambung ke tujuan.
        let byStart = reachable.sorted { simd_distance(point($0), p) < simd_distance(point($1), p) }
        let byGoal = reachable.sorted { simd_distance(point($0), target) < simd_distance(point($1), target) }
        var start = byStart[0], goal = byGoal[0]
        var result = dijkstra(start)
        var found = result.dist[goal] < .infinity
        for candidate in byStart.prefix(12).dropFirst() where !found && simd_distance(point(candidate), p) < 120 {
            let r = dijkstra(candidate)
            if r.dist[goal] < .infinity { start = candidate; result = r; found = true }
        }
        if !found {
            // Tujuan tidak terjangkau: pakai titik terjangkau yang paling dekat ke tujuan.
            guard let alt = byGoal.prefix(40).first(where: { result.dist[$0] < .infinity }) else { return nil }
            goal = alt
        }
        let via = result.via

        var nodePath = [goal], edgePath: [Int] = []
        while let v = via[nodePath.last!] { edgePath.append(v.edge); nodePath.append(v.node) }
        nodePath.reverse(); edgePath.reverse()

        // Di jalan mobil, rute digeser ke tepi (sisi trotoar) — bukan di tengah jalan.
        var pts = nodePath.map(point)
        let onRoad = edgePath.map { Self.roadKinds.contains(kinds[$0]) }
        var shifted = pts
        for i in pts.indices {
            var normal = SIMD2<Float>.zero
            for (seg, road) in [(i - 1, i > 0 ? onRoad[i - 1] : false), (i, i < onRoad.count ? onRoad[i] : false)] where road {
                let d = simd_normalize(pts[seg + 1] - pts[seg])
                normal += SIMD2(d.y, -d.x)
            }
            if simd_length(normal) > 0.01 { shifted[i] = pts[i] + simd_normalize(normal) * 3.5 }
        }
        pts = shifted
        if simd_distance(p, pts[0]) > 1 { pts.insert(p, at: 0) }
        if pts.count < 2 { pts.append(pts[0]) }

        var unknown: Float = 0, caution: Float = 0
        for e in edgePath {
            switch condition(e) {
            case .belumDicek: unknown += length(e)
            case .hatiHati: caution += length(e)
            default: break
            }
        }
        return Plan(route: Route(pts.map { [$0.x, $0.y] }), edges: edgePath, unknownMeters: unknown, cautionMeters: caution)
    }
}

/// Antrian prioritas sederhana untuk Dijkstra.
struct MinHeap {
    private var items: [(Float, Int)] = []
    mutating func push(_ key: Float, _ value: Int) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].0 <= items[i].0 { break }
            items.swapAt(parent, i); i = parent
        }
    }
    mutating func pop() -> (Float, Int)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count && items[l].0 < items[m].0 { m = l }
            if r < items.count && items[r].0 < items[m].0 { m = r }
            if m == i { break }
            items.swapAt(i, m); i = m
        }
        return top
    }
}

// MARK: - Palette

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private enum Palette {
    static let grass: (UInt8, UInt8, UInt8) = (124, 214, 120)
    static let plaza: (UInt8, UInt8, UInt8) = (214, 236, 170)
    static let water: (UInt8, UInt8, UInt8) = (96, 196, 240)
    static let road = UIColor(hex: 0xF8F6EC)
    static let path = UIColor(hex: 0xFFFFFF, alpha: 0.9)
    static let route = UIColor(hex: 0x2F7BFF)
    static let buildings: [UIColor] = [0xF4EBDD, 0xE4EEF8, 0xF6E2D8, 0xECE6F7, 0xE6F2E6].map { UIColor(hex: $0) }
}

// MARK: - Style

/// Dua gaya untuk dunia yang sama: kartun ala Pokémon GO, atau peta navigasi biasa.
enum WorldStyle {
    case game, biasa

    var grass: (UInt8, UInt8, UInt8) { self == .game ? Palette.grass : (196, 226, 184) }
    var plaza: (UInt8, UInt8, UInt8) { self == .game ? Palette.plaza : (238, 236, 230) }
    var water: (UInt8, UInt8, UInt8) { self == .game ? Palette.water : (156, 206, 240) }
    var buildings: [UIColor] {
        self == .game ? Palette.buildings : [0xDCDDE2, 0xE2E3E8, 0xD6D8DE].map { UIColor(hex: $0) }
    }
    var crowns: [UInt32] { self == .game ? [0x4FB35A, 0x3FA14D, 0x63C066] : [0x9CCB8E, 0x8DBF80, 0xA8D29B] }
    var treeChance: Float { self == .game ? 0.45 : 0.22 }
    var sky: (top: Color, bottom: Color) {
        self == .game ? (Color(red: 0.45, green: 0.75, blue: 0.98), Color(red: 0.86, green: 0.95, blue: 0.99))
                      : (Color(red: 0.78, green: 0.86, blue: 0.94), Color(red: 0.95, green: 0.96, blue: 0.97))
    }
}

// MARK: - Scene

@MainActor
final class WorldScene {
    let root = Entity()
    let camera = PerspectiveCamera()
    let avatar = Entity()
    private(set) var route: Route
    private var routeEntity = Entity()

    private var wheels: [Entity] = []
    private let pulse = Entity()
    private var spots: [(entity: Entity, cube: Entity, label: Entity)] = []
    private var goalSpinner = Entity()
    private var buildingFootprints: [[SIMD2<Float>]] = []
    private var buildingEntities: [(entity: Entity, footprint: [SIMD2<Float>])] = []
    private var roadSegments: [(SIMD2<Float>, SIMD2<Float>)] = []

    private var eye: SIMD3<Float>?
    private var target = SIMD3<Float>.zero
    private var facing = SIMD3<Float>(0, 0, -1)
    private var time: Float = 0

    let style: WorldStyle

    init(data: WorldData, style: WorldStyle = .game) {
        self.style = style
        route = Route(data.route)
        camera.camera.fieldOfViewInDegrees = 50

        // Tanah dasar luas, supaya tepi area tidak terlihat.
        let base = ModelEntity(mesh: .generatePlane(width: 4000, depth: 4000),
                               materials: [SimpleMaterial(color: UIColor(red: CGFloat(style.grass.0) / 255,
                                                                         green: CGFloat(style.grass.1) / 255,
                                                                         blue: CGFloat(style.grass.2) / 255, alpha: 1),
                                                          roughness: 1, isMetallic: false)])
        base.position.y = -0.05
        root.addChild(base)

        for a in data.areas { if let e = Self.flatArea(a) { root.addChild(e) } }
        for w in data.paths where w.kind != "steps" {
            let width: Float = switch w.kind {
                case "primary", "secondary", "trunk": 9
                case "service", "residential", "tertiary": 5
                default: 1.8
            }
            let pts = w.pts.map { SIMD3($0[0], width > 2 ? 0.03 : 0.06, $0[1]) }
            root.addChild(Self.strip(pts, width: width, color: width > 2 ? Palette.road : Palette.path))
            for (a, b) in zip(pts, pts.dropFirst()) { roadSegments.append((SIMD2(a.x, a.z), SIMD2(b.x, b.z))) }
        }
        for w in data.paths where w.kind == "steps" {
            let pts = w.pts.map { SIMD3($0[0], 0.08, $0[1]) }
            root.addChild(Self.warningSign(at: pts[pts.count / 2]))
        }
        root.addChild(routeEntity)
        setRoute(route)
        root.addChild(conditionLayer)
        root.addChild(selection)

        for (i, b) in data.buildings.enumerated() {
            buildingFootprints.append(b.pts.map { SIMD2($0[0], $0[1]) })
            if let e = Self.building(b, color: style.buildings[i % style.buildings.count]) {
                root.addChild(e)
                buildingEntities.append((e, buildingFootprints.last!))
            }
        }
        for poi in data.pois { addSpot(poi) }
        root.addChild(goalHolder)
        setGoal(at: route.points.last!, name: AreaConfig.current.defaultDestination)
        if style == .game { buildAvatar() } else { buildPuck() }

        let sun = DirectionalLight()
        sun.light.intensity = 3200
        sun.light.color = UIColor(hex: 0xFFF6E8)
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 160, depthBias: 2)
        sun.look(at: .zero, from: [120, 220, 70], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 1500
        fill.light.color = UIColor(hex: 0xDDE8FF)
        fill.look(at: .zero, from: [-120, 90, -100], relativeTo: nil)
        root.addChild(sun); root.addChild(fill)
        root.addChild(camera)
    }

    // MARK: Stylized ground + trees

    /// Foto satelit hanya dipakai sebagai "contekan": tiap piksel digolongkan jadi
    /// rumput / plaza / air, lalu digambar ulang dengan warna kartun. Area hijau ditanami pohon.
    func loadGround(_ s: WorldData.Snapshot) async {
        let width = s.max[0] - s.min[0], depth = s.max[1] - s.min[1]
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: .init(latitude: (s.minLat + s.maxLat) / 2, longitude: (s.minLon + s.maxLon) / 2),
            span: .init(latitudeDelta: s.maxLat - s.minLat, longitudeDelta: s.maxLon - s.minLon))
        options.preferredConfiguration = MKImageryMapConfiguration()
        options.size = CGSize(width: 1024, height: CGFloat(1024 * depth / width))
        options.scale = 1
        guard let photo = try? await MKMapSnapshotter(options: options).start().image.cgImage else { return }

        let w = 384, h = Int((Float(w) * depth / width).rounded())
        let colors = (style.grass, style.plaza, style.water)
        let result = await Task.detached { Self.stylize(photo, width: w, height: h, colors: colors) }.value
        guard let (image, classes) = result,
              let texture = try? await TextureResource(image: image, options: .init(semantic: .color))
        else { return }

        var material = SimpleMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.roughness = 1
        let ground = ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [material])
        ground.position = [(s.min[0] + s.max[0]) / 2, 0, (s.min[1] + s.max[1]) / 2]
        root.addChild(ground)

        plantTrees(classes: classes, w: w, h: h, origin: SIMD2(s.min[0], s.min[1]), size: SIMD2(width, depth))
    }

    typealias RGB = (UInt8, UInt8, UInt8)

    nonisolated private static func stylize(_ photo: CGImage, width w: Int, height h: Int,
                                            colors: (grass: RGB, plaza: RGB, water: RGB)) -> (CGImage, [UInt8])? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // 0 = plaza, 1 = rumput, 2 = air
        var classes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            if b > r + 18 && b > g && b > 80 { classes[i] = 2 }
            else if g > r + 4 && g + 6 >= b { classes[i] = 1 }
        }
        // Haluskan (mayoritas 5×5) supaya bentuknya membulat seperti kartun.
        var smooth = classes
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) {
                var count = (0, 0, 0)
                for dy in -2...2 { for dx in -2...2 {
                    switch classes[(y + dy) * w + x + dx] {
                    case 1: count.1 += 1
                    case 2: count.2 += 1
                    default: count.0 += 1
                    }
                } }
                smooth[y * w + x] = count.2 >= 9 ? 2 : (count.1 >= 11 ? 1 : 0)
            }
        }
        for i in 0..<(w * h) {
            let c = smooth[i] == 1 ? colors.grass : (smooth[i] == 2 ? colors.water : colors.plaza)
            px[i * 4] = c.0; px[i * 4 + 1] = c.1; px[i * 4 + 2] = c.2; px[i * 4 + 3] = 255
        }
        guard let image = ctx.makeImage() else { return nil }
        return (image, smooth)
    }

    private func plantTrees(classes: [UInt8], w: Int, h: Int, origin: SIMD2<Float>, size: SIMD2<Float>) {
        let trunkMesh = MeshResource.generateCylinder(height: 1.6, radius: 0.28)
        let crownMesh = MeshResource.generateSphere(radius: 1.0)
        let trunkMat = SimpleMaterial(color: UIColor(hex: 0x9A6B47), roughness: 1, isMetallic: false)
        let crownMats = style.crowns.map {
            SimpleMaterial(color: UIColor(hex: $0), roughness: 0.9, isMetallic: false)
        }
        let trees = Entity()
        let cell: Float = 8
        var seed: UInt64 = 42
        func rand() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }

        var z = origin.y + cell / 2
        while z < origin.y + size.y {
            var x = origin.x + cell / 2
            while x < origin.x + size.x {
                let p = SIMD2(x + (rand() - 0.5) * cell * 0.8, z + (rand() - 0.5) * cell * 0.8)
                let col = Int((p.x - origin.x) / size.x * Float(w)), row = Int((p.y - origin.y) / size.y * Float(h))
                if rand() < style.treeChance, (0..<w).contains(col), (0..<h).contains(row), classes[row * w + col] == 1,
                   !isBlocked(p) {
                    let tree = Entity()
                    let s = 0.8 + rand() * 0.7
                    let trunk = ModelEntity(mesh: trunkMesh, materials: [trunkMat])
                    trunk.position.y = 0.8
                    let crown = ModelEntity(mesh: crownMesh, materials: [crownMats[Int(rand() * 3) % 3]])
                    crown.position.y = 2.6
                    crown.scale = [2.1, 1.9, 2.1]
                    tree.addChild(trunk); tree.addChild(crown)
                    tree.position = [p.x, 0, p.y]
                    tree.scale = .init(repeating: s)
                    trees.addChild(tree)
                }
                x += cell
            }
            z += cell
        }
        root.addChild(trees)
    }

    /// Pohon tidak boleh tumbuh di dalam gedung atau di atas jalan.
    private func isBlocked(_ p: SIMD2<Float>) -> Bool {
        for (a, b) in roadSegments {
            let ab = b - a, t = simd_clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 0.001), 0, 1)
            if simd_distance(p, a + ab * t) < 4.5 { return true }
        }
        for poly in buildingFootprints where Self.contains(poly, p) { return true }
        return false
    }

    private static func contains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false, j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: Avatar

    private func buildAvatar() {
        let blue = SimpleMaterial(color: UIColor(hex: 0x2F7BFF), roughness: 0.4, isMetallic: false)
        let dark = SimpleMaterial(color: UIColor(hex: 0x2B2F3A), roughness: 0.6, isMetallic: false)
        let light = SimpleMaterial(color: UIColor(hex: 0xE9EEF5), roughness: 0.5, isMetallic: false)
        let shirt = SimpleMaterial(color: UIColor(hex: 0xFF8A3D), roughness: 0.7, isMetallic: false)
        let skin = SimpleMaterial(color: UIColor(hex: 0xE8B48A), roughness: 0.7, isMetallic: false)
        let cap = SimpleMaterial(color: UIColor(hex: 0xE53950), roughness: 0.6, isMetallic: false)

        let body = Entity()
        func part(_ mesh: MeshResource, _ m: SimpleMaterial, _ p: SIMD3<Float>) -> ModelEntity {
            let e = ModelEntity(mesh: mesh, materials: [m]); e.position = p; body.addChild(e); return e
        }
        // Roda besar dengan jari-jari, supaya putarannya kelihatan.
        for side: Float in [-0.78, 0.78] {
            let spinner = Entity()
            spinner.position = [side, 0.9, 0.05]
            let tire = ModelEntity(mesh: .generateCylinder(height: 0.16, radius: 0.9), materials: [dark])
            tire.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            let hub = ModelEntity(mesh: .generateCylinder(height: 0.2, radius: 0.62), materials: [light])
            hub.orientation = tire.orientation
            spinner.addChild(tire); spinner.addChild(hub)
            for a: Float in [0, .pi / 2] {
                let spoke = ModelEntity(mesh: .generateBox(width: 0.24, height: 1.3, depth: 0.14), materials: [blue])
                spoke.orientation = simd_quatf(angle: a, axis: [1, 0, 0])
                spinner.addChild(spoke)
            }
            body.addChild(spinner)
            wheels.append(spinner)
        }
        for side: Float in [-0.5, 0.5] { _ = part(.generateSphere(radius: 0.22), dark, [side, 0.22, -0.85]) }
        _ = part(.generateBox(width: 1.3, height: 0.22, depth: 1.1, cornerRadius: 0.08), blue, [0, 1.0, 0])
        _ = part(.generateBox(width: 1.3, height: 1.1, depth: 0.16, cornerRadius: 0.08), blue, [0, 1.6, 0.55])
        _ = part(.generateBox(width: 0.95, height: 0.28, depth: 0.85, cornerRadius: 0.12), dark, [0, 1.2, -0.35])
        _ = part(.generateBox(width: 0.9, height: 0.25, depth: 0.25, cornerRadius: 0.1), dark, [0, 0.75, -0.75])
        _ = part(.generateBox(width: 0.95, height: 0.95, depth: 0.6, cornerRadius: 0.28), shirt, [0, 1.65, 0.15])
        _ = part(.generateSphere(radius: 0.55), skin, [0, 2.5, 0.1])
        let capTop = part(.generateSphere(radius: 0.57), cap, [0, 2.68, 0.1])
        capTop.scale = [1, 0.55, 1]
        _ = part(.generateBox(width: 0.6, height: 0.06, depth: 0.45, cornerRadius: 0.03), cap, [0, 2.66, -0.4])
        body.scale = .init(repeating: 1.35)
        avatar.addChild(body)

        // Lingkaran radius di kaki, seperti Pokémon GO.
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 14),
                               materials: [WorldScene.unlit( UIColor(white: 1, alpha: 0.16))])
        ring.position.y = 0.18
        avatar.addChild(ring)
        let ripple = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 1),
                                 materials: [WorldScene.unlit( UIColor(white: 1, alpha: 0.35))])
        pulse.addChild(ripple)
        pulse.position.y = 0.2
        avatar.addChild(pulse)
        root.addChild(avatar)
    }

    /// Penanda lokasi ala peta biasa: titik biru dengan arah hadap.
    private func buildPuck() {
        let blue = UIColor(hex: 0x1E7BFF)
        let rim = ModelEntity(mesh: .generateCylinder(height: 0.25, radius: 1.5),
                              materials: [SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)])
        rim.position.y = 0.3
        let dot = ModelEntity(mesh: .generateCylinder(height: 0.3, radius: 1.1),
                              materials: [SimpleMaterial(color: blue, roughness: 0.3, isMetallic: false)])
        dot.position.y = 0.34
        // Kerucut arah hadap (diamond pipih di depan titik).
        let beam = ModelEntity(mesh: .generateBox(width: 2.2, height: 0.04, depth: 2.2),
                               materials: [WorldScene.unlit(blue.withAlphaComponent(0.35))])
        beam.orientation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
        beam.position = [0, 0.2, -2.1]
        for e in [beam, rim, dot] { avatar.addChild(e) }
        let ripple = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 1),
                                 materials: [WorldScene.unlit(blue.withAlphaComponent(0.25))])
        pulse.addChild(ripple)
        pulse.position.y = 0.18
        avatar.addChild(pulse)
        root.addChild(avatar)
    }

    // MARK: Spots

    private func addSpot(_ poi: WorldData.POI) {
        if style == .biasa {
            let holder = Entity()
            let pin = ModelEntity(mesh: .generateSphere(radius: 0.7),
                                  materials: [SimpleMaterial(color: UIColor(hex: 0x8E8E93), roughness: 0.4, isMetallic: false)])
            pin.position.y = 1.6
            let stem = ModelEntity(mesh: .generateCylinder(height: 1.2, radius: 0.12),
                                   materials: [SimpleMaterial(color: UIColor(hex: 0x8E8E93), isMetallic: false)])
            stem.position.y = 0.6
            let name = Self.label(poi.name, at: [0, 3.2, 0], size: 0.8)
            name.isEnabled = false
            for e in [stem, pin, name] { holder.addChild(e) }
            holder.position = [poi.p[0], 0, poi.p[1]]
            root.addChild(holder)
            spots.append((holder, pin, name))
            return
        }
        let holder = Entity()
        let pole = ModelEntity(mesh: .generateCylinder(height: 3, radius: 0.12),
                               materials: [SimpleMaterial(color: UIColor(hex: 0x6FA8FF), isMetallic: false)])
        pole.position.y = 1.5
        let color: UInt32 = ["cafe", "restaurant", "fast_food", "ice_cream", "food_court"].contains(poi.kind) ? 0x29B6F6 : 0xAB7BFF
        let cube = ModelEntity(mesh: .generateBox(size: 1.2, cornerRadius: 0.25),
                               materials: [SimpleMaterial(color: UIColor(hex: color), roughness: 0.2, isMetallic: false)])
        cube.position.y = 3.6
        cube.orientation = simd_quatf(angle: .pi / 4, axis: simd_normalize([1, 0, 1]))
        let base = ModelEntity(mesh: .generateCylinder(height: 0.08, radius: 1.3),
                               materials: [WorldScene.unlit( UIColor(hex: color, alpha: 0.5))])
        base.position.y = 0.12
        let name = Self.label(poi.name, at: [0, 5.4, 0], size: 0.9)
        name.isEnabled = false
        for e in [pole, cube, base, name] { holder.addChild(e) }
        holder.position = [poi.p[0], 0, poi.p[1]]
        root.addChild(holder)
        spots.append((holder, cube, name))
    }

    private var goalHolder = Entity()

    func setGoal(at p: SIMD3<Float>, name: String) {
        goalHolder.removeFromParent()
        goalSpinner = Entity()
        let holder = Entity()
        let gold = style == .game ? SimpleMaterial(color: UIColor(hex: 0xFFC83D), roughness: 0.25, isMetallic: true)
                                  : SimpleMaterial(color: UIColor(hex: 0xEA4335), roughness: 0.35, isMetallic: false)
        let pole = ModelEntity(mesh: .generateCylinder(height: 6, radius: 0.22),
                               materials: [SimpleMaterial(color: .white, isMetallic: false)])
        pole.position.y = 3
        goalSpinner.position.y = 7.2
        let star = ModelEntity(mesh: style == .game ? .generateBox(size: 2.2, cornerRadius: 0.4) : .generateSphere(radius: 1.4),
                               materials: [gold])
        star.orientation = simd_quatf(angle: .pi / 4, axis: simd_normalize([1, 0, 1]))
        goalSpinner.addChild(star)
        let base = ModelEntity(mesh: .generateCylinder(height: 0.06, radius: 4),
                               materials: [WorldScene.unlit( UIColor(hex: 0xFFC83D, alpha: 0.45))])
        base.position.y = 0.14
        for e in [pole, goalSpinner, base] { holder.addChild(e) }
        holder.addChild(Self.label(name, at: [0, 10, 0], size: 1.6))
        holder.position = p
        root.addChild(holder)
        goalHolder = holder
    }

    func setRoute(_ r: Route) {
        route = r
        routeEntity.removeFromParent()
        routeEntity = Self.strip(r.points.map { $0 + [0, 0.12, 0] }, width: 3.4, color: Palette.route.withAlphaComponent(0.85))
        root.addChild(routeEntity)
    }

    // MARK: Kondisi jalur

    private let conditionLayer = Entity()
    private var edgeEntities: [Int: Entity] = [:]
    private var selection = Entity()

    /// Garis tipis berwarna di atas tiap segmen: hijau/kuning/merah/abu-abu.
    func paint(edge i: Int, graph: WalkGraph, condition: Condition) {
        edgeEntities[i]?.removeFromParent()
        let a = graph.point(graph.edges[i][0]), b = graph.point(graph.edges[i][1])
        let e = Self.strip([SIMD3(a.x, 0.16, a.y), SIMD3(b.x, 0.16, b.y)], width: 1.1, color: condition.color)
        conditionLayer.addChild(e)
        edgeEntities[i] = e
    }

    func select(edge i: Int?, graph: WalkGraph) {
        selection.removeFromParent()
        selection = Entity()
        if let i {
            let a = graph.point(graph.edges[i][0]), b = graph.point(graph.edges[i][1])
            selection = Self.strip([SIMD3(a.x, 0.14, a.y), SIMD3(b.x, 0.14, b.y)], width: 3.2, color: .white)
        }
        root.addChild(selection)
    }

    /// Titik di tanah (y = 0) yang tertunjuk oleh ketukan layar.
    func groundPoint(at tap: CGPoint, in size: CGSize) -> SIMD2<Float>? {
        let ndc = SIMD2(Float(tap.x / size.width) * 2 - 1, 1 - Float(tap.y / size.height) * 2)
        let t = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        let aspect = Float(size.width / size.height)
        let local = simd_normalize(SIMD3(ndc.x * t * aspect, ndc.y * t, -1))
        let dir = camera.orientation(relativeTo: nil).act(local)
        let origin = camera.position(relativeTo: nil)
        guard dir.y < -0.01 else { return nil }
        let hit = origin + dir * (-origin.y / dir.y)
        return SIMD2(hit.x, hit.z)
    }

    // MARK: Frame update

    /// Dipanggil tiap frame. Kamera dan arah avatar dihaluskan supaya tidak patah-patah.
    func update(position here: SIMD3<Float>, direction: SIMD3<Float>, rolled d: Float, dt: Float,
                overview: Bool, camDistance: Float, pitchDegrees: Float, yawOffset: Float, snap: Bool = false) {
        time += dt
        var dir = direction
        if simd_length(dir) < 0.05 { dir = facing }
        let k: Float = snap ? 1 : 0.12
        facing = simd_normalize(simd_mix(facing, simd_normalize(dir), SIMD3(repeating: k)))
        avatar.position = here
        avatar.look(at: here + facing, from: here, relativeTo: nil)
        for w in wheels { w.orientation = simd_quatf(angle: -d / (0.9 * 1.35), axis: [1, 0, 0]) }

        let phase = (time * 0.6).truncatingRemainder(dividingBy: 1)
        pulse.scale = [1 + phase * 13, 1, 1 + phase * 13]
        pulse.children.first?.isEnabled = phase < 0.95

        for s in spots where style == .game {
            s.cube.orientation = simd_quatf(angle: time * 1.2, axis: [0, 1, 0]) *
                simd_quatf(angle: .pi / 4, axis: simd_normalize([1, 0, 1]))
            s.label.isEnabled = simd_distance(s.entity.position, here) < 28
        }
        for s in spots where style == .biasa { s.label.isEnabled = simd_distance(s.entity.position, here) < 28 }
        if style == .game { goalSpinner.orientation = simd_quatf(angle: time * 1.5, axis: [0, 1, 0]) }
        goalSpinner.position.y = 7.2 + sin(time * 2) * 0.4

        let wantEye: SIMD3<Float>, wantTarget: SIMD3<Float>
        if overview {
            // Bingkai seluruh rute, termasuk rute yang memutar jauh.
            let lo = route.points.reduce(route.points[0]) { simd_min($0, $1) }
            let hi = route.points.reduce(route.points[0]) { simd_max($0, $1) }
            let mid = (lo + hi) / 2
            let span = max(hi.x - lo.x, hi.z - lo.z)
            wantTarget = mid
            wantEye = mid + SIMD3(0, span * 1.25 + 60, span * 0.7 + 35)
        } else {
            let pitch = pitchDegrees * .pi / 180
            let look = simd_quatf(angle: yawOffset, axis: [0, 1, 0]).act(facing)
            wantTarget = here + look * 6 + [0, 1.5, 0]
            wantEye = here - look * camDistance * cos(pitch) + SIMD3(0, camDistance * sin(pitch), 0)
        }
        let c: Float = snap || eye == nil ? 1 : 0.08
        eye = simd_mix(eye ?? wantEye, wantEye, SIMD3(repeating: c))
        target = simd_mix(target, wantTarget, SIMD3(repeating: c))
        camera.look(at: target, from: eye!, relativeTo: nil)
        fadeOccluders(from: eye!, to: here)
    }

    /// Gedung yang menghalangi kamera dari avatar disembunyikan.
    private func fadeOccluders(from eye: SIMD3<Float>, to here: SIMD3<Float>) {
        let a = SIMD2(eye.x, eye.z), b = SIMD2(here.x, here.z), t = SIMD2(target.x, target.z)
        for item in buildingEntities {
            // Cek garis kamera→avatar dan kamera→titik pandang; gedung di salah satunya disembunyikan.
            let blocked = (0...10).contains { i in
                let k = SIMD2(repeating: Float(i) / 10)
                return Self.contains(item.footprint, simd_mix(a, b, k)) || Self.contains(item.footprint, simd_mix(a, t, k))
            }
            item.entity.isEnabled = !blocked
        }
    }

    // MARK: - Geometry helpers

    /// UnlitMaterial mengabaikan alpha warna kecuali blending-nya diset transparan.
    nonisolated static func unlit(_ color: UIColor) -> UnlitMaterial {
        var m = UnlitMaterial(color: color.withAlphaComponent(1))
        var a: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &a)
        if a < 1 { m.blending = .transparent(opacity: .init(floatLiteral: Float(a))) }
        return m
    }

    private static func extrude(_ pts: [[Float]], depth: Float) -> MeshResource? {
        guard pts.count >= 3 else { return nil }
        var path = Path()
        // Path di bidang XY, y = -z peta; setelah diputar -90° di sumbu X, y jadi tinggi.
        path.move(to: CGPoint(x: CGFloat(pts[0][0]), y: CGFloat(-pts[0][1])))
        for p in pts.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(p[0]), y: CGFloat(-p[1]))) }
        path.closeSubpath()
        var opts = MeshResource.ShapeExtrusionOptions()
        opts.extrusionMethod = .linear(depth: depth)
        if depth > 1 { opts.chamferRadius = 0.5 }
        return try? MeshResource(extruding: path, extrusionOptions: opts)
    }

    private static func placeExtruded(_ e: ModelEntity, base: Float) {
        e.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        e.position.y += base - e.visualBounds(relativeTo: nil).min.y
    }

    private static func building(_ b: WorldData.Building, color: UIColor) -> Entity? {
        guard let mesh = extrude(b.pts, depth: min(b.h, 45)) else { return nil }
        let e = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, roughness: 0.9, isMetallic: false)])
        placeExtruded(e, base: 0)
        let holder = Entity()
        holder.addChild(e)
        if !b.name.isEmpty {
            let c = b.pts.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1[0], $1[1]) } / Float(b.pts.count)
            holder.addChild(label(b.name, at: [c.x, min(b.h, 45) + 3, c.y], size: 2.2))
        }
        return holder
    }

    private static func flatArea(_ a: WorldData.Way) -> Entity? {
        guard let mesh = extrude(a.pts, depth: 0.05) else { return nil }
        let color = a.kind == "water" ? UIColor(hex: 0x60C4F0) : UIColor(hex: 0xE3E0D2)
        let e = ModelEntity(mesh: mesh, materials: [WorldScene.unlit( color)])
        placeExtruded(e, base: 0.02)
        return e
    }

    private static func label(_ text: String, at p: SIMD3<Float>, size: CGFloat, color: UIColor = .white) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.05,
                                             font: .systemFont(ofSize: size, weight: .heavy),
                                             alignment: .center)
        let textEntity = ModelEntity(mesh: mesh, materials: [WorldScene.unlit( color)])
        let bounds = textEntity.visualBounds(relativeTo: nil)
        textEntity.position = [-bounds.center.x, -bounds.center.y, 0.06]
        let pad = Float(size) * 0.45
        let plate = ModelEntity(mesh: .generatePlane(width: bounds.extents.x + pad * 2,
                                                     height: bounds.extents.y + pad, cornerRadius: pad * 0.8),
                                materials: [WorldScene.unlit( UIColor(hex: 0x1C2440, alpha: 0.78))])
        let holder = Entity()
        holder.addChild(plate); holder.addChild(textEntity)
        holder.position = p
        holder.components.set(BillboardComponent())
        return holder
    }

    private static func warningSign(at p: SIMD3<Float>) -> Entity {
        let holder = Entity()
        let pole = ModelEntity(mesh: .generateCylinder(height: 3, radius: 0.12),
                               materials: [SimpleMaterial(color: .white, isMetallic: false)])
        pole.position.y = 1.5
        holder.addChild(pole)
        holder.addChild(label("⚠︎ Tangga", at: [0, 4, 0], size: 1.2, color: UIColor(hex: 0xFFD6D6)))
        holder.position = p
        return holder
    }

    private static func strip(_ pts: [SIMD3<Float>], width: Float, color: UIColor) -> Entity {
        let parent = Entity()
        let material = WorldScene.unlit( color)
        for (a, b) in zip(pts, pts.dropFirst()) {
            let len = simd_distance(a, b)
            guard len > 0.01 else { continue }
            let seg = ModelEntity(mesh: .generateBox(width: width, height: 0.04, depth: len + width,
                                                     cornerRadius: width / 2 - 0.01),
                                  materials: [material])
            seg.look(at: b, from: (a + b) / 2, relativeTo: nil)
            parent.addChild(seg)
        }
        return parent
    }
}

// MARK: - View

struct World3DView: View {
    /// Kecepatan dorong kursi roda rata-rata, sekitar 1,1 m/detik.
    private static let wheelchairSpeed: Float = 1.1

    @State private var scene: WorldScene
    private let style: WorldStyle

    init(style: WorldStyle = .game, destination: Place = .breeze, gpsOnly: Bool = false) {
        self.style = style
        self.gpsOnly = gpsOnly
        _scene = State(initialValue: WorldScene(data: .bsd, style: style))
        _destination = State(initialValue: destination)
        _mode = State(initialValue: gpsOnly ? .gps : .simulasi)
    }
    private let gpsOnly: Bool
    @State private var travelled: Float = 0
    @State private var walking = false
    @State private var fast = true
    @State private var overview = false
    @State private var voiceOn = true
    @State private var pitch: Double = 48
    @State private var distance: Double = 34
    @State private var yaw: Float = 0
    @State private var dragStartYaw: Float?
    @State private var pinchStartDistance: Double?
    @State private var lastSpoken = -1
    @State private var lastTick = Date()

    enum Mode: String, CaseIterable { case simulasi = "Simulasi", gps = "GPS asli", survei = "Survei" }
    @State private var mode: Mode = .simulasi
    @State private var location = LocationService(origin: WorldData.bsd.origin)
    @State private var gpsPosition: SIMD2<Float>?
    @State private var gpsRolled: Float = 0
    @State private var lastReroute = Date.distantPast

    private static let graph = WorldData.bsd.graph
    private static let simStart = SIMD2(WorldData.bsd.route[0][0], WorldData.bsd.route[0][1])
    @State private var conditions = ConditionStore(graph: WorldData.bsd.graph)
    @State private var unknownMeters: Float = 0
    @State private var cautionMeters: Float = 0
    @State private var selectedEdge: Int?
    @State private var viewSize = CGSize(width: 1, height: 1)
    @State private var showAR = false
    @State private var destination = Place.breeze
    @State private var showPlaces = false

    private let speech = AVSpeechSynthesizer()
    private let timer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    private var route: Route { scene.route }
    private var remaining: Float { max(0, route.length - travelled) }
    private var arrived: Bool { remaining < 0.5 }
    private var nextIndex: Int? { route.maneuvers.firstIndex { $0.at > travelled + 0.5 } }

    var body: some View {
        ZStack {
            LinearGradient(colors: [style.sky.top, style.sky.bottom],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                for i in Self.graph.edges.indices {
                    scene.paint(edge: i, graph: Self.graph, condition: conditions.report(i).condition)
                }
                replan(from: Self.simStart)
                let start = scene.route.position(at: 0)
                scene.update(position: start, direction: scene.route.position(at: 4) - start, rolled: 0, dt: 0,
                             overview: false, camDistance: Float(distance), pitchDegrees: Float(pitch),
                             yawOffset: 0, snap: true)
                await scene.loadGround(WorldData.bsd.snapshot)
            }
            .ignoresSafeArea()
            .gesture(cameraGestures)
            .simultaneousGesture(SpatialTapGesture().onEnded { v in surveyTap(at: v.location) })
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        }
        .sheet(isPresented: $showPlaces) { placePicker }
        .fullScreenCover(isPresented: $showAR) {
            // Peta + AR: AR dibuka di posisi yang sama dengan avatar di peta.
            ARNavView(start: avatarPoint, destination: destination, anywhere: mode == .simulasi || gpsPosition == nil)
        }
        .sheet(isPresented: Binding(get: { selectedEdge != nil }, set: { if !$0 { selectEdge(nil) } })) {
            if let edge = selectedEdge { surveySheet(edge) }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                instructionCard
                if !gpsOnly {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                Button {
                    showPlaces = true
                } label: {
                    Label("Tujuan: \(destination.name)", systemImage: "mappin.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                if let notice = gpsNotice {
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                }
            }
        }
        .onChange(of: mode) { _, m in
            walking = false
            selectEdge(nil)
            if m == .simulasi {
                location.stop(); gpsPosition = nil
                replan(from: Self.simStart)
            } else {
                location.start()
            }
            if m == .survei { overview = false; pitch = 70; distance = 45 }
            lastSpoken = -1
        }
        .overlay(alignment: .bottom) { bottomBar }
        .onAppear { if mode == .gps { location.start() } }
        .onReceive(timer) { now in tick(now) }
    }

    /// Geser kiri/kanan memutar kamera, geser atas/bawah mengubah kemiringan, cubit untuk zoom.
    private var cameraGestures: some Gesture {
        SimultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if dragStartYaw == nil { dragStartYaw = yaw }
                    yaw = dragStartYaw! - Float(v.translation.width) * 0.008
                    pitch = min(80, max(20, pitch - Double(v.velocity.height) * 0.0004))
                }
                .onEnded { _ in dragStartYaw = nil },
            MagnifyGesture()
                .onChanged { v in
                    if pinchStartDistance == nil { pinchStartDistance = distance }
                    distance = min(120, max(10, pinchStartDistance! / v.magnification))
                }
                .onEnded { _ in pinchStartDistance = nil }
        )
    }

    private func tick(_ now: Date) {
        let dt = Float(min(now.timeIntervalSince(lastTick), 0.1))
        lastTick = now
        var here = route.position(at: travelled)
        var direction = route.position(at: travelled + 4) - here
        var rolled = travelled

        if mode != .simulasi {
            if let p = location.local, insideArea(p) {
                // GPS sedikit dihaluskan supaya avatar tidak loncat-loncat.
                let previous = gpsPosition ?? p
                let smoothed = simd_mix(previous, p, SIMD2(repeating: 0.15))
                gpsRolled += simd_distance(previous, smoothed)
                gpsPosition = smoothed
                if mode == .gps { followGPS(smoothed, now: now) }
                here = SIMD3(smoothed.x, 0, smoothed.y)
                if let h = location.heading { direction = LocationService.direction(degrees: h) }
                else if let c = location.course { direction = LocationService.direction(degrees: c) }
                rolled = gpsRolled
            }
        } else if walking {
            travelled = min(route.length, travelled + dt * Self.wheelchairSpeed * (fast ? 5 : 1))
            if arrived { walking = false; say("Kamu sudah sampai di \(destination.name).") }
            announceIfNeeded()
        }
        scene.update(position: here, direction: direction, rolled: rolled, dt: dt, overview: overview,
                     camDistance: Float(distance), pitchDegrees: Float(pitch), yawOffset: yaw)
    }

    /// Posisi GPS di-"tempel" ke rute; kalau keluar rute > 12 m, rute dihitung ulang dari posisi sekarang.
    private func followGPS(_ p: SIMD2<Float>, now: Date) {
        let wasArrived = arrived
        let (along, off) = route.project(p)
        if off > 12, now.timeIntervalSince(lastReroute) > 4 {
            lastReroute = now
            replan(from: p)
            say("Rute diperbarui.")
            return
        }
        travelled = along
        if arrived && !wasArrived { say("Kamu sudah sampai di \(destination.name).") }
        announceIfNeeded()
    }

    /// Hitung rute baru dengan kondisi jalur terbaru. Jalur merah tidak pernah dipakai.
    private func replan(from p: SIMD2<Float>) {
        let plan = Self.graph.plan(from: p, to: destination.point,
                                   cost: { conditions.cost($0) },
                                   condition: { conditions.report($0).condition })
        guard let plan else { return }
        scene.setRoute(plan.route)
        scene.setGoal(at: plan.route.points.last!, name: destination.name)
        unknownMeters = plan.unknownMeters
        cautionMeters = plan.cautionMeters
        travelled = 0
        lastSpoken = -1
    }

    private var avatarPoint: SIMD2<Float> {
        if let g = gpsPosition, mode != .simulasi { return g }
        let p = route.position(at: travelled)
        return SIMD2(p.x, p.z)
    }

    // MARK: Survei

    private func surveyTap(at point: CGPoint) {
        guard mode == .survei, let ground = scene.groundPoint(at: point, in: viewSize) else { return }
        var best: (edge: Int, d: Float)?
        for (i, e) in Self.graph.edges.enumerated() {
            let a = Self.graph.point(e[0]), b = Self.graph.point(e[1]), ab = b - a
            let t = simd_clamp(simd_dot(ground - a, ab) / max(simd_length_squared(ab), 0.0001), 0, 1)
            let d = simd_distance(ground, a + ab * t)
            if d < (best?.d ?? 8) { best = (i, d) }
        }
        selectEdge(best?.edge)
    }

    private func selectEdge(_ edge: Int?) {
        selectedEdge = edge
        scene.select(edge: edge, graph: Self.graph)
    }

    private func applyReport(_ edge: Int, _ condition: Condition?, reasons: [String]) {
        if let condition { conditions.set(edge, condition, reasons: reasons) } else { conditions.reset(edge) }
        scene.paint(edge: edge, graph: Self.graph, condition: conditions.report(edge).condition)
        replan(from: avatarPoint)
    }

    private func surveySheet(_ edge: Int) -> some View {
        let report = conditions.report(edge)
        let kind = Self.graph.kinds[edge]
        let kindName = ["steps": "Tangga", "service": "Jalan servis (mobil)", "residential": "Jalan perumahan",
                        "footway": "Jalur pejalan kaki", "path": "Jalan setapak"][kind] ?? kind
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kondisi jalur").font(.title3.bold())
                Text("\(kindName) · \(Int(Self.graph.length(edge).rounded())) m · " +
                     (report.source == "survei" ? "sudah disurvei" : "perkiraan dari peta, belum disurvei"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach([Condition.aman, .hatiHati, .tidakBisa], id: \.self) { c in
                    Button {
                        applyReport(edge, c, reasons: report.reasons)
                    } label: {
                        Text(c.title).font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(report.condition == c ? .white : Color(c.color))
                            .background(report.condition == c ? Color(c.color) : Color(c.color).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            Text("Alasan").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Condition.reasons, id: \.self) { r in
                        let on = report.reasons.contains(r)
                        Button(r) {
                            let reasons = on ? report.reasons.filter { $0 != r } : report.reasons + [r]
                            applyReport(edge, report.source == "survei" ? report.condition : .hatiHati, reasons: reasons)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(on ? Color.blue : Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(on ? .white : .primary)
                    }
                }
            }
            Button("Tandai belum dicek") { applyReport(edge, nil, reasons: []) }
                .font(.subheadline)
        }
        .padding(20)
        .presentationDetents([.height(320)])
        .presentationBackgroundInteraction(.enabled)
    }

    // MARK: Tujuan

    private var placePicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Place.all.filter(\.inArea)) { place in
                        Button {
                            destination = place
                            showPlaces = false
                            walking = false
                            replan(from: mode == .simulasi ? Self.simStart : avatarPoint)
                        } label: { placeRow(place, selected: place == destination) }
                    }
                } header: {
                    Text("Di \(AreaConfig.current.coverage) · bisa dirute")
                }
                Section {
                    ForEach(Place.all.filter { !$0.inArea }) { place in
                        placeRow(place, selected: false).opacity(0.6)
                    }
                } header: {
                    Text("Di \(AreaConfig.current.name) · belum tercakup peta")
                } footer: {
                    Text("Status aksesibel dari OpenStreetMap diisi relawan dan belum diverifikasi Wheelie.")
                }
            }
            .navigationTitle("Pilih tujuan")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func placeRow(_ place: Place, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: place.wheelchair == "unknown" ? "questionmark.circle" : "figure.roll")
                .foregroundStyle(place.wheelchair == "unknown" ? Color.secondary : Color.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text("\(place.kind) · \(place.statusText) · \(Int(simd_length(place.point - avatarPoint))) m")
                    .font(.caption).foregroundStyle(.secondary)
                Text(place.source).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.blue) }
        }
    }

    private func insideArea(_ p: SIMD2<Float>) -> Bool {
        let s = WorldData.bsd.snapshot
        return p.x > s.min[0] && p.x < s.max[0] && p.y > s.min[1] && p.y < s.max[1]
    }

    private var gpsNotice: String? {
        guard mode == .gps else { return nil }
        if location.denied { return "Izin lokasi ditolak. Aktifkan di Pengaturan." }
        guard let p = location.local else { return "Mencari sinyal GPS…" }
        if !insideArea(p) {
            let meters = Int(simd_length(p))
            return meters > 5000 ? "Kamu \(meters / 1000) km dari area demo (\(AreaConfig.current.coverage))."
                                 : "Kamu di luar area demo (\(AreaConfig.current.coverage))."
        }
        if let a = location.accuracy, a > 25 { return "Sinyal GPS lemah (±\(Int(a)) m)." }
        return nil
    }

    private func announceIfNeeded() {
        guard let i = nextIndex, i != lastSpoken, route.maneuvers[i].at - travelled < 15 else { return }
        lastSpoken = i
        say("Dalam \(Int(route.maneuvers[i].at - travelled)) meter, \(turnText(route.maneuvers[i]).lowercased()).")
    }

    private func say(_ text: String) {
        guard voiceOn else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "id-ID")
        speech.speak(u)
    }

    private func turnText(_ m: Route.Maneuver) -> String {
        (m.sharp ? "Putar balik ke " : "Belok ") + (m.left ? "kiri" : "kanan")
    }

    // MARK: HUD

    private var instructionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(arrived ? Color.green : Color.blue, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.title3.bold())
                Text(subline).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        if arrived { return "flag.checkered" }
        guard let i = nextIndex else { return "arrow.up" }
        let m = route.maneuvers[i]
        if m.sharp { return m.left ? "arrow.uturn.left" : "arrow.uturn.right" }
        return m.left ? "arrow.turn.up.left" : "arrow.turn.up.right"
    }

    private var headline: String {
        if arrived { return "Sampai di \(destination.name)" }
        guard let i = nextIndex else { return "Lurus \(Int(remaining)) m" }
        return "\(Int(route.maneuvers[i].at - travelled)) m · \(turnText(route.maneuvers[i]))"
    }

    private var subline: String {
        if arrived { return "Rute bebas tangga" }
        let minutes = max(1, Int((remaining / Self.wheelchairSpeed / 60).rounded(.up)))
        var warnings: [String] = []
        if cautionMeters > 0 { warnings.append("\(Int(cautionMeters)) m hati-hati") }
        if unknownMeters > 0 { warnings.append("\(Int(unknownMeters)) m belum dicek") }
        return "Sisa \(Int(remaining)) m · ±\(minutes) mnt · " + (warnings.isEmpty ? "semua aman" : warnings.joined(separator: " · "))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if mode == .survei {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            ForEach(Condition.allCases, id: \.self) { c in
                                HStack(spacing: 4) {
                                    Circle().fill(Color(c.color)).frame(width: 10, height: 10)
                                    Text(c.title).font(.caption2).lineLimit(1).fixedSize()
                                }
                            }
                        }
                        Text("Ketuk jalur untuk menandai · \(conditions.surveyedCount) segmen disurvei")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ShareLink(item: conditions.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("Bagikan data survei")
                }
            } else {
                HStack(spacing: 10) {
                    if mode == .gps {
                        Label("Mengikuti lokasimu", systemImage: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(.white)
                            .background(Color.green, in: Capsule())
                    } else {
                        Button {
                            if arrived { travelled = 0; lastSpoken = -1 }
                            walking.toggle()
                            if walking && travelled == 0 { say("Mulai. Ikuti garis biru menuju \(destination.name).") }
                        } label: {
                            Label(walking ? "Jeda" : (arrived ? "Ulangi" : "Mulai"),
                                  systemImage: walking ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    // Peta + AR: intip AR dari posisi yang sama, lalu kembali ke peta.
                    Button {
                        walking = false; showAR = true
                    } label: {
                        Label("Intip AR", systemImage: "arkit").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.large)
                }
                HStack(spacing: 10) {
                    if mode == .simulasi {
                        iconToggle(fast ? "hare.fill" : "tortoise.fill", on: fast, label: fast ? "Cepat 5×" : "Kecepatan asli") { fast.toggle() }
                    }
                    iconToggle(voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill", on: voiceOn, label: "Suara") {
                        voiceOn.toggle(); if !voiceOn { speech.stopSpeaking(at: .immediate) }
                    }
                    iconToggle("map", on: overview, label: "Ringkasan rute") { overview.toggle() }
                    iconToggle("location.north.line.fill", on: yaw == 0, label: "Kamera di belakang avatar") {
                        yaw = 0; pitch = 48; distance = 34
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func iconToggle(_ symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.blue.opacity(0.85) : Color.primary.opacity(0.08), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

#Preview { World3DView() }
