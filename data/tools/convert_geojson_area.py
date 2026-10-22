"""GeoJSON pilot (ekspor overpass turbo) → bsd.json + tempat.json untuk Wheelie. Tanpa gedung 3D.

Pakai: python3 convert_geojson_area.py <fitur.geojson> <folder keluaran> <tujuan bawaan> <nama titik mulai>

- GeoJSON tidak punya id node, jadi persimpangan = titik dengan koordinat sama persis (dibulatkan 7 desimal).
- Graf jalur: jalan & jalur pejalan kaki; tangga = 'steps'; busway (jalur TransJakarta) dibuang.
- Penghalang (titik 'barrier' yang menempel di jalur): turnstile / tembok → 'barrier_closed', sisanya 'barrier'.
"""
import json, math, sys, heapq, collections

src, outdir, goal_name, start_name = sys.argv[1:5]
features = json.load(open(src))['features']

lines = [f for f in features if f['geometry']['type'] == 'LineString']
pts = [f for f in features if f['geometry']['type'] == 'Point']
lats = sorted(c[1] for f in lines for c in f['geometry']['coordinates'])
lons = sorted(c[0] for f in lines for c in f['geometry']['coordinates'])
q = lambda xs, r: xs[int(r * (len(xs) - 1))]
BB = (q(lats, .01), q(lats, .99), q(lons, .01), q(lons, .99))  # minLat, maxLat, minLon, maxLon (buang pencilan)
LAT0, LON0 = round((BB[0] + BB[1]) / 2, 4), round((BB[2] + BB[3]) / 2, 4)


def xz(lat, lon):
    return [round((lon - LON0) * 111320 * math.cos(math.radians(LAT0)), 2), round(-(lat - LAT0) * 110540, 2)]


def key(c):
    return (round(c[0], 7), round(c[1], 7))


WALK = {'footway', 'path', 'pedestrian', 'corridor', 'living_street', 'residential', 'service', 'unclassified', 'road',
        'tertiary', 'tertiary_link', 'secondary', 'secondary_link', 'primary', 'primary_link', 'trunk', 'trunk_link'}
KIND = {'tertiary_link': 'tertiary', 'secondary_link': 'secondary', 'primary_link': 'primary', 'trunk': 'primary',
        'trunk_link': 'primary', 'road': 'unclassified', 'corridor': 'footway', 'pedestrian': 'footway'}
CLOSED = {'turnstile', 'full-height_turnstile', 'kissing_gate', 'jersey_barrier', 'wall', 'fence'}

barriers = {}
for f in pts:
    b = f['properties'].get('barrier')
    if b:
        closed = b in CLOSED or f['properties'].get('locked') == 'yes'
        barriers[key(f['geometry']['coordinates'])] = 'barrier_closed' if closed else 'barrier'

segs, names, paths = {}, {}, []
for f in lines:
    hw = f['properties'].get('highway')
    if hw not in WALK and hw != 'steps':
        continue
    kind = 'steps' if hw == 'steps' else KIND.get(hw, hw)
    cs = [key(c) for c in f['geometry']['coordinates']]
    paths.append({'kind': kind, 'pts': [xz(c[1], c[0]) for c in cs]})
    for a, b in zip(cs, cs[1:]):
        if a == b:
            continue
        k = kind
        for n in (a, b):  # penghalang di salah satu ujung segmen
            bk = barriers.get(n)
            if bk == 'barrier_closed' or (bk == 'barrier' and k not in ('barrier_closed', 'steps')):
                k = bk
        segs[tuple(sorted((a, b)))] = k
        names[tuple(sorted((a, b)))] = f['properties'].get('name', '')

ids = sorted({n for ab in segs for n in ab})
index = {n: i for i, n in enumerate(ids)}
keys = sorted(segs)
nodes = [xz(n[1], n[0]) for n in ids]
edges = [[index[a], index[b]] for a, b in keys]
kinds = [segs[k] for k in keys]
street = [names[k] for k in keys]  # nama jalan untuk instruksi navigasi

