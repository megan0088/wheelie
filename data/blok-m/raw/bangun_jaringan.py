"""Jaringan & rute kursi roda Blok M.

Topologi dari OSM (overpass-jaringan.json); kelas jalan BIG RBI 25K (big-blokm-jalan.geojson)
ditempelkan ke ruas jalan OSM terdekat (<= 12 m) karena geometri keduanya tidak berbagi node.

Biaya ruas = panjang x faktor. Faktor dan status adalah ASUMSI awal, bukan hasil survei:
validasi di lapangan sebelum dipakai untuk memandu pengguna kursi roda.

python3 -I bangun_jaringan.py overpass-jaringan.json ../big-blokm-jalan.geojson ..
"""
import json, sys, math, heapq, collections

osm_f, big_f, out = sys.argv[1], sys.argv[2], sys.argv[3]
el = json.load(open(osm_f))['elements']
node = {e['id']: e for e in el if e['type'] == 'node'}
ways = [e for e in el if e['type'] == 'way']

def meter(a, b):
    return math.hypot((b[0] - a[0]) * 110680 * math.cos(math.radians(a[1])) / math.cos(math.radians(6.24)),
                      (b[1] - a[1]) * 110540)
def ll(n): return (node[n]['lon'], node[n]['lat'])

# --- BIG: indeks grid segmen 25K -------------------------------------------------------------
KELAS_BIG = {'Jalan Arteri': 'arteri', 'Jalan Kolektor': 'kolektor', 'Jalan Lokal': 'lokal', 'Jalan Lain': 'lain'}
SEL = 0.0005  # ~55 m
grid = collections.defaultdict(list)
for f in json.load(open(big_f))['features']:
    g = f['geometry']
    parts = g['coordinates'] if g['type'] == 'MultiLineString' else [g['coordinates']]
    k = KELAS_BIG.get(f['properties']['kelas'], 'lain')
    for c in parts:
        for a, b in zip(c, c[1:]):
            grid[(int(a[0] / SEL), int(a[1] / SEL))].append((a, b, k))
def jarak_seg(p, a, b):
    ax, ay = (a[0] - p[0]) * 110680, (a[1] - p[1]) * 110540
    bx, by = (b[0] - p[0]) * 110680, (b[1] - p[1]) * 110540
    dx, dy = bx - ax, by - ay
    t = 0 if dx == dy == 0 else max(0, min(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy)))
    return math.hypot(ax + t * dx, ay + t * dy)
def kelas_big(p):
    gx, gy = int(p[0] / SEL), int(p[1] / SEL)
    best = (12.0, '')
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            for a, b, k in grid.get((gx + i, gy + j), ()):
                d = jarak_seg(p, a, b)
                if d < best[0]: best = (d, k)
    return best[1]

# --- Penilaian ruas -------------------------------------------------------------------------
TIDAK_DILALUI = {'motorway', 'motorway_link', 'trunk', 'trunk_link', 'busway', 'construction', 'proposed',
                 'raceway', 'bus_guideway', 'abandoned', 'platform'}
PEJALAN = {'footway', 'path', 'pedestrian', 'corridor', 'cycleway', 'elevator'}
JALAN_FAKTOR = {  # menggelinding di badan jalan tanpa trotoar
    'living_street': 1.4, 'residential': 1.6, 'service': 1.6, 'unclassified': 1.8, 'track': 2.5,
    'tertiary': 3.0, 'tertiary_link': 3.0, 'secondary': 5.0, 'secondary_link': 5.0,
    'primary': 6.0, 'primary_link': 6.0}
BIG_FAKTOR = {'arteri': 6.0, 'kolektor': 3.0, 'lokal': 1.6, 'lain': 1.6}
PERMUKAAN_BURUK = {'gravel', 'unpaved', 'dirt', 'grass', 'ground', 'sand', 'mud', 'pebblestone', 'cobblestone', 'sett'}
KERB_RATA = {'flush', 'lowered', 'no'}
KERB_TINGGI = {'raised', 'yes', 'regular', 'rolled'}

def has_sidewalk(t):
    return any(t.get(k) in ('both', 'left', 'right', 'yes') for k in ('sidewalk', 'sidewalk:both')) or \
           t.get('sidewalk:left') == 'yes' or t.get('sidewalk:right') == 'yes'

