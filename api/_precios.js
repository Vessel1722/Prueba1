/* Vessel Games · las reglas de precio y las tuberías hacia Kinguin y Supabase.
 *
 * Este archivo no es una ruta: Vercel ignora los que empiezan con guion bajo.
 *
 * OJO: las reglas de abajo son las mismas que las de nucleo.mjs, en la carpeta
 * vessel-precios de tu PC. Si cambias una, cámbiala en las dos, o la tienda y
 * el script te van a dar precios distintos.
 */

// ═══════════════ LAS REGLAS ═══════════════
const CFG = {
  cuota: 0.16,                  // cuota de servicio de Kinguin (medida: 15.5%)
  gananciaMinima: 100,
  escalones: [[200, 100], [400, 140], [700, 190], [1200, 260], [Infinity, 340]],
  extraDemanda: [[8, 80], [4, 40]],
  extraAAA: [[1500, 60], [900, 30]],
  pisoPorcentual: 0.15,
  topeVenta: 5000,
  debajoDeStore: 0.90,
  margenAjustado: 0.12,
  tipoCambioRespaldo: 20.310158,
};
// ══════════════════════════════════════════

const LIB = 'https://www.kinguin.net/services/library/api/v1/products/search?';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';

function ganancia(costo, ofertas, listaMXN) {
  let base = CFG.escalones[CFG.escalones.length - 1][1];
  for (const [tope, v] of CFG.escalones) if (costo <= tope) { base = v; break; }
  for (const [min, extra] of CFG.extraDemanda) if ((ofertas || 0) >= min) { base += extra; break; }
  for (const [min, extra] of CFG.extraAAA) if ((listaMXN || 0) >= min) { base += extra; break; }
  return Math.max(base, costo * CFG.pisoPorcentual, CFG.gananciaMinima);
}

const redondear = (n) => Math.ceil(n / 5) * 5;

/* Devuelve el precio de venta, o null si este juego no se debe publicar. */
function precioDeVenta(costo, ofertas, listaMXN) {
  let venta = redondear(costo + ganancia(costo, ofertas, listaMXN));
  if (venta > CFG.topeVenta) return { venta: null, motivo: 'pasa del tope de $' + CFG.topeVenta };

  if (listaMXN > 0 && venta >= listaMXN) {
    const rebajado = redondear(listaMXN * CFG.debajoDeStore);
    const minimo = Math.max(CFG.gananciaMinima, costo * CFG.margenAjustado);
    if (rebajado - costo >= minimo) return { venta: rebajado, ajustado: true };
    return { venta: null, motivo: 'no queda debajo del precio de la Microsoft Store' };
  }
  return { venta, ajustado: false };
}

const slugDe = (titulo, edicion) =>
  (titulo + '-' + edicion).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 90);

const REG = 'AR|TR|BR|US|EU|UK|GB|IN|MX|CA|AU|DE|NG|EG|SA|ZA|SG|KR|TW|CL|CO|CH|LATAM|NA|ROW|GLOBAL|EMEA|APAC';

function tituloLimpio(nombre) {
  let t = String(nombre);
  t = t.replace(/\s*[-–]?\s*(XBOX|Xbox)\s*(One|Series)[^]*$/i, ' ');
  t = t.replace(/\b(CD Key|Digital Download|Key|Account|PRE-?ORDER|Pre-?purchase)\b/gi, ' ');
  t = t.replace(new RegExp('\\s+\\b(' + REG + ')\\b\\s*', 'g'), ' ');
  t = t.replace(/\s*\(.*?(key|region|vpn).*?\)\s*/gi, ' ');
  t = t.replace(/^Copy of\s+/i, '');
  return t.replace(/[\s/|-]+$/, '').replace(/\s{2,}/g, ' ').trim();
}

function regionDe(p) {
  const c = (p.attributes.region && p.attributes.region.activationCountries) || [];
  if (c.length > 100) return 'Global';
  if (c.indexOf('MX') >= 0) return 'Latam';
  const uno = { AR: 'Argentina', TR: 'Turquía', BR: 'Brasil', US: 'Estados Unidos', GB: 'Reino Unido', IN: 'India', CA: 'Canadá', AU: 'Australia', DE: 'Alemania', EG: 'Egipto', NG: 'Nigeria', ZA: 'Sudáfrica', SG: 'Singapur', KR: 'Corea', TW: 'Taiwán', CL: 'Chile', CO: 'Colombia', CH: 'Suiza', SA: 'Arabia Saudita' };
  if (c.length === 1) return uno[c[0]] || c[0];
  if (c.length <= 60) return 'Europa';
  return 'Otra región';
}

/* La dirección de la ficha en Kinguin lleva el número del producto delante
   del nombre: /category/122709/cuphead-...  Sin el número contesta con un
   redirección a su página de 404, que es lo que salía al darle a "Comprar".
   La ficha abre ya con la oferta más barata de ese producto seleccionada,
   que es justo la que se usó para calcular el precio. */
function urlDeKinguin(p) {
  const a = p.attributes || {};
  const id = p.externalId;
  const nombre = a.urlKey || '';
  if (id && nombre) return 'https://www.kinguin.net/category/' + id + '/' + nombre;
  if (id) return 'https://www.kinguin.net/category/' + id;
  return 'https://www.kinguin.net/listing?phrase=' + encodeURIComponent(p.name || '') + '&platforms=10,20&hideUnavailable=1&active=1';
}