KMAP = {'station': 'Stasiun', 'subway_entrance': 'Stasiun', 'bus_station': 'Halte', 'platform': 'Halte', 'mall': 'Mall',
        'department_store': 'Mall', 'park': 'Taman', 'garden': 'Taman', 'playground': 'Taman', 'hospital': 'Rumah sakit',
        'clinic': 'Rumah sakit', 'marketplace': 'Pasar', 'library': 'Perpustakaan', 'museum': 'Museum',
        'place_of_worship': 'Tempat ibadah', 'toilets': 'Toilet umum', 'cafe': 'Kafe', 'ice_cream': 'Kafe',
        'restaurant': 'Restoran', 'fast_food': 'Restoran', 'food_court': 'Restoran', 'bakery': 'Kafe',
        'convenience': 'Toko', 'supermarket': 'Supermarket', 'pharmacy': 'Apotek', 'bank': 'Toko', 'atm': 'Toko',
        'parking': 'Parkir', 'hotel': 'Hotel', 'school': 'Sekolah', 'college': 'Kampus', 'university': 'Kampus',
        'theatre': 'Rekreasi', 'cinema': 'Rekreasi', 'sports_centre': 'Rekreasi'}
places, names = [], set()
for f in features:
    t = f['properties']
    name = t.get('name')
    if not name or name in names or f['geometry']['type'] == 'LineString':
        continue
    raw = t.get('railway') if t.get('railway') in KMAP else None
    raw = raw or t.get('amenity') or t.get('shop') or t.get('leisure') or t.get('tourism') or t.get('public_transport')
    kind = KMAP.get(raw)
    if not kind:
        continue
    g = f['geometry']
    if g['type'] == 'Point':
        lon, lat = g['coordinates'][:2]
    else:  # Polygon: pakai rata-rata titik cincin luar
        ring = g['coordinates'][0]
        lon, lat = sum(c[0] for c in ring) / len(ring), sum(c[1] for c in ring) / len(ring)
    names.add(name)
    places.append({'name': name, 'kind': kind, 'lat': lat, 'lon': lon, 'p': xz(lat, lon),
                   'inArea': BB[0] < lat < BB[1] and BB[2] < lon < BB[3],
                   'wheelchair': t.get('wheelchair', 'unknown'), 'toilet': t.get('toilets:wheelchair', 'unknown'),
                   'lift': 'unknown', 'source': 'OpenStreetMap via data pilot Blok M (diisi relawan, belum diverifikasi)',
                   'hours': t.get('opening_hours'), 'street': t.get('addr:street'), 'updated': t.get('check_date')})
order = {'Stasiun': 0, 'Halte': 1, 'Mall': 2, 'Taman': 3, 'Rumah sakit': 4}
places.sort(key=lambda p: (p['wheelchair'] in ('unknown', 'no'), order.get(p['kind'], 9), p['name']))

# Rute awal (tampilan 3D / mode uji): titik mulai → tujuan bawaan.
adj = [[] for _ in nodes]
for (a, b), k in zip(edges, kinds):
    if k in ('steps', 'barrier_closed'):
        continue
    w = math.dist(nodes[a], nodes[b]); adj[a].append((b, w)); adj[b].append((a, w))


def nearest(p):
    return min((i for i in range(len(nodes)) if adj[i]), key=lambda i: math.dist(nodes[i], p))


by_name = {p['name']: p for p in places}
start, goal = nearest(by_name[start_name]['p']), nearest(by_name[goal_name]['p'])
dist, prev, pq = {start: 0}, {}, [(0, start)]
while pq:
    d, u = heapq.heappop(pq)
    if u == goal:
        break
    if d > dist[u]:
        continue
    for v, w in adj[u]:
        if d + w < dist.get(v, 1e18):
            dist[v] = d + w; prev[v] = u; heapq.heappush(pq, (d + w, v))
if goal not in dist:
    sys.exit(f'Tidak ada jalur dari {start_name} ke {goal_name} — graf terputus')
route, n = [], goal
while n != start:
    route.append(nodes[n]); n = prev[n]
route.append(nodes[start]); route.reverse()

snap = {'minLat': BB[0], 'maxLat': BB[1], 'minLon': BB[2], 'maxLon': BB[3], 'min': xz(BB[1], BB[2]), 'max': xz(BB[0], BB[3])}
out = {'graph': {'nodes': nodes, 'edges': edges, 'kinds': kinds, 'goal': goal, 'names': street}, 'origin': [LAT0, LON0], 'snapshot': snap,
       'buildings': [], 'paths': paths, 'areas': [], 'pois': [], 'route': route}
json.dump(out, open(f'{outdir}/bsd.json', 'w'), separators=(',', ':'))
json.dump(places, open(f'{outdir}/tempat.json', 'w'), ensure_ascii=False)
print('pusat', LAT0, LON0, '· bbox', BB)
print(len(nodes), 'node,', len(edges), 'segmen', collections.Counter(kinds).most_common(10))
print(len(places), 'tempat ·', collections.Counter(p['kind'] for p in places).most_common(), '· rute awal', round(dist[goal]), 'm')
