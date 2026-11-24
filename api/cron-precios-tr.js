/* GET /api/cron-precios-tr
 *
 * Repaso diario de la sección Cuenta Nueva: relee el precio de México y
 * de Turquía de cada juego de vg_xbox_tr, con el tipo de cambio vivo, y
 * recalcula la venta (70% del precio MX, ganancia mínima $15). El juego
 * que ya no deja ganancia se esconde; el que vuelve a dejarla, se publica.
 *
 * Dos reglas que vienen del susto de los 300 juegos escondidos en la
 * sección de Kinguin:
 *   1. Si Microsoft no responde para un juego, se queda como estaba. Un
 *      error nunca se confunde con un juego retirado.
 *   2. Si más de la mitad de las consultas fallan, la corrida se cae con
 *      502 SIN escribir nada.
 *
 * Solo el cron de Vercel o el administrador (?ensayo=1 no escribe nada).
 */

const P = require('./_precios');
const T = require('./_precios-tr');

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  const ensayo = String(req.query.ensayo || '') === '1';

  const secreto = process.env.CRON_SECRET || '';
  const auth = req.headers.authorization || '';
  const esCron = secreto && auth === 'Bearer ' + secreto;
  if (!esCron) {
    const quien = await P.esAdmin(req);
    if (!quien.ok) {
      return res.status(403).json({ error: 'Solo el administrador o el cron. ' + quien.motivo });
    }
  }
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_KEY) {
    return res.status(500).json({ error: 'Faltan las variables de entorno de Supabase en Vercel.' });
  }

  const t0 = Date.now();
  try {
    let filas;
    try {
      filas = await T.leerTablaTR();
    } catch (e) {
      return res.status(502).json({
        error: 'No se pudo leer vg_xbox_tr. Corre crear-tabla-tr.sql en Supabase. ' + String(e.message).slice(0, 120),
      });
    }
    if (!filas.length) {
      return res.status(502).json({ error: 'vg_xbox_tr está vacía. Corre crear-tabla-tr.sql en Supabase.' });
    }

    const { tc } = await T.tipoCambioTRY();

    const conId = filas.filter((f) => f.ms_id);
    const sinId = filas.filter((f) => !f.ms_id);
    const [mxMapa, trMapa] = await Promise.all([
      P.preciosDeMicrosoft(conId.map((f) => f.ms_id)).catch(() => ({ __fallidos: conId.map((f) => f.ms_id) })),
      T.preciosDeMicrosoftTR(conId.map((f) => f.ms_id)).catch(() => ({ __fallidos: conId.map((f) => f.ms_id) })),
    ]);
    const porTitulo = {};
    await P.enTanda(sinId, 4, async (f) => {
      const m = await T.buscarEnMicrosoftTR(f.title).catch(() => null);
      if (m) porTitulo[f.slug] = m;
    });

    /* Falla global: si más de la mitad no tiene precio vivo, 502 sin tocar nada. */
    let conPrecio = 0;
    for (const f of conId) {
      const a = mxMapa[f.ms_id];
      const b = trMapa[f.ms_id];
      if (a && (a.precio || a.ListPrice || Number(a)) && b && (b.precio || b.ListPrice || Number(b))) conPrecio++;
    }
    conPrecio += Object.keys(porTitulo).length;
    if (conPrecio < Math.ceil(filas.length / 2)) {
      return res.status(502).json({
        error: 'Microsoft no respondió para la mayoría de los juegos; no se escribió nada.',
        con_precio: conPrecio, total: filas.length,
      });
    }

    const cambios = [];
    let actualizados = 0;
    let ocultos = 0;
    let publicados = 0;
    let sinPrecio = 0;
    let errores = 0;
    for (const f of filas) {
      let mx = null;
      let tr = null;
      let msId = f.ms_id;
      if (f.ms_id) {
        const a = mxMapa[f.ms_id];
        const b = trMapa[f.ms_id];
        mx = a && (a.precio || a.ListPrice || Number(a) || null);
        tr = b && (b.precio || b.ListPrice || Number(b) || null);
      } else if (porTitulo[f.slug]) {
        mx = porTitulo[f.slug].mx;
        tr = porTitulo[f.slug].tr;
        msId = porTitulo[f.slug].id;
      }
      if (!(mx > 0) || !(tr > 0)) { sinPrecio++; continue; }
      const v = T.precioVentaTR(mx, tr, tc);
      const status = v.publica ? 'active' : 'hidden';
      if (!v.publica && f.status !== 'hidden') ocultos++;
      if (v.publica && f.status === 'hidden') publicados++;
      if (Number(f.mx) !== Number(mx) || Number(f.tr) !== Number(tr) ||
          Number(f.venta_mxn) !== Number(v.venta || 0) || f.status !== status) {
        actualizados++;
        cambios.push({
          slug: f.slug, title: f.title, platform: f.platform,
          ms_id: msId || null, image: f.image || null,
          mx: Number(mx), tr: Number(tr),
          costo_mxn: Math.round((Number(tr) * tc) * 100) / 100,
          venta_mxn: v.publica ? v.venta : Number(f.venta_mxn || 0),
          ganancia: Math.round(((v.venta || 0) - Number(tr) * tc) * 100) / 100,
          paquete: Number(tr) < T.CFG_TR.MINIMO_TRY,
          status, origen: f.origen || null,
          updated_at: new Date().toISOString(),
        });
      }
    }

    if (!ensayo && cambios.length) {
      for (let i = 0; i < cambios.length; i += 100) {
        const lote = cambios.slice(i, i + 100);
        const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '') + '/rest/v1/vg_xbox_tr?on_conflict=slug';
        const r = await fetch(url, {
          method: 'POST',
          headers: {
            apikey: process.env.SUPABASE_SERVICE_KEY,
            Authorization: 'Bearer ' + process.env.SUPABASE_SERVICE_KEY,
            'Content-Type': 'application/json',
            Prefer: 'resolution=merge-duplicates,return=minimal',
          },
          body: JSON.stringify(lote),
        });
        if (!r.ok) {
          errores++;
          const t = await r.text().catch(() => '');
          throw new Error('Supabase upsert ' + r.status + ': ' + t.slice(0, 120));
        }
      }
    }

    return res.status(200).json({
      ensayo,
      total: filas.length,
      actualizados,
      ocultos,
      publicados,
      sin_precio: sinPrecio,
      errores,
      tipo_cambio: tc,
      duracion_ms: Date.now() - t0,
    });
  } catch (e) {
    return res.status(502).json({ error: String(e.message).slice(0, 200) });
  }
};
