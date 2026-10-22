"""Jaringan kursi roda inti Blok M → bundel aplikasi (Spike3DMap/AreaBlokM: bsd.json, tempat.json, area.json).

Format bsd.json sama dengan data/tools/convert_geojson_area.py, ditambah per segmen di `graph`:
  status  : aman | hatiHati | tidakBisa | belumDicek  (= enum Condition di aplikasi)
  factor  : pengali biaya dari bangun_jaringan.py (null = tidak bisa dilewati)
  reasons : alasan status, teks pendek
  osmWay  : id way OSM — kunci hasil survei di aplikasi, supaya tetap menempel saat graf dibuat ulang

python3 -I export_aplikasi.py overpass-jaringan.json ../jaringan-kursi-roda-blokm.geojson <BBOX s,w,n,e> <folder AreaBlokM>
"""
import json, sys, math, heapq, collections

osm_f, jar_f, bbox, outdir = sys.argv[1:5]
S, W, N, E = map(float, bbox.split(','))
LAT0, LON0 = round((S + N) / 2, 4), round((W + E) / 2, 4)
def xz(lat, lon):
    return [round((lon - LON0) * 111320 * math.cos(math.radians(LAT0)), 2), round(-(lat - LAT0) * 110540, 2)]

raw = json.load(open(osm_f))
el = raw['elements']
node = {e['id']: e for e in el if e['type'] == 'node'}
way = {e['id']: e for e in el if e['type'] == 'way'}
jar = [f for f in json.load(open(jar_f))['features'] if 'osm_way' in f['properties']]

STATUS = {'aksesibel': 'aman', 'belum_disurvei': 'belumDicek', 'perlu_perhatian': 'hatiHati',
          'berisiko': 'hatiHati', 'tidak_bisa': 'tidakBisa'}
KIND = {'tertiary_link': 'tertiary', 'secondary_link': 'secondary', 'primary_link': 'primary', 'road': 'unclassified',
        'corridor': 'footway', 'pedestrian': 'footway', 'path': 'footway', 'cycleway': 'footway', 'elevator': 'footway'}
CLOSED = {'turnstile', 'full-height_turnstile', 'kissing_gate', 'jersey_barrier', 'wall', 'fence', 'stile'}

KELAS = {'arteri': 'Jalan arteri', 'kolektor': 'Jalan kolektor', 'lokal': 'Jalan lokal'}
def ramah(alasan):
    """Alasan teknis bangun_jaringan.py → teks pendek untuk pengguna; yang paling penting di depan."""
    out = []
    for a in alasan.split('; ') if alasan else []:
        if a.startswith('badan jalan'):
            out.insert(0, 'Jalan mobil tanpa trotoar')
            big = a.split('BIG ')[-1] if 'BIG ' in a else ''
            if big in KELAS: out.append(KELAS[big])
        elif a == 'penyeberangan': out.insert(0, 'Penyeberangan jalan')
        elif a == 'lampu': out.append('Ada lampu penyeberangan')
        elif a == 'tangga': out.insert(0, 'Tangga')
        elif a.startswith('surface='): out.append('Permukaan kasar')
        elif a.startswith('smoothness='): out.append('Permukaan rusak')
        elif a.startswith('incline'): out.append('Tanjakan curam')
        elif 'kerb' in a: out.insert(0, 'Trotoar tinggi')
        elif a == 'wheelchair=no': out.insert(0, 'Tidak bisa untuk kursi roda')
        elif a == 'wheelchair=limited': out.append('Akses terbatas')
        elif a.startswith('lebar'): out.insert(0, 'Jalur sempit')
        elif a.startswith('penghalang'): out.insert(0, a[0].upper() + a[1:])
    return '; '.join(dict.fromkeys(out))

def barrier(n):
    t = node[n].get('tags', {})
    b = t.get('barrier')
    if not b or b == 'kerb': return None
    return 'barrier_closed' if b in CLOSED or t.get('locked') == 'yes' else 'barrier'

idx, nodes, edges, kinds, status, factor, reasons, ways_of, paths = {}, [], [], [], [], [], [], [], []
seen = set()
def ni(n):
    if n not in idx:
        idx[n] = len(nodes); nodes.append(xz(node[n]['lat'], node[n]['lon']))
    return idx[n]

