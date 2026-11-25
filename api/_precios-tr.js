/* Precios de la sección Cuenta Nueva (Xbox Cuentas: Retro + One/Series
 * desde Turquía). Regla v3 (2026-11-24, Miguel).
 *
 * Las reglas viven aquí y en recalcular-v3.py (el barrido que genera el
 * catálogo): si una cambia, cambia en los dos sitios.
 *
 *   · costo = precio TR en liras × tipo de cambio vivo.
 *   · ganancia = 120% del costo, entre $15 y $400 MXN.
 *   · venta = costo + ganancia, redondeada a $5 hacia arriba.
 *   · juegos baratos (precio MX < $60): venta = ~80% del precio MX.
 *     Ej: Gears of War 3 (MX $57.25, costo $6.17) se vende en $45.
 *   · Topes: nunca arriba del 90% del precio de México, y nunca arriba
 *     del precio del mismo juego en la sección Xbox One/Series (código):
 *     si la venta calculada lo alcanza, baja a ese precio menos $5.
 *   · Solo se publica si deja al menos $15 MXN de ganancia.
 *   · El cliente solo ve pesos mexicanos. Nunca se le muestra la lira ni
 *     el costo. El campo `tr` viaja en la API solo para aplicar la regla
 *     del paquete, y la tienda no lo pinta en ningún sitio.
 *   · Regla del paquete (INTERNA, no se muestra al cliente): los juegos
 *     de menos de 300 TRY no se venden solos; el pedido tiene que sumar
 *     300 TRY o más entre juegos. Los de 300 TRY o más sí se venden
 *     individuales.
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
  GANANCIA_MAXIMA: 400,
  PCT_COSTO: 1.2,    // ganancia = 120% del costo
  MX_BARATO: 60,     // juegos con precio MX menor de $60
  PCT_BARATO: 0.8,   // ... se venden a ~80% del precio MX
  TOPE_MX: 0.9,      // nunca arriba del 90% del precio MX
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

/* La regla de venta v3. mx y tr son los precios de lista de Microsoft;
   precioKinguin es el precio del mismo juego en la sección Xbox
   One/Series (código), o 0 si no está ahí. */
function precioVentaTR(mx, tr, tc, precioKinguin) {
  mx = Number(mx || 0);
  tr = Number(tr || 0);
  tc = Number(tc || CFG_TR.TC_RESPALDO);
  if (!(mx > 0) || !(tr > 0) || !(tc > 0)) {
    return { publica: false, motivo: 'sin precio en una de las tiendas' };
  }
  const costo = tr * tc;
  const ganancia = Math.min(
    Math.max(CFG_TR.PCT_COSTO * costo, CFG_TR.GANANCIA_MINIMA),
    CFG_TR.GANANCIA_MAXIMA);
  let venta = Math.ceil((costo + ganancia) / 5) * 5;
  if (mx < CFG_TR.MX_BARATO) {
    venta = Math.floor((CFG_TR.PCT_BARATO * mx) / 5 + 0.5) * 5;
  }
  const topeMX = Math.floor((CFG_TR.TOPE_MX * mx) / 5) * 5;
  if (venta > topeMX) venta = topeMX;
  const pk = Number(precioKinguin || 0);
  if (pk > 0 && venta >= pk) venta = Math.floor((pk - 5) / 5) * 5;
  const ganFinal = venta - costo;
  if (ganFinal < CFG_TR.GANANCIA_MINIMA || venta <= costo) {
    return { publica: false, motivo: 'no deja $15 de ganancia', venta, costo, ganancia: ganFinal };
  }
  return { publica: true, venta, costo, ganancia: ganFinal };
}

/* Precio de la sección One/Series (Kinguin) por ms_id. La sección Cuenta
   Nueva nunca puede vender más caro que esa sección. Lectura anon (la
   tabla es pública para lectura), por ms_id en lotes. Si no se puede leer,
   devuelve vacío y el tope no se aplica en esa corrida (el catálogo
   estático ya lo trae aplicado). */
async function mapaKinguin(ids) {
  const limpios = [...new Set((ids || []).filter(Boolean))].map(String);
  const mapa = {};
  const url0 = process.env.SUPABASE_URL || '';
  const anon = process.env.SUPABASE_ANON_KEY || '';
  if (!url0 || !anon || !limpios.length) return mapa;
  for (let i = 0; i < limpios.length; i += 200) {
    const lote = limpios.slice(i, i + 200);
    try {
      const r = await fetch(url0.replace(/\/+$/, '') +
        '/rest/v1/vg_xbox_games?select=ms_id,price&ms_id=in.(' +
        lote.map(encodeURIComponent).join(',') + ')', {
        headers: { apikey: anon, Authorization: 'Bearer ' + anon },
      });
      if (!r.ok) continue;
      const filas = await r.json();
      for (const f of (filas || [])) {
        if (f.ms_id && f.price != null) mapa[String(f.ms_id)] = Number(f.price);
      }
    } catch (e) { /* sin tope Kinguin para este lote */ }
  }
  return mapa;
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
  CFG_TR, tipoCambioTRY, precioVentaTR, mapaKinguin,
  preciosDeMicrosoftTR, buscarEnMicrosoftTR, leerTablaTR,
};
