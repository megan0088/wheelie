// Gaya visual "Dari": token warna + komponen dasar yang dipakai semua layar prototipe.

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    /// Teks utama, kartu instruksi navigasi.
    static let dariPrimary = Color(hex: 0x17324D)
    /// Tombol, garis rute, tautan.
    static let dariAction = Color(hex: 0x146EF5)
    /// Status aksesibel / terverifikasi.
    static let dariAccess = Color(hex: 0x007F86)
    static let dariCaution = Color(hex: 0xF2A900)
    static let dariUrgent = Color(hex: 0xE63946)
    static let dariBackground = Color(hex: 0xF7F8FA)
    static let dariCard = Color.white
    static let dariMuted = Color(hex: 0x6B7785)
    static let dariLine = Color(hex: 0xE4E8EE)
}

extension Condition {
    var tint: Color {
        switch self {
        case .aman: .dariAccess
        case .hatiHati: .dariCaution
        case .tidakBisa: .dariUrgent
        case .belumDicek: .dariMuted
        }
    }
}

/// "2026-10-22" → "22 Okt 2026". String lain dikembalikan apa adanya.
func tanggalPendek(_ iso: String?) -> String? {
    guard let iso else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: String(iso.prefix(10))) else { return iso }
    return tanggalPendek(d)
}

func tanggalPendek(_ d: Date) -> String {
    d.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "id_ID")))
}

struct DariButton: View {
    enum Style { case filled, outline, soft }
    let title: String
    var symbol: String?
    var style: Style = .filled
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(style == .filled ? .white : (style == .soft ? Color.dariPrimary : Color.dariAction))
            .background {
                switch style {
                case .filled: Capsule().fill(enabled ? Color.dariAction : Color.gray.opacity(0.5))
                case .outline: Capsule().stroke(Color.dariAction, lineWidth: 1.5)
                case .soft: Capsule().fill(Color.dariLine.opacity(0.6))
                }
            }
        }
        .disabled(!enabled)
    }
}

struct DariChip: View {
    let text: String
    var symbol: String?
    var tint: Color = .dariMuted
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Bulatan ikon dengan latar tipis, dipakai di baris status dan petak ringkasan rute.
struct IconDot: View {
    let symbol: String
    var tint: Color = .dariAccess
    var size: CGFloat = 32
    var filled = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(filled ? .white : tint)
            .frame(width: size, height: size)
            .background(filled ? tint : tint.opacity(0.12), in: Circle())
    }
}

/// Tombol bulat di atas peta / foto (kembali, simpan).
struct CircleButton: View {
    let symbol: String
    var tint: Color = .dariPrimary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.headline)
                .frame(width: 44, height: 44)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .foregroundStyle(tint)
    }
}

extension View {
    func dariCard(padding: CGFloat = 14, radius: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(Color.dariCard, in: RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

/// Kotak gambar pengganti saat tempat belum punya foto: ikon sesuai jenis, bukan foto karangan.
struct KindTile: View {
    let kind: String
    var size: CGFloat = 52
    var symbol: String {
        switch kind {
        case "Taman": "tree.fill"
        case "Mall", "Mall terbuka", "Toko", "Supermarket", "Toko buku": "bag.fill"
        case "Stasiun": "tram.fill"
        case "Halte": "bus.fill"
        case "Kafe": "cup.and.saucer.fill"
        case "Restoran": "fork.knife"
        case "Perpustakaan": "books.vertical.fill"
        case "Rumah sakit", "Apotek": "cross.case.fill"
        case "Tempat ibadah": "building.columns.fill"
        case "Hotel": "bed.double.fill"
        case "Rekreasi", "Museum", "Gedung pameran": "theatermasks.fill"
        default: "mappin.circle.fill"
        }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [Color.dariAccess.opacity(0.18), Color.dariAction.opacity(0.14)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.38)).foregroundStyle(Color.dariAccess))
    }
}

#Preview {
    VStack(spacing: 12) {
        DariButton(title: "Rencanakan rute aksesibel") {}
        DariButton(title: "Cari alternatif", style: .outline) {}
        HStack { DariChip(text: "Terverifikasi", symbol: "checkmark.circle.fill", tint: .dariAccess); KindTile(kind: "Taman") }
    }
    .padding()
    .background(Color.dariBackground)
}
