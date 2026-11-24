/* POST /api/validar-tr
 *
 * Revalidación al momento de pagar: vuelve a leer el precio de México y
 * de Turquía de cada juego del pedido, con el tipo de cambio vivo, y
 * recalcula la venta con la regla del 70% y la ganancia mínima de $15.
 *
 * La tienda lo llama antes de abrir el pago de un pedido Cuenta Nueva. Si
 * algo cambió (un juego ya no deja $15, se acabó la oferta en Turquía, o
 * el pedido ya no suma 300 TRY), responde ok:false y la tienda no deja
 * pagar con los precios viejos.
 *
 * Si Microsoft no responde para un juego, ese juego se marca no válido:
 * no se vende a precio desactualizado. Falla cerrada, como el cron.
 */

const P = require('./_precios');
const T = require('./_precios-tr');

function leerRespaldo() {
  try {
    const datos = require('./tr-catalogo.json');
    const mapa = {};
    for (const j of datos) mapa[j.slug] = j;
    return mapa;
  } catch (e) {
    return {};
  }
}

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  let cuerpo = req.body;
  if (typeof cuerpo === 'string') {
    try { cuerpo = JSON.parse(cuerpo); } catch (e) { cuerpo = {}; }
  }
  let slugs = (cuerpo && cuerpo.slugs) || [];
  if (!slugs.length && req.query.slugs) slugs = String(req.query.slugs).split(',').map((s) => s.trim()).filter(Boolean);
  slugs = [...new Set(slugs.map(String))].slice(0, 50);
  if (!slugs.length) {
    return res.status(400).json({ ok: false, error: 'Faltan los juegos del pedido (slugs).' });
  }

  try {
    const { tc } = await T.tipoCambioTRY();

    /* Filas actuales: tabla si existe, respaldo si no. */
    let filas = [];
    try {
      const todas = await T.leerTablaTR();
      filas = todas.filter((f) => slugs.includes(f.slug));
    } catch (e) { /* cae al respaldo */ }
    const respaldo = leerRespaldo();
    if (!filas.length) {
      filas = slugs.map((s) => respaldo[s]).filter(Boolean);
    } else {
      for (const s of slugs) {
        if (!filas.find((f) => f.slug === s) && respaldo[s]) filas.push(respaldo[s]);
      }
    }
    if (!filas.length) {
      return res.status(404).json({ ok: false, error: 'Ningún juego del pedido está en el catálogo Cuenta Nueva.' });
    }

    /* Precios vivos por ms_id; sin ficha, por nombre. */
    const conId = filas.filter((f) => f.ms_id);
    const sinId = filas.filter((f) => !f.ms_id);
    const [mxMapa, trMapa] = await Promise.all([
      P.preciosDeMicrosoft(conId.map((f) => f.ms_id)).catch(() => ({})),
      T.preciosDeMicrosoftTR(conId.map((f) => f.ms_id)).catch(() => ({})),
    ]);
    const porTitulo = {};
    await P.enTanda(sinId, 4, async (f) => {
      const m = await T.buscarEnMicrosoftTR(f.title).catch(() => null);
      if (m) porTitulo[f.slug] = m;
    });

    const juegos = [];
    let tryTotal = 0;
    let totalMxn = 0;
    let todoOk = true;
    for (const f of filas) {
      let mx = null;
      let tr = null;
      if (f.ms_id) {
        const a = mxMapa[f.ms_id];
        const b = trMapa[f.ms_id];
        mx = a && (a.precio || a.ListPrice || Number(a) || null);
        tr = b && (b.precio || b.ListPrice || Number(b) || null);
      } else if (porTitulo[f.slug]) {
        mx = porTitulo[f.slug].mx;
        tr = porTitulo[f.slug].tr;
      }
      if (!(mx > 0) || !(tr > 0)) {
        juegos.push({ slug: f.slug, ok: false, motivo: 'sin precio actual en Microsoft' });
        todoOk = false;
        continue;
      }
      const v = T.precioVentaTR(mx, tr, tc);
      if (!v.publica) {
        juegos.push({ slug: f.slug, ok: false, motivo: v.motivo || 'ya no deja ganancia', mx, tr });
        todoOk = false;
        continue;
      }
      tryTotal += Number(tr);
      totalMxn += v.venta;
      juegos.push({ slug: f.slug, ok: true, venta_mxn: v.venta, mx, tr });
    }

    const tryOk = tryTotal >= T.CFG_TR.MINIMO_TRY;
    res.status(200).json({
      ok: todoOk && tryOk,
      tipo_cambio: tc,
      try_total: Math.round(tryTotal * 100) / 100,
      try_ok: tryOk,
      minimo_try: T.CFG_TR.MINIMO_TRY,
      total_mxn: totalMxn,
      juegos,
    });
  } catch (e) {
    return res.status(502).json({ ok: false, error: 'No se pudo revalidar: ' + String(e.message).slice(0, 160) });
  }
};
