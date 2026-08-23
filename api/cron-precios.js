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

const TOPE_ESCRITURAS = 300;   // cambios de precio por corrida, para no pasarse del minuto
const TOPE_ALTAS = 200;        // altas por corrida; el resto entra al día siguiente
/* La corrida diaria comparte el minuto que da Vercel con los precios, así
   que ahí se reparan de poco en poco. Pidiendo solo portadas no compite con
   nada y caben todas de una: hoy hay 538 por arreglar. */
const TOPE_PORTADAS = 250;
const TOPE_PORTADAS_SOLAS = 800;
/* 390 juegos de la tienda no tienen ficha de Microsoft guardada, y sin ella
   no hay contra qué comparar: se publican sin la red que impide venderlos más
   caros que la tienda oficial. Se buscan de poco en poco, que buscar un
   título son hasta cuatro consultas y el minuto de Vercel es para todos. */
const TOPE_FICHAS = 60;
/* El precio oficial solo se guardaba cuando el juego cambiaba de precio.
   Los que no cambiaban se quedaban con el hueco vacío para siempre, y ése
   es justo el número que decide si el juego se puede publicar: 29 se
   estaban vendiendo por encima de la tienda de Xbox por esto. Ahora se
   guarda aunque no cambie nada más. */
const TOPE_LISTA = 500;
const CONCURRENCIA_PAGINAS = 10;
const CONCURRENCIA = 12;

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');

  const ensayo = String(req.query.ensayo || '') === '1';
  /* Con ?soloPortadas=1 se repara la imagen y no se toca ni un precio.
     Sirve para arreglar el catálogo hoy sin esperar al repaso de mañana y
     sin mover nada de lo que el cliente ya vio anunciado. */
  const soloPortadas = String(req.query.soloPortadas || '') === '1';

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
      const lote = await P.supa('vg_xbox_games?select=slug,title,price,precio_lista,ms_id,status,image&slug=not.is.null&order=slug.asc&limit=1000&offset=' + desde);
      filas.push.apply(filas, lote);
      if (lote.length < 1000) break;
      desde += 1000;
    }

    /* El precio de la tienda de Xbox se relee cada vez. Guardarlo y no volver
       a mirarlo era el fallo que dejaba publicar un juego más caro que en la
       propia tienda: las rebajas de Microsoft duran días. */
    const preciosMS = await P.preciosDeMicrosoft(filas.map((f) => f.ms_id));

    /* ── Fichas de Microsoft que faltan ──

       Sin ms_id no hay precio oficial, y sin precio oficial precioDeVenta()
       no puede comprobar que el juego quede por debajo de la tienda de Xbox:
       se publica a lo que salga. Así se colaron 29 juegos más caros que la
       tienda, uno a $4,065 contra los $999 que cobra Microsoft.

       Se buscan de TOPE_FICHAS en TOPE_FICHAS por corrida, empezando por los
       más caros, que son los que más dinero cuestan si el precio está mal.
       En una semana quedan todos. Solo se guarda el número de la ficha: la
       portada NO se toca, que emparejar por nombre fue lo que cruzó 328
       carátulas entre juegos de la misma saga. */
    const sinFicha = filas.filter((f) => !f.ms_id && f.status !== 'hidden')
      .sort((a, b) => Number(b.price || 0) - Number(a.price || 0))
      .slice(0, TOPE_FICHAS);
    const fichasNuevas = new Map();
    await P.enTanda(sinFicha, 8, async (f) => {
      const m = await P.buscarEnMicrosoft(f.title, f.edicion);
      if (m) fichasNuevas.set(f.slug, m.id);
    });
    if (fichasNuevas.size) {
      const masPrecios = await P.preciosDeMicrosoft([...fichasNuevas.values()]);
      for (const k of Object.keys(masPrecios)) if (k !== '__fallidos') preciosMS[k] = masPrecios[k];
    }
    const fichaDe = (f) => f.ms_id || fichasNuevas.get(f.slug) || '';

    /* ── Carátulas cruzadas ──

       Se vendía "Call of Duty: Advanced Warfare Gold Edition" con la
       portada de "Call of Duty: WWII". No era una ficha suelta: 328 de
       2.744 juegos (el 12%) enseñaban la carátula de otro juego, en 110
       montones donde una sola imagen valía para siete títulos distintos.
       Vendiendo por foto, eso es dinero: el cliente compra lo que ve.

       De dónde venían. Esta función pone la portada de Kinguin, que es
       de cada producto, y solo al dar de alta. La herramienta de la PC
       (vessel-precios) las reescribe con las de la tienda de Microsoft, y
       ésas las empareja por nombre: toda la saga acababa con la misma.
       Los números lo dicen solos: de los 186 montones que compartían
       imagen, 184 eran direcciones de Microsoft y ninguna de las 325
       portadas de Kinguin estaba repartida entre juegos distintos.

       Qué se repara. Solo lo demostrablemente ambiguo: una portada que
       usan DOS O MÁS juegos de la tienda. A ésas se les devuelve la de
       Kinguin de ese juego exacto. Una portada que solo usa un juego no
       se toca, aunque no coincida: no hay motivo para pensar que esté
       mal y no vale la pena arriesgar una buena.

       Dos juegos que de verdad son el mismo (la versión japonesa y la de
       aquí) comparten portada con razón. No hay que distinguirlos a mano:
       Kinguin les da la misma imagen a los dos, así que se quedan igual. */
    const slugsPorImagen = new Map();
    for (const f of filas) {
      const img = String(f.image || '');
      if (!img) continue;
      if (!slugsPorImagen.has(img)) slugsPorImagen.set(img, new Set());
      slugsPorImagen.get(img).add(f.slug);
    }
    const portadaCompartida = (img) => {
      const s = slugsPorImagen.get(String(img || ''));
      return !!s && s.size > 1;
    };

    const cambios = { sube: [], baja: [], oculta: [], revive: [], alta: [], portada: [], igual: 0, sinCambio: 0, store: [] };

    for (const f of filas) {
      const o = kinguin.get(f.slug);
      const guardado = Number(f.precio_lista || 0);
      const idMS = fichaDe(f);
      const listaMXN = (idMS && preciosMS[idMS]) ? preciosMS[idMS] : guardado;
      if (listaMXN && listaMXN !== guardado) {
        cambios.store.push({ slug: f.slug, title: f.title, antes: guardado, ahora: listaMXN, ficha: fichasNuevas.get(f.slug) || null });
      } else if (fichasNuevas.has(f.slug)) {
        /* Se encontró la ficha aunque hoy no dé precio: se guarda igual para
           no volver a buscarla mañana. */
        cambios.store.push({ slug: f.slug, title: f.title, antes: guardado, ahora: 0, ficha: fichasNuevas.get(f.slug) });
      }

      if (!o) {
        if (f.status !== 'hidden') cambios.oculta.push({ slug: f.slug, title: f.title, motivo: 'ya no está en Kinguin' });
        else cambios.igual++;
        continue;
      }

      /* La portada se revisa aunque el juego acabe escondido: si mañana
         vuelve, vuelve con la suya. */
      if (o.portada && o.portada !== f.image && portadaCompartida(f.image)) {
        cambios.portada.push({ slug: f.slug, title: f.title, antes: f.image, ahora: o.portada });
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
      kinguin.delete(f.slug);   // lo que sobre al final son juegos nuevos
    }

    /* ── Altas ──
       Lo que quedó en el mapa de Kinguin no está en la tienda. Antes esto
       solo lo hacía el script de la PC, así que un juego nuevo no entraba
       hasta que se corría a mano y se reimportaba el CSV. Con el catálogo
       moviéndose todos los días, eso es un catálogo que envejece solo.

       Sin precio de la Store no se puede comprobar que no salga más caro que
       Microsoft, así que esos esperan a la siguiente corrida del script de
       la PC, que sí sabe preguntárselo. */
    for (const [slug, o] of kinguin) {
      const costo = Math.round(o.costoBase * (1 + P.CFG.cuota));
      const r = P.precioDeVenta(costo, o.ofertas, 0);
      if (r.venta == null) continue;
      cambios.alta.push({
        slug, title: o.titulo, edicion: o.edicion, plataforma: o.plataforma,
        ahora: r.venta, costo, region: o.region, url: o.url,
        generos: (o.generos || []).join(' · '), portada: o.portada,
      });
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
      altasNuevas: cambios.alta.length,
      portadasCruzadas: cambios.portada.length,
      ejemplosPortadas: cambios.portada.slice(0, 6).map(function (c) { return c.title; }),
      primerasAltas: cambios.alta.slice(0, 6).map(function (a) { return a.title + ' a ' + a.ahora; }),
      tipoCambio: Number(tipoCambio.toFixed(4)),
      /* Si Microsoft dejó bloques sin contestar, hay juegos que pasaron el
         repaso sin comparar contra la tienda oficial. Sale en el informe
         para que no se lea como "todo revisado" cuando no lo fue. */
      bloquesDeXboxSinRespuesta: preciosMS.__fallidos || 0,
      masSuben: cambios.sube.slice().sort((a, b) => (b.ahora - b.antes) - (a.ahora - a.antes)).slice(0, 8),
      seEscondieron: cambios.oculta.slice(0, 8),
    };

    if (ensayo) {
      resumen.segundos = Math.round((Date.now() - t0) / 1000);
      return res.json(resumen);
    }

    // ── Escribir ──

    /* Las portadas van primero y aparte del tope de precios: son el fallo
       que se ve en la tarjeta, y no compiten por el mismo cupo. */
    const topePortadas = soloPortadas ? TOPE_PORTADAS_SOLAS : TOPE_PORTADAS;
    const aRepintar = cambios.portada.slice(0, topePortadas);
    await P.enTanda(aRepintar, 8, async (c) => {
      await P.supa('vg_xbox_games?slug=eq.' + encodeURIComponent(c.slug), {
        method: 'PATCH',
        body: JSON.stringify({ image: c.ahora, updated_at: new Date().toISOString() }),
      });
    });
    resumen.portadasArregladas = aRepintar.length;
    resumen.portadasPendientes = Math.max(0, cambios.portada.length - aRepintar.length);

    /* Con ?soloPortadas=1 se acaba aquí: ni precios, ni altas, ni bajas. */
    if (soloPortadas) {
      resumen.soloPortadas = true;
      resumen.segundos = Math.round((Date.now() - t0) / 1000);
      return res.json(resumen);
    }

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

    /* Las altas entran al final del catálogo, con orden alto, para no
       desordenar lo que ya estaba colocado. */
    const aDarDeAlta = cambios.alta.slice(0, TOPE_ALTAS);
    if (aDarDeAlta.length) {
      const lotes = [];
      for (let i = 0; i < aDarDeAlta.length; i += 100) lotes.push(aDarDeAlta.slice(i, i + 100));
      for (const lote of lotes) {
        await P.supa('vg_xbox_games', {
          method: 'POST',
          body: JSON.stringify(lote.map(function (a, i) {
            return {
              slug: a.slug, title: a.title, edicion: a.edicion, platform: a.plataforma,
              generos: a.generos || null, price: a.ahora, precio_lista: null,
              image: a.portada || '', status: 'active', orden: 9000 + i,
            };
          })),
        });
        await P.supa('vg_xbox_costos', {
          method: 'POST',
          headers: { Prefer: 'resolution=merge-duplicates' },
          body: JSON.stringify(lote.map(function (a) {
            return { slug: a.slug, costo: a.costo, region: a.region, url_proveedor: a.url, actualizado: new Date().toISOString() };
          })),
        });
      }
    }

    const aEsconder = cambios.oculta.slice(0, TOPE_ESCRITURAS);
    await P.enTanda(aEsconder, 8, async (o) => {
      await P.supa('vg_xbox_games?slug=eq.' + encodeURIComponent(o.slug), {
        method: 'PATCH',
        body: JSON.stringify({ status: 'hidden', updated_at: new Date().toISOString() }),
      });
    });

    /* ── Guardar el precio oficial de Xbox ──

       Antes esto solo se escribía de rebote, cuando el juego cambiaba de
       precio o se revivía. Un juego estable no lo guardaba nunca, y uno que
       acababa escondido tampoco: la casilla se quedaba vacía, el panel no
       tenía qué enseñar y la comprobación contra la tienda oficial se hacía
       contra un cero, o sea que no se hacía. Ahora se guarda siempre, aparte
       de todo lo demás, y de paso el número de ficha recién encontrado. */
    const yaEscritos = new Set(aTocar.map((c) => c.slug));
    const listaPendiente = cambios.store.filter((c) => !yaEscritos.has(c.slug));
    const aGuardarLista = listaPendiente.slice(0, TOPE_LISTA);
    await P.enTanda(aGuardarLista, 10, async (c) => {
      const cuerpo = {};
      if (c.ahora) cuerpo.precio_lista = c.ahora;
      if (c.ficha) cuerpo.ms_id = c.ficha;
      if (!Object.keys(cuerpo).length) return;
      await P.supa('vg_xbox_games?slug=eq.' + encodeURIComponent(c.slug), {
        method: 'PATCH',
        body: JSON.stringify(cuerpo),
      });
    });

    resumen.escritos = aTocar.length;
    resumen.dadosDeAlta = aDarDeAlta.length;
    resumen.escondidos = aEsconder.length;
    resumen.fichasDeXboxEncontradas = fichasNuevas.size;
    resumen.preciosDeXboxGuardados = aGuardarLista.length;
    resumen.preciosDeXboxPorGuardar = listaPendiente.length - aGuardarLista.length;
    resumen.pendientes = Math.max(0,
      (cambios.sube.length + cambios.baja.length + cambios.revive.length - aTocar.length) +
      (cambios.oculta.length - aEsconder.length));
    resumen.segundos = Math.round((Date.now() - t0) / 1000);
    res.json(resumen);
  } catch (e) {
    res.status(502).json({ error: String(e.message).slice(0, 200), segundos: Math.round((Date.now() - t0) / 1000) });
  }
};
