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
  // Only handle GET requests — never try to cache POST/PUT/DELETE
  if (e.request.method !== 'GET') return;

  // Pass through all API calls without caching
  const url = e.request.url;
  if (
    url.includes('api.github.com') ||
    url.includes('api.twitch.tv') ||
    url.includes('id.twitch.tv') ||
    url.includes('supabase.co') ||
    url.includes('discord.com') ||
    url.includes('youtube.com/iframe_api')
  ) {
    e.respondWith(fetch(e.request));
    return;
  }

  // Network first for everything — cache only as offline fallback
  e.respondWith(
    fetch(e.request).then(res => {
      const clone = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, clone));
      return res;
    }).catch(() => caches.match(e.request))
  );
});
