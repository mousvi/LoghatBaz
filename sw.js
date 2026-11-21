var C="lughatbaz-v6",F=["./","./index.html","./manifest.json","./icon-192.png","./icon-512.png"];
self.addEventListener("install",function(e){
  e.waitUntil(caches.open(C).then(function(c){return c.addAll(F)}).then(function(){return self.skipWaiting()}));
});
self.addEventListener("activate",function(e){
  e.waitUntil(caches.keys().then(function(k){return Promise.all(k.filter(function(x){return x!==C}).map(function(x){return caches.delete(x)}))}).then(function(){return self.clients.claim()}));
});
self.addEventListener("fetch",function(e){
  var q=e.request;
  if(q.method!=="GET"||new URL(q.url).origin!==self.location.origin)return;
  e.respondWith(fetch(q,{cache:"no-store"}).then(function(r){
    if(r&&r.ok){var copy=r.clone();caches.open(C).then(function(c){c.put(q,copy)});}
    return r;
  }).catch(function(){return caches.match(q).then(function(r){return r||caches.match("./index.html")})}));
});