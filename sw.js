// 144(P) Plan service worker — caches only static app files. Account data lives in app storage, never in this cache.
const CACHE = '144p-static-v5';
const STATIC = /\.(?:html|js|css|png|jpe?g|webp|svg|ico|json|woff2?|ttf)$/i;
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('.supabase.co')) return; // live account data is never cached
  const isStatic = STATIC.test(url.pathname) || url.hostname.includes('fonts.g') || url.hostname.includes('unpkg.com') || url.hostname.includes('jsdelivr.net');
  if (!isStatic || url.search.includes('invite=')) return; // never cache invitation links or dynamic responses
  e.respondWith(fetch(req).then(res => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return res; }).catch(() => caches.match(req)));
});
