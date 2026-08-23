/* GET /api/catalogo-xbox
 *
 * El catálogo de Xbox One / Series que pinta la tienda, servido desde la red
 * de Vercel en vez de desde Supabase.
 *
 * Por qué existe. La portada se bajaba el catálogo entero de Supabase en cada
 * visita: 3.008 filas con select('*'), medio mega comprimido, y encima dos
 * veces porque cuatro bloques distintos lo pedían a la vez. Con el plan
 * gratis de Supabase (5 GB de salida al mes) eso son unas 165 visitas al día
 * y se acabó la cuota. Ya pasó una vez.
 *
 * Qué cambia. Esto es lo mismo, pero:
 *   · solo los juegos que se venden —los 293 escondidos se bajaban a todo el
 *     mundo para que la tienda los tirara al pintar—;
 *   · solo las columnas que la ficha enseña; created_at, updated_at y ms_id
 *     eran el 20% del peso y no se usan en ningún sitio;
 *   · con cabecera de caché, así que Vercel lo guarda y Supabase lo sirve una
 *     vez cada diez minutos en lugar de una vez por visitante.
 *
 * El catálogo se mueve una vez al día, cuando corre el cron de las 7. Diez
 * minutos de caché no se notan; para ver un cambio al instante desde el panel
 * está ?fresco=1, que se salta la caché.
 *
 * Si esto falla, la tienda vuelve a pedirle los juegos a Supabase por su
 * cuenta: es más caro, pero se ve el catálogo. Nunca una tienda vacía.
 */

/* Lo que la tarjeta necesita para pintarse, y nada más. */
const CAMPOS = 'id,slug,title,edicion,platform,price,precio_lista,image,status,generos,orden';

module.exports = async (req, res) => {
  const fresco = String(req.query.fresco || '') === '1';

  const raiz = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  /* La anónima basta y es la que toca: estos juegos ya son públicos, los lee
     cualquiera desde el navegador. La de servicio solo entra si la otra no
     está puesta. */
  const clave = String(process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_KEY || '').trim().replace(/^["']|["']$/g, '');

  if (!raiz || !clave) {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(500).json({ error: 'Faltan SUPABASE_URL o SUPABASE_ANON_KEY en Vercel.' });
  }

  try {
    /* Supabase no da más de 1.000 filas por consulta, así que se pide de mil
       en mil hasta que devuelva menos de mil. El orden por id no es el que se
       ve —ése lo pone la columna 'orden' al pintar—: es para paginar sin
       repetir ni saltarse filas. */
    const juegos = [];
    for (let desde = 0; desde < 20000; desde += 1000) {
      const url = `${raiz}/rest/v1/vg_xbox_games?select=${CAMPOS}&status=eq.active&order=id.asc&offset=${desde}&limit=1000`;
      const r = await fetch(url, { headers: { apikey: clave, Authorization: 'Bearer ' + clave } });
      if (!r.ok) throw new Error('Supabase ' + r.status + ': ' + (await r.text()).slice(0, 160));
      const lote = await r.json();
      juegos.push.apply(juegos, lote);
      if (lote.length < 1000) break;
    }

    if (fresco) {
      res.setHeader('Cache-Control', 'no-store');
    } else {
      /* Diez minutos de caché en la red de Vercel. Pasados esos, el primero
         que llegue se lleva la copia vieja igual —sin esperar— mientras por
         detrás se pide la nueva: así ninguna visita paga el viaje a Supabase.
         El navegador no la guarda (max-age=0) para que un cambio en el panel
         se vea al recargar sin tener que vaciar la caché. */
      res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=600, stale-while-revalidate=3600');
    }
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.status(200).json({ juegos, total: juegos.length });
  } catch (e) {
    res.setHeader('Cache-Control', 'no-store');
    res.status(502).json({ error: String(e.message).slice(0, 200) });
  }
};