async function json(url) {
  const r = await fetch(url, { headers: { 'user-agent': UA, accept: 'application/json' } });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function enTanda(items, n, fn) {
  const salida = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (i < items.length) {
      const k = i++;
      try { salida[k] = await fn(items[k], k); } catch (e) { salida[k] = null; }
    }
  }));
  return salida;
}

/* El tipo de cambio que Kinguin le aplica a México, leído de su propia página.
   Si no se puede, se usa el de respaldo: más vale cotizar de más que de menos. */
async function tipoDeCambio() {
  try {
    const r = await fetch('https://www.kinguin.net/listing?platforms=20&size=1', {
      headers: { 'user-agent': UA, 'accept-language': 'es-MX,es;q=0.9' },
    });
    const h = await r.text();
    const i = h.indexOf('window._preloadedState');
    if (i < 0) return CFG.tipoCambioRespaldo;
    const s = h.indexOf('=', i) + 1, e = h.indexOf('</script>', s);
    const j = JSON.parse(h.slice(s, e).trim().replace(/;\s*$/, ''));
    const c = j && j.currencies && j.currencies.current;
    return (c && c.code === 'MXN' && c.rate) ? c.rate : CFG.tipoCambioRespaldo;
  } catch (e) { return CFG.tipoCambioRespaldo; }
}

/* Convierte productos crudos de Kinguin en {slug: {costoBase, ofertas, …}},
   quedándose siempre con la oferta más barata de cada juego. */
function agrupar(crudos, tipoCambio) {
  const mapa = new Map();
  for (const p of crudos) {
    const a = p.attributes || {};
    if (a.marketingProductType !== 'GAME') continue;
    if (!p.active || !p.visible || p.isDeleted) continue;
    const centavos = (p.price && p.price.calculated) || 0;
    if (centavos < 100) continue;
    if (/beta|early access|\bdemo\b/i.test(p.name)) continue;

    const titulo = tituloLimpio(p.name);
    if (titulo.length < 3) continue;
    const edicion = a.edition || 'Standard';
    const slug = slugDe(titulo, edicion);
    const costoBase = (centavos / 100) * tipoCambio;

    const previo = mapa.get(slug);
    if (!previo) {
      mapa.set(slug, {
        slug, titulo, edicion, costoBase, ofertas: 1,
        region: regionDe(p),
        url: urlDeKinguin(p),
        plataforma: ((a.platforms || []).indexOf('20') >= 0 && (a.platforms || []).indexOf('10') >= 0)
          ? 'Xbox One / Series' : (a.platform === 20 ? 'Xbox Series' : 'Xbox One'),
        portada: p.coverImageUrl || p.hiImageUrl || p.imageUrl || '',
      });
    } else {
      previo.ofertas++;
      if (costoBase < previo.costoBase) {
        previo.costoBase = costoBase;
        previo.region = regionDe(p);
        previo.url = urlDeKinguin(p);
      }
    }
  }
  return mapa;
}

/* Baja el catálogo Xbox entero de Kinguin. paginas=50 son 5,000 por plataforma,
   que es todo lo que la API deja ver. */
async function bajarCatalogo(paginas, concurrencia) {
  const crudos = [];
  for (const plat of [10, 20]) {
    const pags = Array.from({ length: paginas }, (_, p) => p);
    const lotes = await enTanda(pags, concurrencia, async (page) => {
      const j = await json(LIB + 'platforms=' + plat + '&size=100&page=' + page);
      return (j._embedded && j._embedded.products) || [];
    });
    for (const l of lotes) if (l) crudos.push(...l);
  }
  return crudos;
}

/* Busca un juego suelto por nombre. Para el botón de "precio de ahora". */
async function buscarUno(frase) {
  const j = await json(LIB + 'phrase=' + encodeURIComponent(frase) + '&platforms=10,20&size=100');
  return (j._embedded && j._embedded.products) || [];
}

/* ───────── Supabase por REST, sin librerías ───────── */
function supa(ruta, opciones) {
  const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '') + '/rest/v1/' + ruta;
  const key = process.env.SUPABASE_SERVICE_KEY || '';
  const cab = Object.assign({
    apikey: key,
    Authorization: 'Bearer ' + key,
    'Content-Type': 'application/json',
  }, (opciones && opciones.headers) || {});
  return fetch(url, Object.assign({}, opciones, { headers: cab })).then(async (r) => {
    const t = await r.text();
    if (!r.ok) throw new Error('Supabase ' + r.status + ': ' + t.slice(0, 160));
    return t ? JSON.parse(t) : null;
  });
}

/* ¿Quien llama es el administrador? Se le pregunta a la propia base con el
   token de sesión de quien hace la llamada: si is_admin() dice que sí, es que
   sí. Aquí no se guarda ninguna contraseña ni se confía en el navegador. */
async function esAdmin(req) {
  const auth = req.headers.authorization || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return false;
  const anon = process.env.SUPABASE_ANON_KEY || '';
  const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '') + '/rest/v1/rpc/is_admin';
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { apikey: anon, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (!r.ok) return false;
    return (await r.json()) === true;
  } catch (e) { return false; }
}

module.exports = {
  CFG, ganancia, redondear, precioDeVenta, slugDe,
  tipoDeCambio, agrupar, bajarCatalogo, buscarUno, enTanda,
  supa, esAdmin,
};