for f in jar:
    p = f['properties']
    w = way[p['osm_way']]
    ns = [n for n in w['nodes'] if n in node]
    kind = 'steps' if p['highway'] == 'steps' else KIND.get(p['highway'], p['highway'])
    paths.append({'kind': kind, 'pts': [xz(node[n]['lat'], node[n]['lon']) for n in ns]})
    for a, b in zip(ns, ns[1:]):
        if a == b or (min(a, b), max(a, b)) in seen: continue
        seen.add((min(a, b), max(a, b)))
        k, st, fa, why = kind, STATUS[p['status']], p['faktor_biaya'], ramah(p['alasan'])
        for bk in (barrier(a), barrier(b)):  # penghalang di ujung segmen
            if bk == 'barrier_closed': k, st, fa, why = bk, 'tidakBisa', None, 'Penghalang tertutup'
            elif bk == 'barrier' and k not in ('barrier_closed', 'steps'):
                k = bk; st = 'hatiHati' if st != 'tidakBisa' else st; why = 'Penghalang (cek celah)' + ('; ' + why if why else '')
        edges.append([ni(a), ni(b)]); kinds.append(k); status.append(st)
        factor.append(fa); reasons.append(why); ways_of.append(p['osm_way'])

# Tempat: pakai daftar yang sudah dikurasi di tempat.json, hitung ulang posisi ke pusat baru.
old = json.load(open(f'{outdir}/tempat.json'))
places = []
for pl in old:
    pl['p'] = xz(pl['lat'], pl['lon'])
    pl['inArea'] = S < pl['lat'] < N and W < pl['lon'] < E
    places.append(pl)
places.sort(key=lambda p: (not p['inArea'], p['wheelchair'] in ('unknown', 'no'), p['name']))

# Rute awal (titik mulai simulasi): MRT Blok M BCA → tujuan bawaan, pakai biaya yang sama dengan aplikasi.
area = json.load(open(f'{outdir}/area.json'))
adj = collections.defaultdict(list)
for i, (a, b) in enumerate(edges):
    if factor[i] is None: continue
    w = math.dist(nodes[a], nodes[b]) * factor[i]
    adj[a].append((b, w)); adj[b].append((a, w))
def nearest(p): return min(adj, key=lambda i: math.dist(nodes[i], p))
by_name = {p['name']: p for p in places}
start, goal = nearest(by_name['Blok M BCA']['p']), nearest(by_name[area['defaultDestination']]['p'])
dist, prev, pq = {start: 0}, {}, [(0, start)]
while pq:
    d, u = heapq.heappop(pq)
    if u == goal: break
    if d > dist[u]: continue
    for v, w in adj[u]:
        if d + w < dist.get(v, 1e18): dist[v] = d + w; prev[v] = u; heapq.heappush(pq, (d + w, v))
if goal not in dist: sys.exit('Tujuan bawaan tidak terjangkau dari Blok M BCA')
route, n = [], goal
while n != start: route.append(nodes[n]); n = prev[n]
route.append(nodes[start]); route.reverse()

snap = {'minLat': S, 'maxLat': N, 'minLon': W, 'maxLon': E, 'min': xz(N, W), 'max': xz(S, E)}
out = {'graph': {'nodes': nodes, 'edges': edges, 'kinds': kinds, 'goal': goal, 'status': status, 'factor': factor,
                 'reasons': reasons, 'osmWay': ways_of},
       'origin': [LAT0, LON0], 'snapshot': snap, 'buildings': [], 'paths': paths, 'areas': [], 'pois': [], 'route': route}
json.dump(out, open(f'{outdir}/bsd.json', 'w'), separators=(',', ':'), ensure_ascii=False)
json.dump(places, open(f'{outdir}/tempat.json', 'w'), ensure_ascii=False)
area.update({'center': [LAT0, LON0], 'span': round(max(N - S, E - W) * 1.3, 4),
             'coverage': 'Inti Blok M – Melawai (OSM + BIG RBI 25K)', 'has3D': False,
             'dataUpdated': raw['osm3s']['timestamp_osm_base'][:10]})
json.dump(area, open(f'{outdir}/area.json', 'w'), ensure_ascii=False, indent=1)

print(len(nodes), 'node,', len(edges), 'segmen ·', collections.Counter(status).most_common())
print(sum(p['inArea'] for p in places), 'dari', len(places), 'tempat di dalam area · rute awal', len(route), 'titik')
