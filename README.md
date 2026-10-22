# Wheelie

Aplikasi iOS (SwiftUI) untuk navigasi kursi roda di Blok M, Jakarta Selatan: rute dihitung di HP dari jaringan jalan
yang tiap ruasnya diberi status aksesibilitas, lalu diperbaiki lewat survei lapangan.

## Dua versi aplikasi

| Target Xcode | Nama di HP | Data |
|---|---|---|
| `WheelieBlokM` | ega | Inti Blok M (±1,1 × 1,1 km), status jalur dari OpenStreetMap + kelas jalan BIG RBI 25K |
| `WheelieMG` | WheelieMG | `data/BlokM_Pilot_Features_19_oct_26.geojson` apa adanya, status hanya dari jenis jalan |

Kode aplikasi dipakai bersama (`Spike3DMap/Spike3DMap`); tiap target membundel folder datanya sendiri
(`Spike3DMap/AreaBlokM`, `Spike3DMap/AreaMG`).

## Memasang di iPhone (dua aplikasi sekaligus)

Satu perintah mem-build dan memasang **ega** dan **WheelieMG** ke iPhone yang tersambung ke Mac:

```bash
git clone https://github.com/megan0088/wheelie.git && cd wheelie
sh pasang-iphone.sh                               # akun Apple Ega
sh pasang-iphone.sh <TEAM_ID> com.<namamu>.wheelie   # akun Apple lain
```

Persiapan sekali saja:

1. Mac dengan Xcode, dan `brew install xcodegen`.
2. Login akun Apple di Xcode → Settings → Accounts (akun gratis cukup). **Team ID** ada di situ.
3. iPhone: sambungkan lewat kabel, percayai Mac ini, nyalakan **Settings → Privacy & Security → Developer Mode**.
4. Setelah terpasang, buka **Settings → General → VPN & Device Management** dan percayai sertifikat developer.

Akun gratis: aplikasi berlaku ±7 hari, lalu jalankan ulang `pasang-iphone.sh`. Prefix bundle harus unik per akun
(bundle `com.egaaaa.*` hanya bisa dipakai tim Ega).

`Spike3DMap.xcodeproj` tidak disimpan di repo; dibuat ulang oleh script (atau
`WHEELIE_TEAM=<TEAM_ID> WHEELIE_BUNDLE_PREFIX=com.<namamu>.wheelie xcodegen generate` di folder `Spike3DMap`)
supaya berisi Team ID masing-masing. Rute hanya dihitung dari GPS asli saat berada di area peta; izinkan lokasi dan
nyalakan "Lokasi Tepat".

## Memperbarui data

```bash
sh data/blok-m/raw/jalankan.sh            # versi ega: ambil ulang OSM + BIG, bangun jaringan, rute, survei, bundel
python3 data/tools/convert_geojson_area.py data/BlokM_Pilot_Features_19_oct_26.geojson \
    Spike3DMap/AreaMG "Blok M Square" "Blok M BCA"   # versi MG
```

Hasil pipeline Blok M ada di `data/blok-m/`: jaringan kursi roda, rute contoh, lembar survei lapangan
(`koridor-survei.csv`), dan peta pratinjau HTML.

## Catatan data

- Status dan faktor biaya tiap ruas adalah **perkiraan awal**, belum hasil survei. Hasil survei di aplikasi
  disimpan per way OSM dan selalu diutamakan.
- Rating dan ulasan hanya berasal dari ulasan pengguna sungguhan (disimpan di HP); tidak ada angka contoh.
- Sumber: © OpenStreetMap contributors (ODbL); Badan Informasi Geospasial, Rupabumi Indonesia.
