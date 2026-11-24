/* GET /api/catalogo-retro-tr
 *
 * El catálogo de la sección Cuenta Nueva: juegos más baratos en Turquía
 * que en México, con la venta al 70% del precio de México. Solo pesos a la
 * vista; el campo `tr` viaja solo para aplicar la regla del paquete de
 * 300 TRY y la tienda no lo pinta en ningún sitio.
 *
 * Fuente 1: la tabla public.vg_xbox_tr (la mantiene el cron diario).
 * Fuente 2: si la tabla no existe o está vacía, el respaldo
 * api/tr-catalogo.json que se subió con el primer barrido. Así la sección
 * no queda vacía mientras Miguel corre el SQL en Supabase.
 */

const T = require('./_precios-tr');

const CAMPOS = 'slug,title,platform,ms_id,image,mx,tr,venta_mxn,paquete';

module.exports = async (req, res) => {
  const fresco = String(req.query.fresco || '') === '1';

  const raiz = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  const clave = String(process.env.SUPABASE_ANON_KEY || '').trim().replace(/^["']|["']$/g, '');

  let juegos = [];
  let fuente = 'respaldo';
  let tc = T.CFG_TR.TC_RESPALDO;

  try {
    const r = await T.tipoCambioTRY();
    tc = r.tc;
  } catch (e) { /* el respaldo ya está puesto */ }

  if (raiz && clave) {
    try {
      const todos = [];
      for (let desde = 0; desde < 20000; desde += 1000) {
        const url = `${raiz}/rest/v1/vg_xbox_tr?select=${CAMPOS}&status=eq.active&order=platform.asc&order=title.asc&offset=${desde}&limit=1000`;
        const r = await fetch(url, { headers: { apikey: clave, Authorization: 'Bearer ' + clave } });
        if (!r.ok) throw new Error('Supabase ' + r.status);
        const lote = await r.json();
        todos.push.apply(todos, lote);
        if (lote.length < 1000) break;
      }
      if (todos.length) { juegos = todos; fuente = 'supabase'; }
    } catch (e) { /* cae al respaldo */ }
  }

  if (!juegos.length) {
    try {
      const respaldo = require('./tr-catalogo.json');
      juegos = respaldo
        .filter((j) => j && j.venta_mxn > 0)
        .map((j) => ({
          slug: j.slug, title: j.title, platform: j.platform,
          ms_id: j.ms_id || null, image: j.image || null,
          mx: Number(j.mx), tr: Number(j.tr),
          venta_mxn: Number(j.venta_mxn), paquete: !!j.paquete,
        }));
    } catch (e) {
      res.setHeader('Cache-Control', 'no-store');
      return res.status(502).json({ error: 'No hay catálogo Cuenta Nueva disponible.' });
    }
  }

  if (fresco) {
    res.setHeader('Cache-Control', 'no-store');
  } else {
    res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=600, stale-while-revalidate=3600');
  }
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(200).json({
    juegos,
    total: juegos.length,
    tipo_cambio: tc,
    minimo_try: T.CFG_TR.MINIMO_TRY,
    minimo_mxn: Math.ceil(T.CFG_TR.MINIMO_TRY * tc),
    fuente,
  });
};
