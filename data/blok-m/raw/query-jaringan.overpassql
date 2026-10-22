[out:json][timeout:180][bbox:{{BBOX}}];
(
  way["highway"];
  node["kerb"];
  node["barrier"];
  node["highway"~"^(crossing|elevator|steps)$"];
  node["entrance"];
)->.a;
(.a; node(w.a););
out meta;