def nilai(t, big):
    """-> (faktor, status, alasan); faktor None = tidak bisa dilalui."""
    h = t['highway']
    w = t.get('wheelchair', '')
    alasan = []
    if w == 'no': return None, 'tidak_bisa', ['wheelchair=no']
    if h == 'steps' and t.get('ramp:wheelchair') != 'yes' and w not in ('yes', 'limited', 'designated'):
        return None, 'tidak_bisa', ['tangga']
    if t.get('smoothness') in ('very_bad', 'horrible', 'very_horrible', 'impassable'):
        return None, 'tidak_bisa', ['smoothness=' + t['smoothness']]
    try:
        inc = float(str(t.get('incline', '')).rstrip('%'))
    except ValueError:
        inc = 0.0
    if abs(inc) > 12: return None, 'tidak_bisa', [f'incline {inc}%']

    if h in PEJALAN or h == 'steps' or t.get('footway'):
        f, status = 1.0, 'aksesibel' if w in ('yes', 'designated') else 'belum_disurvei'
        alasan.append('jalur pejalan')
        if t.get('footway') == 'crossing' or t.get('crossing'):
            f, status = 1.3, 'perlu_perhatian'; alasan = ['penyeberangan']
            if t.get('crossing') in ('traffic_signals',) or t.get('crossing:signals') == 'yes': f = 1.15; alasan.append('lampu')
    elif has_sidewalk(t):
        f, status = 1.1, 'belum_disurvei'; alasan.append('jalan bertrotoar')
    else:
        f = BIG_FAKTOR[big] if big else JALAN_FAKTOR.get(h, 2.0)
        if big and h in JALAN_FAKTOR: f = max(f, JALAN_FAKTOR[h])
        status = 'berisiko' if f >= 3 else 'perlu_perhatian'
        alasan.append(f'badan jalan {h}' + (f' / BIG {big}' if big else ''))
    if w == 'limited': f *= 1.8; status = 'perlu_perhatian'; alasan.append('wheelchair=limited')
    if t.get('surface') in PERMUKAAN_BURUK: f *= 1.8; alasan.append('surface=' + t['surface'])
    if t.get('smoothness') in ('bad',): f *= 1.6; alasan.append('smoothness=bad')
    if 6 < abs(inc) <= 12: f *= 2.5; alasan.append(f'incline {inc}%')
    try:
        if float(t.get('width', '9')) < 0.9: return None, 'tidak_bisa', ['lebar < 90 cm']
    except ValueError:
        pass
    return f, status, alasan

def node_penalti(n):
    t = node[n].get('tags', {})
    k = t.get('kerb', '')
    if t.get('barrier') == 'kerb' and not k: k = 'raised'
    if k in KERB_TINGGI: return None
    if t.get('wheelchair') == 'no' or t.get('barrier') in ('stile', 'turnstile', 'kissing_gate', 'full-height_turnstile'): return None
    return 0.0

