// SPIKE — throwaway. GPS + kompas, dikonversi ke koordinat lokal dunia 3D (meter, x = timur, z = selatan).

import CoreLocation
import Observation
import simd

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var local: SIMD2<Float>?
    /// Arah hadap HP dalam derajat dari utara (searah jarum jam), kalau kompas tersedia.
    private(set) var heading: Double?
    /// Arah gerak dari GPS, dipakai kalau kompas tidak ada (misalnya di simulator).
    private(set) var course: Double?
    private(set) var accuracy: Double?
    private(set) var denied = false
    /// "Lokasi Tepat" dimatikan: akurasi bisa ratusan meter sampai kilometer, tidak cukup untuk memandu kursi roda.
    private(set) var reduced = false

    private let manager = CLLocationManager()
    private var lastLog = Date.distantPast
    private let origin: (lat: Double, lon: Double)

    init(origin: [Double]) {
        self.origin = (origin[0], origin[1])
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .otherNavigation
        manager.headingFilter = 2
        // Kursi roda bergerak pelan dan sering berhenti; jangan biarkan iOS menjeda GPS di tengah navigasi.
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        denied = [.denied, .restricted].contains(m.authorizationStatus)
        reduced = m.accuracyAuthorization == .reducedAccuracy
        wlog("[GPS] izin lokasi: \(m.authorizationStatus.rawValue) (4 = saat dipakai, 2 = ditolak)")
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        let x = (l.coordinate.longitude - origin.lon) * 111_320 * cos(origin.lat * .pi / 180)
        let z = -(l.coordinate.latitude - origin.lat) * 110_540
        local = SIMD2(Float(x), Float(z))
        accuracy = l.horizontalAccuracy
        if l.course >= 0, l.speed > 0.3 { course = l.course }
        // Log uji perangkat: posisi lokal (meter dari pusat area), bukan koordinat mentah.
        guard Date.now.timeIntervalSince(lastLog) > 3 else { return }
        lastLog = .now
        let box = WorldData.bsd.snapshot
        let inside = Float(x) > box.min[0] && Float(x) < box.max[0] && Float(z) > box.min[1] && Float(z) < box.max[1]
        wlog(String(format: "[GPS] x=%.0f m, z=%.0f m, akurasi ±%.0f m, kecepatan %.1f m/s, ", x, z, l.horizontalAccuracy, max(0, l.speed))
              + (inside ? "DI DALAM area" : "di luar area"))
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard h.headingAccuracy >= 0 else { return }
        heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    /// Derajat kompas → vektor arah di dunia 3D (utara = -z, timur = +x).
    static func direction(degrees: Double) -> SIMD3<Float> {
        let r = Float(degrees * .pi / 180)
        return [sin(r), 0, -cos(r)]
    }
}

/// Log uji lapangan: dicetak ke konsol dan ditulis ke Documents/wheelie-log.txt,
/// supaya tetap tercatat walau koneksi ke Mac putus. Diambil lewat `devicectl device copy from`.
func wlog(_ message: String) {
    print(message)
    let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message)\n"
    let url = URL.documentsDirectory.appending(path: "wheelie-log.txt")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
