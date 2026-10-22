// Peta statis (MKMapSnapshotter) untuk kartu, header tempat, dan pratinjau rute alternatif.
// Jauh lebih ringan daripada Map interaktif di dalam ScrollView, dan di-cache per ukuran.

import SwiftUI
import MapKit

private let snapshotCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 60
    return c
}()

struct MapSnapshot: View {
    let center: CLLocationCoordinate2D
    var distance: Double = 600
    var pitch: Double = 45
    var heading: Double = 25
    /// Garis rute yang digambar di atas peta; kalau ada, peta dipaskan ke garis ini (tanpa kemiringan).
    var path: [CLLocationCoordinate2D] = []
    var showPin = true

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.dariLine.opacity(0.45)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                } else {
                    Image(systemName: "map").font(.title2).foregroundStyle(Color.dariMuted.opacity(0.6))
                }
            }
            .task(id: key(geo.size)) { await load(geo.size) }
        }
        .clipped()
    }

    private func key(_ size: CGSize) -> String {
        let p = path.first.map { "\($0.latitude),\($0.longitude),\(path.count)" } ?? ""
        return "\(center.latitude),\(center.longitude),\(distance),\(pitch),\(heading),\(Int(size.width))x\(Int(size.height)),\(p)"
    }

    private func load(_ size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let k = key(size) as NSString
        if let cached = snapshotCache.object(forKey: k) { image = cached; return }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.pointOfInterestFilter = .excludingAll
        if path.count > 1 {
            var rect = MKMapRect.null
            for c in path { rect = rect.union(MKMapRect(origin: MKMapPoint(c), size: .init(width: 1, height: 1))) }
            let pad = max(rect.width, rect.height) * 0.25 + 80
            options.mapRect = rect.insetBy(dx: -pad, dy: -pad)
        } else {
            options.camera = MKMapCamera(lookingAtCenter: center, fromDistance: distance, pitch: pitch, heading: heading)
        }
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return }

        let rendered = UIGraphicsImageRenderer(size: size).image { ctx in
            shot.image.draw(at: .zero)
            let g = ctx.cgContext
            if path.count > 1 {
                let pts = path.map { shot.point(for: $0) }
                g.setLineCap(.round); g.setLineJoin(.round)
                g.setStrokeColor(UIColor.white.cgColor); g.setLineWidth(8)
                g.addLines(between: pts); g.strokePath()
                g.setStrokeColor(UIColor(Color.dariAction).cgColor); g.setLineWidth(5)
                g.addLines(between: pts); g.strokePath()
                dot(g, pts[0], UIColor(Color.dariAction), 7)
                pin(g, pts[pts.count - 1])
            } else if showPin {
                pin(g, shot.point(for: center))
            }
        }
        snapshotCache.setObject(rendered, forKey: k)
        withAnimation(.easeOut(duration: 0.2)) { image = rendered }
    }

    private func dot(_ g: CGContext, _ p: CGPoint, _ color: UIColor, _ r: CGFloat) {
        g.setFillColor(UIColor.white.cgColor)
        g.fillEllipse(in: CGRect(x: p.x - r - 2.5, y: p.y - r - 2.5, width: 2 * r + 5, height: 2 * r + 5))
        g.setFillColor(color.cgColor)
        g.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    /// Pin merah bergaya peta: lingkaran di atas, ujung runcing tepat di titik lokasi.
    private func pin(_ g: CGContext, _ p: CGPoint) {
        let r: CGFloat = 11, top = CGPoint(x: p.x, y: p.y - 26)
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        g.setFillColor(UIColor(Color.dariUrgent).cgColor)
        g.move(to: p)
        g.addLine(to: CGPoint(x: top.x - r * 0.75, y: top.y + r * 0.6))
        g.addArc(center: top, radius: r, startAngle: .pi * 0.8, endAngle: .pi * 0.2, clockwise: false)
        g.closePath(); g.fillPath()
        g.setShadow(offset: .zero, blur: 0, color: nil)
        g.setFillColor(UIColor.white.cgColor)
        g.fillEllipse(in: CGRect(x: top.x - 4.5, y: top.y - 4.5, width: 9, height: 9))
    }
}

#Preview {
    MapSnapshot(center: .init(latitude: -6.2445, longitude: 106.8006)).frame(height: 160)
}