# --- Graf -----------------------------------------------------------------------------------
adj = collections.defaultdict(list)
fitur = []
STAT = collections.Counter()
for w in ways:
    t = w.get('tags', {})
    h = t.get('highway')
    if not h or h in TIDAK_DILALUI or t.get('access') in ('private', 'no') and h not in PEJALAN | {'steps'}:
        continue
    if t.get('foot') == 'no': continue
    ns = [n for n in w['nodes'] if n in node]
    if len(ns) < 2: continue
    mid = ll(ns[len(ns) // 2])
    big = kelas_big(mid) if h in JALAN_FAKTOR else ''
    f, status, alasan = nilai(t, big)
    blok = [n for n in ns if node_penalti(n) is None]
    if blok and f is not None:
        status = 'tidak_bisa' if h in PEJALAN else status
        alasan.append(f'{len(blok)} titik kerb tinggi/penghalang')
    panjang = sum(meter(ll(a), ll(b)) for a, b in zip(ns, ns[1:]))
    STAT[status] += panjang
    if f is not None:
        for a, b in zip(ns, ns[1:]):
            if node_penalti(a) is None or node_penalti(b) is None: continue
            d = meter(ll(a), ll(b))
            biaya = d * f + (30 if h == 'elevator' else 0)
            adj[a].append((b, biaya, d, w['id'])); adj[b].append((a, biaya, d, w['id']))
    fitur.append({'type': 'Feature', 'geometry': {'type': 'LineString', 'coordinates': [list(ll(n)) for n in ns]},
                  'properties': {'osm_way': w['id'], 'nama': t.get('name', ''), 'highway': h, 'kelas_big': big,
                                 'status': status, 'faktor_biaya': round(f, 2) if f else None,
                                 'alasan': '; '.join(alasan), 'panjang_m': round(panjang, 1),
                                 **{k: t[k] for k in ('sidewalk', 'surface', 'smoothness', 'width', 'incline',
                                                      'wheelchair', 'footway', 'crossing', 'lit') if k in t}}})

titik_kerb = []
for n, e in node.items():
    t = e.get('tags', {})
    if 'kerb' in t or t.get('barrier') == 'kerb':
        titik_kerb.append({'type': 'Feature', 'geometry': {'type': 'Point', 'coordinates': [e['lon'], e['lat']]},
                           'properties': {'osm_node': n, 'jenis': 'kerb', 'kerb': t.get('kerb', 'raised?'),
                                          'status': 'aksesibel' if t.get('kerb') in KERB_RATA else 'tidak_bisa'}})

json.dump({'type': 'FeatureCollection', 'name': 'jaringan-kursi-roda-blokm',
           'sumber': 'OSM (ODbL) + BIG Rupabumi Indonesia 25K',
           'catatan': 'status & faktor_biaya adalah asumsi awal, belum hasil survei lapangan',
           'features': fitur + titik_kerb}, open(f'{out}/jaringan-kursi-roda-blokm.geojson', 'w'), ensure_ascii=False)

# --- Rute -----------------------------------------------------------------------------------
def dijkstra(src, dst, aman):
    dist, prev, pq = {src: 0.0}, {}, [(0.0, src)]
    while pq:
        c, u = heapq.heappop(pq)
        if u == dst: break
        if c > dist[u]: continue
        for v, biaya, d, wid in adj[u]:
            nc = c + (biaya if aman else d)
            if nc < dist.get(v, 1e18): dist[v] = nc; prev[v] = (u, wid, d); heapq.heappush(pq, (nc, v))
    if dst not in dist: return None
    path, u = [], dst
    while u != src: path.append((prev[u][0], u, prev[u][1], prev[u][2])); u = prev[u][0]
    return path[::-1]

# Koridor stasiun/mall di OSM sering tidak tersambung ke jalan; snap hanya ke komponen terbesar.
komp, utama = {}, set()
for s in adj:
    if s in komp: continue
    st, anggota = [s], {s}
    komp[s] = s
    while st:
        u = st.pop()
        for v, *_ in adj[u]:
            if v not in komp: komp[v] = s; anggota.add(v); st.append(v)
    if len(anggota) > len(utama): utama = anggota
def snap(lon, lat):
    return min(utama, key=lambda n: meter((lon, lat), ll(n)))

TITIK = {
    'MRT Blok M BCA': (106.797973, -6.244937), 'Blok M Square': (106.800616, -6.244574),
    'Halte TJ Blok M': (106.801859, -6.243291), 'MRT ASEAN': (106.798445, -6.238693),
    'Taman Literasi Martha Tiahahu': (106.798874, -6.243501), 'Pasaraya Grande': (106.802753, -6.244441),
    'Halte M Bloc': (106.798617, -6.24141), 'Plaza Blok M': (106.797882, -6.243972)}
PASANG = [('MRT Blok M BCA', 'Blok M Square'), ('MRT Blok M BCA', 'Halte TJ Blok M'),
          ('MRT ASEAN', 'Taman Literasi Martha Tiahahu'), ('Taman Literasi Martha Tiahahu', 'Pasaraya Grande'),
          ('Halte M Bloc', 'MRT Blok M BCA'), ('Plaza Blok M', 'Blok M Square')]
status_way = {f['properties']['osm_way']: f['properties']['status'] for f in fitur}
rute, ringkas = [], []
for a, b in PASANG:
    s, d = snap(*TITIK[a]), snap(*TITIK[b])
    for jenis, aman in (('rute_kursi_roda', True), ('rute_terpendek', False)):
        p = dijkstra(s, d, aman)
        if not p: ringkas.append((a, b, jenis, None)); continue
        per, per_way = collections.Counter(), collections.Counter()
        for u, v, wid, m in p: per[status_way[wid]] += m; per_way[wid] += m
        total = sum(per.values())
        props = {'dari': a, 'ke': b, 'jenis': jenis, 'panjang_m': round(total),
                 'snap_dari_m': round(meter(TITIK[a], ll(s))), 'snap_ke_m': round(meter(TITIK[b], ll(d))),
                 'estimasi_menit': round(total / 50),  # ~3 km/jam kursi roda manual
                 **{f'm_{k}': round(v) for k, v in per.items()},
                 'persen_berisiko': round(100 * per['berisiko'] / total, 1) if total else 0,
                 'osm_ways': [[wid, round(m, 1)] for wid, m in per_way.items()]}  # urut sepanjang rute
        rute.append({'type': 'Feature', 'properties': props,
                     'geometry': {'type': 'LineString', 'coordinates': [list(ll(p[0][0]))] + [list(ll(v)) for _, v, _, _ in p]}})
        ringkas.append((a, b, jenis, props))
json.dump({'type': 'FeatureCollection', 'name': 'rute-kursi-roda-blokm',
           'titik': {k: list(v) for k, v in TITIK.items()}, 'features': rute},
          open(f'{out}/rute-kursi-roda-blokm.geojson', 'w'), ensure_ascii=False)

print('jaringan:', len(fitur), 'ruas,', len(titik_kerb), 'titik kerb')
for k, v in STAT.most_common(): print(f'  {k:16s} {v / 1000:6.1f} km')
print('BIG tertempel di', sum(1 for f in fitur if f['properties']['kelas_big']), 'ruas jalan;',
      'komponen utama', len(utama), 'dari', len(adj), 'node')
for a, b, j, p in ringkas:
    print(f'{a} -> {b} [{j}]:', 'TIDAK TERSAMBUNG' if not p else
          f"{p['panjang_m']} m, ~{p['estimasi_menit']} mnt, berisiko {p['persen_berisiko']}%, " +
          ', '.join(f"{k[2:]} {v}" for k, v in p.items() if k.startswith('m_')))
