const CACHE_NAME = "kad-braille-v2";

const PRECACHE_ASSETS = [
  "./",
  "./index.html",
  "./styles.css",
  "./app.js",
  "./manifest.webmanifest",
  "./icon.svg",
  "./audio/12x.m4a",
  "./audio/3x%20%2B%20x.m4a",
  "./audio/4x%20%2B%205x.m4a",
  "./audio/4x.m4a",
  "./audio/6x.m4a",
  "./audio/8x%20%2B%204x.m4a",
  "./audio/9x.m4a",
  "./audio/x%2B5x.m4a"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Never intercept external Google Drive / API network requests
  if (url.origin !== self.location.origin) {
    return;
  }

  // Always prefer network for same-origin Google Drive mirror so Sync Now gets fresh updates
  if (url.pathname.includes("/gdrive-cache/")) {
    event.respondWith(
      fetch(event.request).then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return response;
      }).catch(() => caches.match(event.request, { ignoreSearch: true }))
    );
    return;
  }

  // For navigation (e.g. /index.html?card=3x%2Bx), return cached index.html offline
  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request).catch(() => caches.match("./index.html", { ignoreSearch: true }))
    );
    return;
  }

  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return response;
      });
    })
  );
});
