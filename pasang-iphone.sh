#!/bin/sh
# Build & pasang kedua aplikasi (ega dan WheelieMG) ke iPhone yang tersambung ke Mac.
#
#   sh pasang-iphone.sh                       # akun Apple Ega (default)
#   sh pasang-iphone.sh TEAMID com.nama.wheelie   # akun Apple lain: Team ID-mu + prefix bundle unik
#
# Team ID: Xcode → Settings → Accounts → pilih tim → "Team ID" (10 karakter).
# Prefix bundle harus unik per akun, mis. com.<namamu>.wheelie.
set -e

TEAM=${1:-${WHEELIE_TEAM:-R93K2HFM78}}
PREFIX=${2:-${WHEELIE_BUNDLE_PREFIX:-com.egaaaa.wheelie}}
cd "$(dirname "$0")/Spike3DMap"

command -v xcodegen >/dev/null || { echo "xcodegen belum terpasang: brew install xcodegen"; exit 1; }
WHEELIE_TEAM=$TEAM WHEELIE_BUNDLE_PREFIX=$PREFIX xcodegen generate --quiet

# iPhone fisik pertama yang tersambung (UDID berbentuk 00008xxx-xxxxxxxxxxxxxxxx).
DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -E "available|connected" \
    | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}" | head -1)
[ -n "$DEVICE" ] || { echo "Tidak ada iPhone tersambung. Sambungkan lewat kabel, buka kuncinya, dan percayai Mac ini."; exit 1; }
echo "iPhone: $DEVICE · tim $TEAM · bundle $PREFIX.*"

for TARGET in WheelieBlokM WheelieMG; do
    echo "→ build $TARGET"
    xcodebuild -project Spike3DMap.xcodeproj -scheme $TARGET -configuration Debug \
        -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates -quiet build
    echo "→ pasang $TARGET"
    # Koneksi ke iPhone kadang putus sesaat (HP tidur / pindah ke Wi-Fi); coba ulang sampai 3 kali.
    for TRY in 1 2 3; do
        xcrun devicectl device install app --device "$DEVICE" "build/Build/Products/Debug-iphoneos/$TARGET.app" >/dev/null 2>&1 && break
        [ $TRY = 3 ] && { echo "Gagal memasang $TARGET. Buka kunci iPhone, pastikan kabel tersambung, lalu ulangi."; exit 1; }
        echo "  koneksi ke iPhone terputus, coba lagi ($TRY/3)…"; sleep 3
    done
done
echo "Selesai: \"ega\" dan \"WheelieMG\" sudah ada di iPhone."
