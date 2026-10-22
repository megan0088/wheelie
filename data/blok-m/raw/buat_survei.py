"""Lembar survei ruas di rute kursi roda Blok M; kolom mengikuti the-breeze/koridor-survei.csv.

panjang_di_area_m = panjang ruas yang benar-benar dilewati rute kursi roda (bukan seluruh way).
Urutan baris = urutan dilalui sepanjang rute, supaya surveyor bisa berjalan berurutan.

python3 -I buat_survei.py overpass-jaringan.json ../jaringan-kursi-roda-blokm.geojson ../rute-kursi-roda-blokm.geojson ../koridor-survei.csv
"""
import json, sys, csv

osm_f, jar_f, rute_f, out = sys.argv[1:5]
way = {e['id']: e for e in json.load(open(osm_f))['elements'] if e['type'] == 'way'}
jar = {f['properties']['osm_way']: f for f in json.load(open(jar_f))['features'] if 'osm_way' in f['properties']}

FIELDS = ['surface', 'smoothness', 'lit', 'covered', 'handrail', 'width', 'incline', 'kerb', 'wheelchair',
          'ramp:wheelchair', 'tactile_paving', 'name']
TAMBAHAN = ['status_model', 'alasan_model', 'kelas_big', 'rute', 'lat_tengah', 'lon_tengah']
SURVEI = ['SURVEI_lebar_cm', 'SURVEI_kemiringan_derajat', 'SURVEI_undakan_cm', 'SURVEI_ada_ramp', 'SURVEI_hambatan',
          'SURVEI_teduh', 'SURVEI_foto', 'SURVEI_status', 'SURVEI_tanggal', 'SURVEI_oleh']

dilalui, rute_way = {}, {}
for f in json.load(open(rute_f))['features']:
    p = f['properties']
    if p['jenis'] != 'rute_kursi_roda': continue
    for wid, m in p['osm_ways']:
        dilalui[wid] = max(dilalui.get(wid, 0), m)  # dict menjaga urutan kemunculan pertama
        rute_way.setdefault(wid, []).append(f"{p['dari']} > {p['ke']}")

rows = []
for i, (wid, m) in enumerate(dilalui.items(), 1):
    t, j = way[wid].get('tags', {}), jar[wid]
    c = j['geometry']['coordinates'][len(j['geometry']['coordinates']) // 2]
    jp = j['properties']
    rows.append({'kode': f'BM{i:02d}', 'osm_way': wid, 'jenis': t['highway'], 'panjang_m': jp['panjang_m'],
                 'panjang_di_area_m': round(m, 1), 'osm_diperbarui': way[wid]['timestamp'][:10],
                 **{k: t.get(k, '') for k in FIELDS},
                 'status_model': jp['status'], 'alasan_model': jp['alasan'], 'kelas_big': jp['kelas_big'],
                 'rute': ' | '.join(rute_way[wid]), 'lat_tengah': round(c[1], 6), 'lon_tengah': round(c[0], 6)})

with open(out, 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['kode', 'osm_way', 'jenis', 'panjang_m', 'panjang_di_area_m', 'osm_diperbarui']
                       + FIELDS + TAMBAHAN + SURVEI)
    w.writeheader()
    for r in rows: w.writerow(r)

prioritas = {'berisiko': 0, 'tidak_bisa': 0, 'perlu_perhatian': 1, 'belum_disurvei': 2, 'aksesibel': 3}
print(len(rows), 'ruas,', round(sum(r['panjang_di_area_m'] for r in rows)), 'm untuk disurvei')
for s in sorted({r['status_model'] for r in rows}, key=prioritas.get):
    rs = [r for r in rows if r['status_model'] == s]
    print(f'  {s:16s} {len(rs):3d} ruas {round(sum(r["panjang_di_area_m"] for r in rs)):5d} m')
