/* Precios de la sección Cuenta Nueva (Xbox Retro + One/Series desde Turquía).
 *
 * Las reglas viven aquí, en crear-tabla-tr.sql y en el módulo de la tienda
 * vg-retro-tr-v1: si una cambia, cambia en los tres sitios.
 *
 *   · Venta = 70% del precio de la Microsoft Store de México, redondeado
 *     hacia abajo a pesos enteros.
 *   · Solo se publica si deja al menos $15 MXN de ganancia sobre el costo
 *     (precio de Turquía convertido a pesos).
 *   · El cliente solo ve pesos mexicanos. Nunca se le muestra la lira ni el
 *     costo. El campo `tr` viaja en la API solo para aplicar la regla del
 *     paquete, y la tienda no lo pinta en ningún sitio.
 *   · Regla del paquete: los juegos de menos de 300 TRY no se venden solos;
 *     el pedido tiene que sumar 300 TRY o más entre juegos. Los de 300 TRY
 *     o más sí se venden individuales.
 *   · Nunca se vende por encima del precio de México: la venta es el 70%,
 *     así que siempre queda por debajo.
 *
 * No se toca api/_precios.js (Kinguin): son reglas distintas y ese archivo
 * se comparte con vessel-precios/nucleo.mjs en la PC de Miguel.
 */

const P = require('./_precios');
const MS_CATALOGO = 'https://displaycatalog.mp.microsoft.com/v7.0/';
const MS_CV = 'MS-CV=DGU1mcuYo0WMMp%2BF.1';

const CFG_TR = {
  MINIMO_TRY: 300,
  GANANCIA_MINIMA: 15,
  PCT_VENTA: 0.7,
  TC_RESPALDO: 0.38, // MXN por TRY, solo si la tasa viva no responde
};

async function json(url, opciones) {
  const r = await fetch(url, opciones);
  const t = await r.text();
  if (!r.ok) throw new Error('HTTP ' + r.status + ': ' + t.slice(0, 160));
  return t ? JSON.parse(t) : null;
}

/* Tipo de cambio vivo TRY -> MXN. Frankfurter es gratis y no pide llave. */
async function tipoCambioTRY() {
  try {
    const d = await json('https://api.frankfurter.dev/v1/latest?base=TRY&symbols=MXN');
    const tc = Number(d && d.rates && d.rates.MXN);
    if (tc > 0) return { tc, fuente: 'frankfurter' };
  } catch (e) { /* cae al respaldo */ }
  try {
    const d = await json('https://open.er-api.com/v6/latest/TRY');
    const tc = Number(d && d.rates && d.rates.MXN);
    if (tc > 0) return { tc, fuente: 'er-api' };
  } catch (e) { /* cae al respaldo */ }
  return { tc: CFG_TR.TC_RESPALDO, fuente: 'respaldo' };
}

/* La regla de venta. mx y tr son los precios de lista de Microsoft. */
function precioVentaTR(mx, tr, tc) {
  mx = Number(mx || 0);
  tr = Number(tr || 0);
  tc = Number(tc || CFG_TR.TC_RESPALDO);
  if (!(mx > 0) || !(tr > 0) || !(tc > 0)) {
    return { publica: false, motivo: 'sin precio en una de las tiendas' };
  }
  const costo = tr * tc;
  const venta = Math.floor(mx * CFG_TR.PCT_VENTA);
  const ganancia = venta - costo;
  if (ganancia < CFG_TR.GANANCIA_MINIMA) {
    return { publica: false, motivo: 'no deja $15 de ganancia', venta, costo, ganancia };
  }
  return { publica: true, venta, costo, ganancia };
}

/* Precios de Microsoft en Turquía, por ms_id. Espejo de preciosDeMicrosoft
   (que es solo MX). Devuelve mapa id -> { precio, moneda } y __fallidos. */
