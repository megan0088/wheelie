import json, sys, collections
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
KEEP = ['name', 'highway', 'footway', 'sidewalk', 'surface', 'smoothness', 'width', 'incline', 'kerb', 'kerb:height',
        'wheelchair', 'wheelchair:description', 'toilets:wheelchair', 'ramp', 'ramp:wheelchair', 'tactile_paving',
        'handrail', 'step_count', 'crossing', 'crossing:signals', 'lit', 'covered', 'entrance', 'door', 'level',
        'amenity', 'shop', 'public_transport', 'railway', 'bus', 'capacity:disabled', 'opening_hours', 'operator']
def kategori(t):
    h = t.get('highway', '')
    if h == 'steps': return 'tangga'
    if h == 'elevator': return 'lift'
    if h == 'crossing' or t.get('footway') == 'crossing': return 'penyeberangan'
    if 'kerb' in t or t.get('barrier') == 'kerb': return 'trotoar_kerb'
    if 'entrance' in t: return 'pintu_masuk'
    if t.get('amenity') == 'toilets': return 'toilet'
    if 'public_transport' in t or h == 'bus_stop': return 'transportasi_umum'
    if 'capacity:disabled' in t: return 'parkir_difabel'
    if h in ('footway', 'path', 'pedestrian', 'living_street') or 'footway' in t: return 'jalur_pejalan'
    if 'sidewalk' in t: return 'jalan_bertrotoar'
    return 'tempat'
def status(t):
    w = t.get('wheelchair', '')
    if w: return w
    if t.get('highway') == 'steps' and t.get('ramp:wheelchair') != 'yes': return 'no'
    k = t.get('kerb', '')
    if k in ('flush', 'lowered', 'no'): return 'yes'
    if k in ('raised', 'yes', 'regular'): return 'no'
    return 'unknown'
feats = []
for e in d['elements']:
    t = e.get('tags', {})
    if not t: continue
    if e['type'] == 'node':
        g = {'type': 'Point', 'coordinates': [e['lon'], e['lat']]}
    elif e['type'] == 'way':
        c = [[p['lon'], p['lat']] for p in e['geometry']]
        closed = len(c) > 3 and c[0] == c[-1] and t.get('highway') not in ('footway', 'path', 'pedestrian', 'steps')
        g = {'type': 'Polygon', 'coordinates': [c]} if closed else {'type': 'LineString', 'coordinates': c}
    else:
        b = e.get('bounds')
        if not b: continue
        g = {'type': 'Point', 'coordinates': [(b['minlon'] + b['maxlon']) / 2, (b['minlat'] + b['maxlat']) / 2]}
    props = {'osm_id': f"{e['type']}/{e['id']}", 'kategori': kategori(t), 'akses_kursi_roda': status(t),
             'osm_diperbarui': e.get('timestamp', '')[:10], **{k: t[k] for k in KEEP if k in t}}
    feats.append({'type': 'Feature', 'properties': props, 'geometry': g})
json.dump({'type': 'FeatureCollection', 'name': 'blokm-kursi-roda',
           'sumber': 'OpenStreetMap contributors (ODbL), Overpass ' + d['osm3s']['timestamp_osm_base'],
           'features': feats}, open(out, 'w'), ensure_ascii=False)
print(len(feats), 'fitur')
for k, v in collections.Counter((f['properties']['kategori'], f['properties']['akses_kursi_roda']) for f in feats).most_common(): print(' ', k, v)
