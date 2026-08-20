/* GET /api/precio?slug=…   ó   /api/precio?titulo=…
 *
 * Le pregunta a Kinguin cuánto cuesta ese juego AHORA MISMO y contesta con lo
 * que te costaría, lo que ganarías al precio que tienes puesto, y el enlace
 * para comprarlo. Es lo que el navegador no puede hacer solo: Kinguin no
 * acepta llamadas desde una página web (CORS), pero sí desde un servidor.
 *
 * Solo contesta al administrador.
 */
const P = require('./_precios');

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');

  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_KEY) {
    return res.status(500).json({ error: 'Faltan las variables de entorno de Supabase en Vercel.' });
  }
  const quien = await P.esAdmin(req);
  if (!quien.ok) {
    return res.status(403).json({ error: 'Solo el administrador. ' + quien.motivo });
  }

  const slug = String(req.query.slug || '').trim();
  const titulo = String(req.query.titulo || '').trim();
  if (!slug && !titulo) return res.status(400).json({ error: 'Dime slug o titulo.' });

  try {
    // Lo que hay guardado, para comparar contra lo de ahora.
    let fila = null;
    if (slug) {
      const r = await P.supa('vg_xbox_games?select=slug,title,edicion,price,precio_lista,ms_id,status&slug=eq.' + encodeURIComponent(slug));
      fila = (r && r[0]) || null;
    }

    const frase = titulo || (fila && fila.title) || slug.replace(/-/g, ' ');
    const [tipoCambio, crudos] = await Promise.all([P.tipoDeCambio(), P.buscarUno(frase)]);
    const mapa = P.agrupar(crudos, tipoCambio);

    // Se busca por slug exacto; si no, el más parecido por nombre.
    let oferta = slug ? mapa.get(slug) : null;
    if (!oferta) {
      const objetivo = (frase || '').toLowerCase();
      let mejor = null, puntos = 0;
      for (const o of mapa.values()) {
        const a = new Set(o.titulo.toLowerCase().split(/\s+/));
        const b = new Set(objetivo.split(/\s+/));
        let comunes = 0;
        for (const w of a) if (b.has(w)) comunes++;
        const p = comunes / Math.max(a.size, b.size);
        if (p > puntos) { puntos = p; mejor = o; }
      }
      if (puntos >= 0.5) oferta = mejor;
    }

    if (!oferta) {
      return res.json({
        encontrado: false,
        buscado: frase,
        aviso: 'Kinguin ya no lo tiene con ese nombre. Búscalo a mano antes de venderlo.',
        enlaceBusqueda: 'https://www.kinguin.net/listing?phrase=' + encodeURIComponent(frase) + '&platforms=10,20&hideUnavailable=1&active=1',
      });
    }

    const costo = Math.round(oferta.costoBase * (1 + P.CFG.cuota));

    /* El precio de Xbox se pregunta ahora, no se lee el guardado: sus rebajas
       duran días y es justo contra ese número contra el que compites. */
    let listaMXN = fila ? Number(fila.precio_lista || 0) : 0;
    if (fila && fila.ms_id) {
      const vivos = await P.preciosDeMicrosoft([fila.ms_id]);
      if (vivos[fila.ms_id]) listaMXN = vivos[fila.ms_id];
    }

    const sugerido = P.precioDeVenta(costo, oferta.ofertas, listaMXN);
    const tuPrecio = fila ? Number(fila.price || 0) : 0;
    const ganas = tuPrecio ? tuPrecio - costo : null;
    const margen = (tuPrecio && costo) ? Math.round((tuPrecio - costo) / costo * 100) : null;
    const masCaroQueXbox = !!(tuPrecio && listaMXN && tuPrecio >= listaMXN);

    res.json({
      encontrado: true,
      titulo: oferta.titulo,
      edicion: oferta.edicion,
      region: oferta.region,
      ofertas: oferta.ofertas,
      tipoCambio: Number(tipoCambio.toFixed(4)),
      costoAhora: costo,
      tuPrecio: tuPrecio || null,
      ganas,
      margen,
      precioSugerido: sugerido.venta,
      motivoSinPrecio: sugerido.motivo || null,
      precioXbox: listaMXN || null,
      masCaroQueXbox,
      // Las dos señales que importan: ¿te deja dinero? ¿le ganas a Xbox?
      alerta: masCaroQueXbox
        ? 'MÁS CARO que en la tienda de Xbox ($' + listaMXN.toLocaleString('es-MX') + ')'
        : (ganas !== null && ganas < P.CFG.gananciaMinima)
          ? (ganas <= 0 ? 'PIERDES dinero a tu precio actual' : 'Ganas menos de $' + P.CFG.gananciaMinima)
          : null,
      enlace: oferta.url,
      enlaceBusqueda: 'https://www.kinguin.net/listing?phrase=' + encodeURIComponent(oferta.titulo) + '&platforms=10,20&hideUnavailable=1&active=1',
    });
  } catch (e) {
    res.status(502).json({ error: 'No se pudo consultar Kinguin: ' + String(e.message).slice(0, 160) });
  }
};