async function preciosDeMicrosoftTR(ids) {
  const limpios = [...new Set((ids || []).filter(Boolean))];
  const mapa = { __fallidos: [] };
  if (!limpios.length) return mapa;
  const bloques = [];
  for (let i = 0; i < limpios.length; i += 20) bloques.push(limpios.slice(i, i + 20));
  const leer = (p) => {
    /* Igual que preciosDeMicrosoft: el precio efectivo más bajo entre las
       ediciones, en liras. La edición cara no puede inflar el costo. */
    let ahora = 0;
    for (const sku of (p.DisplaySkuAvailabilities || [])) {
      for (const av of (sku.Availabilities || [])) {
        const pr = ((av.OrderManagementData || {}).Price) || {};
        if (!pr || pr.CurrencyCode !== 'TRY') continue;
        const efectivo = pr.ListPrice || pr.MSRP || 0;
        if (efectivo > 0 && (ahora === 0 || efectivo < ahora)) ahora = efectivo;
      }
    }
    return ahora > 0 ? Math.round(ahora * 100) / 100 : 0;
  };
  await P.enTanda(bloques, 8, async (bloque) => {
    for (let intento = 1; intento <= 3; intento++) {
      try {
        const r = await json(`${MS_CATALOGO}products?bigIds=${bloque.join(',')}&market=TR&languages=tr-TR&${MS_CV}`);
        for (const p of (r.Products || [])) {
          const v = leer(p);
          if (v) mapa[p.ProductId] = v;
        }
        return;
      } catch (e) {
        if (intento === 3) for (const id of bloque) mapa.__fallidos.push(id);
        await new Promise((s) => setTimeout(s, 300 * intento));
      }
    }
  });
  return mapa;
}

/* Coincidencia por nombre, con la misma disciplina que buscarEnMicrosoft:
   exacto primero, si no el mejor por palabras, con un mínimo de 0.45, y
   sin aceptar pases de temporada, DLC ni avatares cuando se busca un juego. */
const norm = (s) => String(s || '').toLowerCase()
  .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-z0-9]+/g, ' ').trim();
const NO_ES_JUEGO = /(season pass|pase de temporada|\bdlc\b|avatar|gamerpic|theme|tema\b|soundtrack|artbook)/i;

function puntaje(query, titulo) {
  const q = norm(query).split(' ').filter(Boolean);
  const t = new Set(norm(titulo).split(' ').filter(Boolean));
  if (!q.length) return 0;
  let ok = 0;
  for (const w of q) if (t.has(w)) ok++;
  return ok / q.length;
}

async function buscarEnMicrosoftTR(titulo) {
  const r = await json(MS_CATALOGO + 'productFamilies/autosuggest?market=MX&languages=es-MX&productFamilyNames=Games&query=' + encodeURIComponent(String(titulo).slice(0, 60)));
  const prods = [];
  for (const fam of (r.Results || [])) for (const p of (fam.Products || [])) prods.push(p);
  if (!prods.length) return null;
  const nq = norm(titulo);
  let mejor = null;
  let mejorPuntaje = 0;
  for (const p of prods) {
    const nt = norm(p.Title || '');
    if (nt === nq) { mejor = p; mejorPuntaje = 1; break; }
    if (NO_ES_JUEGO.test(p.Title || '') && !NO_ES_JUEGO.test(titulo)) continue;
    const s = puntaje(titulo, p.Title || '');
    if (s > mejorPuntaje) { mejorPuntaje = s; mejor = p; }
  }
  if (!mejor || mejorPuntaje < 0.45) return null;
  const id = mejor.ProductId;
  const [mx, tr] = await Promise.all([
    P.preciosDeMicrosoft([id]).catch(() => ({})),
    preciosDeMicrosoftTR([id]).catch(() => ({})),
  ]);
  const pmx = mx[id] && (mx[id].precio || mx[id].ListPrice || mx[id]);
  const ptr = tr[id] && (tr[id].precio || tr[id].ListPrice || tr[id]);
  const precioMX = pmx && typeof pmx === 'object' ? pmx.precio : Number(pmx || 0);
  const precioTR = ptr && typeof ptr === 'object' ? ptr.precio : Number(ptr || 0);
  if (!(precioMX > 0) || !(precioTR > 0)) return null;
  return {
    id, titulo: mejor.Title || titulo,
    mx: precioMX, tr: precioTR,
    icon: mejor.Icon ? ('https:' + mejor.Icon.replace(/^https?:/, '')) : '',
    calidad: mejorPuntaje >= 0.75 ? 'exacto' : 'aproximado',
  };
}

/* Lee toda la tabla vg_xbox_tr con la llave de servicio. */
async function leerTablaTR() {
  const filas = [];
  let desde = 0;
  while (true) {
    const lote = await P.supa('vg_xbox_tr?select=slug,title,platform,ms_id,image,mx,tr,costo_mxn,venta_mxn,ganancia,paquete,status,origen&order=slug.asc&limit=1000&offset=' + desde);
    filas.push.apply(filas, lote);
    if (lote.length < 1000) break;
    desde += 1000;
  }
  return filas;
}

module.exports = {
  CFG_TR, tipoCambioTRY, precioVentaTR,
  preciosDeMicrosoftTR, buscarEnMicrosoftTR, leerTablaTR,
};
