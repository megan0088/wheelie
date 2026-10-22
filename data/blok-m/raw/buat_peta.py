import json, sys
jar, rute, out = sys.argv[1:4]
J = json.load(open(jar)); R = json.load(open(rute))
for f in J['features']:  # pangkas properti supaya HTML ringan
    p = f['properties']; f['properties'] = {k: p.get(k) for k in ('nama', 'highway', 'kelas_big', 'status', 'alasan', 'panjang_m', 'kerb') if p.get(k) not in (None, '')}
html = '''<!doctype html><html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Peta Kursi Roda Blok M</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>html,body,#m{height:100%;margin:0;font:13px system-ui}#p{position:absolute;z-index:999;top:10px;right:10px;background:#fff;padding:10px 12px;border-radius:8px;box-shadow:0 2px 8px #0003;max-width:300px}
#p label{display:block;margin:2px 0}.leaflet-tile-pane{filter:grayscale(1) opacity(.55)}.k{display:inline-block;width:22px;height:4px;margin-right:6px;vertical-align:middle}</style></head><body><div id="m"></div>
<div id="p"><b>Jaringan kursi roda Blok M</b><br><small>OSM + BIG RBI 25K · status = asumsi, belum survei</small>
<div id="leg"></div><hr><b>Rute</b><select id="r" style="width:100%"></select><div id="info"></div></div>
<script>
const J=__J__,R=__R__;
const W={aksesibel:'#1a9850',belum_disurvei:'#7b8794',perlu_perhatian:'#f5a623',berisiko:'#d7301f',tidak_bisa:'#000'};
const m=L.map('m').setView([-6.2432,106.7995],16);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'© OpenStreetMap contributors · BIG RBI'}).addTo(m);
const lay={};
for(const s in W){lay[s]=L.geoJSON({type:'FeatureCollection',features:J.features.filter(f=>f.properties.status===s)},{
 style:{color:W[s],weight:s==='berisiko'||s==='tidak_bisa'?4:3,opacity:.9},
 pointToLayer:(f,ll)=>L.circleMarker(ll,{radius:4,color:W[s]}),
 onEachFeature:(f,l)=>l.bindPopup(Object.entries(f.properties).map(([k,v])=>'<b>'+k+'</b>: '+v).join('<br>'))}).addTo(m);
 document.getElementById('leg').insertAdjacentHTML('beforeend',`<label><input type=checkbox checked data-s=${s}> <span class=k style="background:${W[s]}"></span>${s.replace('_',' ')}</label>`);}
document.querySelectorAll('#leg input').forEach(c=>c.onchange=()=>c.checked?lay[c.dataset.s].addTo(m):m.removeLayer(lay[c.dataset.s]));
for(const [n,p] of Object.entries(R.titik)) L.marker([p[1],p[0]]).bindTooltip(n).addTo(m);
const pairs=[...new Set(R.features.map(f=>f.properties.dari+' → '+f.properties.ke))],sel=document.getElementById('r');
pairs.forEach(p=>sel.add(new Option(p,p)));let rl=[];
function show(){rl.forEach(l=>m.removeLayer(l));rl=[];let h='';
 for(const f of R.features.filter(f=>f.properties.dari+' → '+f.properties.ke===sel.value)){const p=f.properties,a=p.jenis==='rute_kursi_roda';
  const l=L.geoJSON(f,{style:{color:a?'#2563eb':'#9333ea',weight:a?7:4,opacity:.75,dashArray:a?null:'6 6'}}).addTo(m);rl.push(l);
  h+=`<p><b style="color:${a?'#2563eb':'#9333ea'}">${a?'Rute kursi roda':'Rute terpendek'}</b><br>${p.panjang_m} m · ~${p.estimasi_menit} mnt<br>berisiko ${p.persen_berisiko}% (${p.m_berisiko||0} m)<br><small>snap ${p.snap_dari_m} / ${p.snap_ke_m} m</small></p>`;}
 document.getElementById('info').innerHTML=h;m.fitBounds(rl[0].getBounds(),{padding:[40,40]});}
sel.onchange=show;show();
</script></body></html>'''
open(out, 'w').write(html.replace('__J__', json.dumps(J, ensure_ascii=False)).replace('__R__', json.dumps(R, ensure_ascii=False)))
