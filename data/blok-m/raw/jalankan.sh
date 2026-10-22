#!/bin/sh
# Pipeline data kursi roda inti Blok M. Ubah BBOX (selatan,barat,utara,timur) lalu jalankan: sh raw/jalankan.sh
set -e
BBOX="-6.2475,106.7950,-6.2375,106.8055"
cd "$(dirname "$0")"
S=${BBOX%%,*}; R=${BBOX#*,}; W=${R%%,*}; R=${R#*,}; N=${R%%,*}; E=${R#*,}

for q in kursi-roda jaringan; do
  sed "s/{{BBOX}}/$BBOX/" query-$q.overpassql | curl -sf --max-time 240 -A "Wheelie-research/1.0" \
    --data-urlencode data@- https://overpass-api.de/api/interpreter -o overpass-$q.json
done

B="https://geoservices.big.go.id/rbi/rest/services/BASEMAP/Rupabumi_Indonesia/MapServer"
rm -f big-*.geojson
for id in 547 338; do  # RBI 25K & 10K; skala 5K belum mencakup Jakarta
  curl -sf --max-time 90 "$B/$id/query" --data-urlencode "geometry=$W,$S,$E,$N" -d geometryType=esriGeometryEnvelope \
    -d inSR=4326 -d outSR=4326 -d spatialRel=esriSpatialRelIntersects -d outFields='*' -d resultRecordCount=1000 \
    -d orderByFields=OBJECTID -d f=geojson -o big-$id-0.geojson
done

python3 -I convert_kursi_roda.py overpass-kursi-roda.json ../osm-blokm-kursi-roda.geojson
python3 -I merge_big.py ../big-blokm-jalan.geojson big-*.geojson
python3 -I bangun_jaringan.py overpass-jaringan.json ../big-blokm-jalan.geojson ..
python3 -I buat_survei.py overpass-jaringan.json ../jaringan-kursi-roda-blokm.geojson ../rute-kursi-roda-blokm.geojson ../koridor-survei.csv
python3 -I buat_peta.py ../jaringan-kursi-roda-blokm.geojson ../rute-kursi-roda-blokm.geojson ../peta-kursi-roda-blokm.html
python3 -I export_aplikasi.py overpass-jaringan.json ../jaringan-kursi-roda-blokm.geojson "$BBOX" ../../../Spike3DMap/AreaBlokM
