/* GET /api/cron-precios
 *
 * Repasa todo el catálogo contra los precios de Kinguin de hoy y deja la
 * tienda al día. Lo llama Vercel solo, a la hora que diga vercel.json, sin
 * depender de que tu computadora esté encendida.
 *
 * Qué hace con cada juego:
 *   · si en Kinguin cambió de precio, se le pone el nuevo precio de venta;
 *   · si dejó de convenir (desapareció, se pasó del precio de la Microsoft
 *     Store o del tope), se esconde —no se borra, que los pedidos viejos lo
 *     apuntan—;
 *   · si estaba escondido y ya vuelve a convenir, se enciende otra vez.
 *
 * No toca los juegos que cargaste a mano: esos no tienen slug.
 *
 * También se puede llamar a mano con ?ensayo=1 para ver qué haría.
 */
const P = require('./_precios');

const TOPE_ESCRITURAS = 300;   // por corrida, para no pasarse del tiempo
const CONCURRENCIA_PAGINAS = 10;
const CONCURRENCIA = 12;

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');

  const ensayo = String(req.query.ensayo || '') === '1';

  /* Vercel manda el CRON_SECRET en la cabecera. A mano, lo puede mandar el
     administrador con su sesión. Cualquier otro se queda fuera. */
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
    const [tipoCambio, crudos] = await Promise.all([
      P.tipoDeCambio(),
      P.bajarCatalogo(CONCURRENCIA_PAGINAS),
    ]);
    const kinguin = P.agrupar(crudos, tipoCambio);

    // El catálogo de la tienda, de mil en mil que es lo que Supabase deja.
    const filas = [];
    let desde = 0;
    while (true) {
      const lote = await P.supa('vg_xbox_games?select=slug,title,price,precio_lista,ms_id,status&slug=not.is.null&order=slug.asc&limit=1000&offset=' + desde);
      filas.push.apply(filas, lote);
      if (lote.length < 1000) break;
      desde += 1000;
    }

    /* El precio de la tienda de Xbox se relee cada vez. Guardarlo y no volver
       a mirarlo era el fallo que dejaba publicar un juego más caro que en la
       propia tienda: las rebajas de Microsoft duran días. */
    const preciosMS = await P.preciosDeMicrosoft(filas.map((f) => f.ms_id));
    const cambios = { sube: [], baja: [], oculta: [], revive: [], igual: 0, sinCambio: 0, store: [] };

    for (const f of filas) {
      const o = kinguin.get(f.slug);
      const guardado = Number(f.precio_lista || 0);
      const listaMXN = (f.ms_id && preciosMS[f.ms_id]) ? preciosMS[f.ms_id] : guardado;
      if (listaMXN && listaMXN !== guardado) {
        cambios.store.push({ slug: f.slug, title: f.title, antes: guardado, ahora: listaMXN });
      }

      if (!o) {
        if (f.status !== 'hidden') cambios.oculta.push({ slug: f.slug, title: f.title, motivo: 'ya no está en Kinguin' });
        else cambios.igual++;
        continue;
      }

      const costo = Math.round(o.costoBase * (1 + P.CFG.cuota));
      const r = P.precioDeVenta(costo, o.ofertas, listaMXN);

      if (r.venta == null) {
        if (f.status !== 'hidden') cambios.oculta.push({ slug: f.slug, title: f.title, motivo: r.motivo });
        else cambios.igual++;
        continue;
      }

      const antes = Number(f.price || 0);
      const store = listaMXN || null;
      if (f.status === 'hidden') {
        cambios.revive.push({ slug: f.slug, title: f.title, ahora: r.venta, costo, region: o.region, url: o.url, store });
      } else if (r.venta !== antes) {
        (r.venta > antes ? cambios.sube : cambios.baja)
          .push({ slug: f.slug, title: f.title, antes, ahora: r.venta, costo, region: o.region, url: o.url, store });
      } else if (listaMXN && listaMXN !== guardado) {
        /* El precio nuestro no cambia pero el de Xbox sí: hay que guardarlo
           igual, que es el tachado que ve el cliente y el que decide mañana
           si el juego sigue conviniendo. */
        cambios.baja.push({ slug: f.slug, title: f.title, antes, ahora: r.venta, costo, region: o.region, url: o.url, store });
      } else {
        cambios.igual++;
      }
    }

    const resumen = {
      ensayo,
      revisados: filas.length,
      suben: cambios.sube.length,
      bajan: cambios.baja.length,
      seEsconden: cambios.oculta.length,
      vuelven: cambios.revive.length,
      sinCambio: cambios.igual,
      preciosDeXboxQueCambiaron: cambios.store.length,
      tipoCambio: Number(tipoCambio.toFixed(4)),
      masSuben: cambios.sube.slice().sort((a, b) => (b.ahora - b.antes) - (a.ahora - a.antes)).slice(0, 8),
      seEscondieron: cambios.oculta.slice(0, 8),
    };

    if (ensayo) {
      resumen.segundos = Math.round((Date.now() - t0) / 1000);
      return res.json(resumen);
    }

    // ── Escribir ──
    const aTocar = cambios.sube.concat(cambios.baja, cambios.revive).slice(0, TOPE_ESCRITURAS);
    await P.enTanda(aTocar, 8, async (c) => {
      const cuerpo = { price: c.ahora, status: 'active', updated_at: new Date().toISOString() };
      if (c.store) cuerpo.precio_lista = c.store;
      await P.supa('vg_xbox_games?slug=eq.' + encodeURIComponent(c.slug), {
        method: 'PATCH',
        body: JSON.stringify(cuerpo),
      });
      await P.supa('vg_xbox_costos', {
        method: 'POST',
        headers: { Prefer: 'resolution=merge-duplicates' },
        body: JSON.stringify({
          slug: c.slug, costo: c.costo, region: c.region,
          url_proveedor: c.url, actualizado: new Date().toISOString(),
        }),
      });
    });

    const aEsconder = cambios.oculta.slice(0, TOPE_ESCRITURAS);
    await P.enTanda(aEsconder, 8, async (o) => {
      await P.supa('vg_xbox_games?slug=eq.' + encodeURIComponent(o.slug), {
        method: 'PATCH',
        body: JSON.stringify({ status: 'hidden', updated_at: new Date().toISOString() }),
      });
    });

    resumen.escritos = aTocar.length;
    resumen.escondidos = aEsconder.length;
    resumen.pendientes = Math.max(0,
      (cambios.sube.length + cambios.baja.length + cambios.revive.length - aTocar.length) +
      (cambios.oculta.length - aEsconder.length));
    resumen.segundos = Math.round((Date.now() - t0) / 1000);
    res.json(resumen);
  } catch (e) {
    res.status(502).json({ error: String(e.message).slice(0, 200), segundos: Math.round((Date.now() - t0) / 1000) });
  }
};
