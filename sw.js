/* ═══════════════════════════════════════════════════════════════════
   VESSEL GAMES · Service worker

   Su único trabajo es que la app abra rápido y no se caiga si el
   teléfono pierde señal un momento. NO cachea la tienda de forma
   agresiva a propósito:

   · La página (index.html) va SIEMPRE a la red primero. Si se sirviera
     de caché, un cliente podría quedarse días con precios viejos, y
     cada vez que subimos un cambio tendría que borrar datos del
     navegador para verlo. Solo si no hay señal se le da la copia
     guardada, para que al menos vea algo.

   · Los iconos y las imágenes fijas sí van de caché primero: no
     cambian y ahorran datos.

   · FASE 81: las PORTADAS del almacén de Supabase también van de caché
     primero. Antes se dejaban pasar por la regla de "ningún otro
     dominio", y el resultado fue que cada cliente se rebajaba el
     catálogo entero una y otra vez: 63 MB de fotos generando 8 GB de
     tráfico al mes contra un plan gratuito de 5 GB. Guardarlas aquí es
     seguro porque sus direcciones llevan ?v=<fecha>: si el dueño cambia
     una portada, cambia la dirección y esta caché ni se entera de la
     vieja.

   · Los datos de Supabase (pedidos, chat, precios) siguen sin tocarse:
     solo se intercepta /storage/v1/object/public/, que son archivos.

   Para forzar que todos los clientes reciban una versión nueva del
   propio service worker, sube el número de VERSION.
   ═══════════════════════════════════════════════════════════════════ */

const VERSION = 'vg-v3';   /* fase 81: sube al cambiar este archivo */
const CACHE_PAGINA  = VERSION + '-pagina';
const CACHE_ESTATIC = VERSION + '-estaticos';
const CACHE_FOTOS   = VERSION + '-portadas';

/* Tope de portadas guardadas. Un catálogo grande más los retro no pasa
   de unos cientos; el límite existe para que la caché no crezca sin
   freno en un teléfono que lleve meses con la tienda abierta. */
const MAX_FOTOS = 300;

/* Lo mínimo para que la app abra sin señal */
const BASICOS = [
  '/',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png',
  '/logo.png'
];

self.addEventListener('install', (ev) => {
  ev.waitUntil(
    caches.open(CACHE_ESTATIC)
      .then((c) => c.addAll(BASICOS).catch(() => {}))
      /* No esperar a que se cierren las pestañas viejas */
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (ev) => {
  ev.waitUntil(
    caches.keys()
      .then((claves) => Promise.all(
        claves.filter((k) => !k.startsWith(VERSION))
              .map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

function esEstatico(url) {
  return /\.(png|jpg|jpeg|webp|gif|svg|ico|woff2?)$/i.test(url.pathname);
}

/* Portadas de juegos del almacén de Supabase. Viven en dos cubos por
   razones históricas: 'catalogo' (la migración de imgur) y 'productos'
   (el botón de subir foto del formulario).

   Se nombran uno por uno en vez de aceptar todo /public/ porque en ese
   mismo almacén están los COMPROBANTES DE PAGO. Guardarlos aquí llenaría
   el teléfono del administrador de capturas de pago de sus clientes,
   durante meses y sin que nadie lo pidiera. Además no haría falta: cada
   comprobante se mira una vez. */
function esFotoDelAlmacen(url) {
  return /\.supabase\.co$/i.test(url.hostname) &&
         /^\/storage\/v1\/object\/public\/(catalogo|productos)\//.test(url.pathname);
}

async function fotoDeCache(req) {
  const cache = await caches.open(CACHE_FOTOS);

  const guardada = await cache.match(req);
  if (guardada) return guardada;

  try {
    /* Se pide en modo cors A PROPÓSITO. La etiqueta <img> pide en
       no-cors y devuelve una respuesta opaca, de la que no se puede
       saber si trae la foto o un 404 — y guardar un 404 con caché de un
       año dejaría ese hueco en blanco para siempre. El bucket manda
       Access-Control-Allow-Origin: *, así que cors funciona y sí se
       puede mirar el estado antes de guardar. */
    const resp = await fetch(req.url, { mode: 'cors', credentials: 'omit' });
    if (resp && resp.ok) {
      const copia = resp.clone();
      cache.put(req, copia)
        .then(() => podarFotos(cache))
        .catch(() => {});
    }
    return resp;
  } catch (e) {
    /* Sin señal y sin copia: se deja fallar para que el onerror de la
       tarjeta ponga portada.png, igual que hacía antes. */
    return Response.error();
  }
}

/* Las claves salen en orden de llegada, así que las primeras son las
   más viejas. */
async function podarFotos(cache) {
  const claves = await cache.keys();
  if (claves.length <= MAX_FOTOS) return;
  const sobran = claves.slice(0, claves.length - MAX_FOTOS);
  await Promise.all(sobran.map((k) => cache.delete(k)));
}

self.addEventListener('fetch', (ev) => {
  const req = ev.request;

  /* Solo GET. Todo POST pasa de largo sin que el service worker opine. */
  if (req.method !== 'GET') return;
  let url;
  try { url = new URL(req.url); } catch (e) { return; }

  /* ── Portadas del almacén: caché primero ── */
  if (esFotoDelAlmacen(url)) {
    ev.respondWith(fotoDeCache(req));
    return;
  }

  /* El resto de dominios ajenos (imgur, bing, la API de Supabase) no se
     toca: los pedidos, el chat y los precios tienen que ir en vivo. */
  if (url.origin !== self.location.origin) return;

  /* ── La página: red primero ── */
  if (req.mode === 'navigate' || req.destination === 'document') {
    ev.respondWith(
      fetch(req)
        .then((resp) => {
          const copia = resp.clone();
          /* Se guarda bajo la dirección COMPLETA y también bajo '/'.
             La app distingue vistas por parámetros (?producto=54,
             ?ir=compras), y antes sin señal siempre salía la portada
             aunque el cliente hubiera abierto un producto: la copia se
             guardaba solo en '/'. La de '/' se mantiene porque es la
             que responde cuando se abre una dirección nunca visitada. */
          caches.open(CACHE_PAGINA).then((c) => {
            c.put(req, copia.clone()).catch(() => {});
            c.put('/', copia).catch(() => {});
          }).catch(() => {});
          return resp;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match('/')))
    );
    return;
  }

  /* ── Imágenes y fuentes propias: caché primero ── */
  if (esEstatico(url)) {
    ev.respondWith(
      caches.match(req).then((guardada) => {
        if (guardada) return guardada;
        return fetch(req).then((resp) => {
          if (resp && resp.status === 200) {
            const copia = resp.clone();
            caches.open(CACHE_ESTATIC).then((c) => c.put(req, copia)).catch(() => {});
          }
          return resp;
        });
      })
    );
    return;
  }

  /* El resto, directo a la red */
});

/* Permite que la página pida activar de inmediato una versión nueva */
self.addEventListener('message', (ev) => {
  if (ev.data === 'vg-actualizar') self.skipWaiting();
});
