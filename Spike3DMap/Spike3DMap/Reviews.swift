// SPIKE — ulasan aksesibilitas dari layar Kontribusi. Disimpan di HP ini saja (belum ada server),
// jadi rating yang tampil di aplikasi selalu berasal dari ulasan sungguhan, bukan angka contoh.

import Foundation
import Observation
import UIKit

struct Review: Codable, Identifiable, Equatable {
    var id = UUID()
    let place: String
    let rating: Int
    let text: String
    let photo: String?
    let date: Date
}

@Observable
final class ReviewStore {
    private(set) var reviews: [Review] = []
    private let fileURL = URL.documentsDirectory.appending(path: "ulasan.json")

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode([Review].self, from: data) {
            reviews = saved
        }
    }

    func reviews(for place: Place) -> [Review] { reviews.filter { $0.place == place.name } }

    /// Rata-rata bintang; nil kalau belum ada ulasan (UI menampilkan "Belum ada penilaian").
    func rating(for place: Place) -> (value: Double, count: Int)? {
        let r = reviews(for: place)
        guard !r.isEmpty else { return nil }
        return (Double(r.map(\.rating).reduce(0, +)) / Double(r.count), r.count)
    }

    func add(place: Place, rating: Int, text: String, image: UIImage?) {
        var photo: String?
        if let data = image?.jpegData(compressionQuality: 0.7) {
            let name = "foto-ulasan-\(UUID().uuidString).jpg"
            if (try? data.write(to: URL.documentsDirectory.appending(path: name))) != nil { photo = name }
        }
        reviews.append(Review(place: place.name, rating: rating, text: text, photo: photo, date: .now))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(reviews).write(to: fileURL, options: .atomic)
    }

    func image(_ review: Review) -> UIImage? {
        review.photo.flatMap { UIImage(contentsOfFile: URL.documentsDirectory.appending(path: $0).path) }
    }
}
