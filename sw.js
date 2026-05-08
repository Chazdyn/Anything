// Control.Dyn Service Worker
const CACHE = 'controldyn-v2';
const ASSETS = [
  './Control.Dyn.html',
  './control.css',
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  // Always pass through API calls
  if (e.request.url.includes('api.github.com') ||
      e.request.url.includes('api.twitch.tv') ||
      e.request.url.includes('id.twitch.tv') ||
      e.request.url.includes('supabase.co')) {
    e.respondWith(fetch(e.request).catch(() =>
      new Response('{}', { headers: { 'Content-Type': 'application/json' }})
    ));
    return;
  }

  // Network first everywhere — cache is fallback for offline only
  e.respondWith(
    fetch(e.request).then(res => {
      const clone = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, clone));
      return res;
    }).catch(() => caches.match(e.request))
  );
});
