import json, sys, collections
out, layers = sys.argv[1], sys.argv[2:]
SKALA = {'547': '25K', '338': '10K'}
feats, seen = [], set()
for f in layers:
    lid = f.split('big-')[1].split('-')[0]
    for x in json.load(open(f)).get('features', []):
        key = (lid, x['properties']['OBJECTID'])
        if key in seen: continue
        seen.add(key)
        p = {k: (v.strip() if isinstance(v, str) else v) for k, v in x['properties'].items()}
        p = {k: v for k, v in p.items() if v not in (None, '', 999) and k != 'SHAPE_Length'}
        feats.append({'type': 'Feature', 'properties': {'skala': SKALA[lid], 'kelas': p.pop('REMARK', ''), 'nama': p.pop('NAMRJL', ''), **p},
                      'geometry': x['geometry']})
json.dump({'type': 'FeatureCollection', 'name': 'big-blokm-jalan',
           'sumber': 'Badan Informasi Geospasial, Rupabumi Indonesia (geoservices.big.go.id) layer 547 (25K) & 338 (10K)',
           'features': feats}, open(out, 'w'), ensure_ascii=False)
print(len(feats), 'ruas')
print(collections.Counter((f['properties']['skala'], f['properties']['kelas']) for f in feats).most_common())
print('bernama:', sum(1 for f in feats if f['properties']['nama']), collections.Counter(f['properties']['nama'] for f in feats if f['properties']['nama']).most_common(8))
