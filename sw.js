// 144(P) Plan service worker — caches only static app files. Account data lives in app storage, never in this cache.
const CACHE = '144p-static-v36';
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

// Daily reminders and messages from church leaders (sent by the send-push server function).
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'What will you give today?', {
    body: d.body || 'Open the app and log your time.',
    icon: 't4g/t4g-icon-192.png', badge: 't4g/t4g-icon-48.png',
    tag: d.tag || 'time4god', renotify: true, data: { url: d.url || 'https://time4god.app/' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || 'https://time4god.app/';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if (c.url.split('#')[0] === url.split('#')[0] && 'focus' in c) return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
