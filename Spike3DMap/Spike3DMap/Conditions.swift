// SPIKE — throwaway. Status kondisi tiap segmen jalur, hasil survei di lapangan.

import Foundation
import Observation
import UIKit

enum Condition: String, Codable, CaseIterable {
    case aman, hatiHati, tidakBisa, belumDicek

    var title: String {
        switch self {
        case .aman: "Aman"
        case .hatiHati: "Hati-hati"
        case .tidakBisa: "Tidak bisa"
        case .belumDicek: "Belum dicek"
        }
    }

    var color: UIColor {
        switch self {
        case .aman: UIColor(red: 0, green: 0.498, blue: 0.525, alpha: 1)
        case .hatiHati: UIColor(red: 0.949, green: 0.663, blue: 0, alpha: 1)
        case .tidakBisa: UIColor(red: 0.902, green: 0.224, blue: 0.275, alpha: 1)
        case .belumDicek: UIColor(white: 0.62, alpha: 1)
        }
    }

    /// Pengali jarak saat routing. nil = tidak boleh dilewati sama sekali.
    var cost: Float? {
        switch self {
        case .aman: 1
        case .belumDicek: 1.6
        case .hatiHati: 3
        case .tidakBisa: nil
        }
    }

    static let reasons = ["Tangga", "Trotoar tinggi", "Tanpa ramp", "Tanjakan curam", "Paving rusak",
                          "Jalur sempit", "Terhalang", "Jalan mobil", "Ada ramp", "Rata & lebar"]
}

struct SegmentReport: Codable, Equatable {
    var condition: Condition
    var reasons: [String]
    var updated: Date?
    /// "survei" kalau dicek langsung, "osm" kalau cuma perkiraan dari data peta.
    var source: String
}

@Observable
final class ConditionStore {
    /// Hasil survei per kunci segmen: "w<id way OSM>" kalau graf punya osmWay, selain itu "e<nomor segmen>".
    private(set) var surveyed: [String: SegmentReport] = [:]
    private let graph: WalkGraph

    /// Kunci per way OSM tetap berlaku saat graf dibuat ulang. Kunci per nomor segmen tidak: kalau graf berubah
    /// (area diperluas), nomornya bergeser, jadi file itu dipisah per jumlah segmen supaya tidak menempel ke segmen yang salah.
    let fileURL: URL

    init(graph: WalkGraph) {
        self.graph = graph
        fileURL = URL.documentsDirectory.appending(path: graph.osmWay != nil
            ? "kondisi-jalur-osm.json" : "kondisi-jalur-\(graph.kinds.count).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode([String: SegmentReport].self, from: data) {
            surveyed = saved
        }
    }

    private func key(_ edge: Int) -> String {
        if let ways = graph.osmWay { return "w\(ways[edge])" }
        return "e\(edge)"
    }

    func report(_ edge: Int) -> SegmentReport {
        if let r = surveyed[key(edge)] { return r }
        // Perkiraan dari OSM + BIG (export_aplikasi.py), masih belum disurvei.
        if let status = graph.status, let c = Condition(rawValue: status[edge]) {
            let why = graph.reasons?[edge].split(separator: "; ").map(String.init) ?? []
            return .init(condition: c, reasons: why, updated: nil, source: "osm")
        }
        // Tanpa survei: hanya tangga yang pasti; jalan mobil diberi peringatan; sisanya jujur "belum dicek".
        switch graph.kinds[edge] {
        case "steps": return .init(condition: .tidakBisa, reasons: ["Tangga"], updated: nil, source: "osm")
        case "barrier_closed": return .init(condition: .tidakBisa, reasons: ["Penghalang tertutup"], updated: nil, source: "osm")
        case "barrier": return .init(condition: .hatiHati, reasons: ["Penghalang (cek celah)"], updated: nil, source: "osm")
        case "service", "residential", "tertiary", "unclassified", "secondary", "primary":
            return .init(condition: .hatiHati, reasons: ["Jalan mobil"], updated: nil, source: "osm")
        default: return .init(condition: .belumDicek, reasons: [], updated: nil, source: "osm")
        }
    }

    /// Pengali jarak untuk rute terbaik. Hasil survei memakai pengali kondisi; perkiraan memakai faktor dari data
    /// (arteri lebih berat dari jalan lokal), dengan sedikit tambahan untuk jalur yang belum dicek.
    func cost(_ edge: Int) -> Float? {
        let r = report(edge)
        guard r.source != "survei", let factors = graph.factor else { return r.condition.cost }
        guard let f = factors[edge], r.condition.cost != nil else { return nil }
        return r.condition == .belumDicek ? max(f, 1) * 1.3 : f
    }

    func set(_ edge: Int, _ condition: Condition, reasons: [String]) {
        surveyed[key(edge)] = .init(condition: condition, reasons: reasons, updated: .now, source: "survei")
        save()
    }

    func reset(_ edge: Int) {
        surveyed[key(edge)] = nil
        save()
    }

    var surveyedCount: Int { surveyed.count }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(surveyed).write(to: fileURL, options: .atomic)
    }
}
