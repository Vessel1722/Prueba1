/* GET /juego/<slug>
 *
 * La página que se manda por WhatsApp. Existe por un motivo concreto: la
 * tienda es una sola página y WhatsApp, Facebook y compañía leen el HTML
 * ANTES de que corra nada de JavaScript. Da igual lo que la página haga
 * después: la vista previa que enseñan es la portada genérica del sitio.
 *
 * Esto sirve, para ese enlace, un HTML pequeño con el nombre del juego, su
 * precio y su portada en las etiquetas que leen esos programas. Al visitante
 * de carne y hueso se le manda a la tienda en cuanto carga.
 *
 * No pide sesión: es una ficha de producto, está hecha para enseñarse.
 */

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

const BASE = 'https://www.vesselgames.xyz';
const PORTADA_POR_DEFECTO = BASE + '/og-vessel-games.png';

module.exports = async (req, res) => {
  const slug = String((req.query && req.query.slug) || '').trim();

  const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  const clave = String(process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_KEY || '').trim();

  let juego = null;
  if (slug && url && clave) {
    try {
      const r = await fetch(
        `${url}/rest/v1/vg_xbox_games?select=slug,title,edicion,platform,price,precio_lista,image,status,generos&slug=eq.${encodeURIComponent(slug)}&limit=1`,
        { headers: { apikey: clave, Authorization: 'Bearer ' + clave } }
      );
      if (r.ok) {
        const filas = await r.json();
        juego = (filas && filas[0]) || null;
      }
    } catch (e) { /* si falla, se sirve la ficha genérica */ }
  }

  const destino  = BASE + '/?juego=' + encodeURIComponent(slug);   // adonde va la persona
  /* La dirección que se comparte y la que debe indexar Google es esta, no la
     de destino: es la que sale en el mapa del sitio y la que lleva la ficha. */
  const canonica = BASE + '/juego/' + encodeURIComponent(slug);

  const pesos = (n) => '$' + Number(n || 0).toLocaleString('es-MX') + ' MXN';
  const titulo = juego ? juego.title : 'Juegos de Xbox One / Series';
  const precio = juego ? Number(juego.price || 0) : 0;
  const lista = juego ? Number(juego.precio_lista || 0) : 0;
  const ahorro = (lista > precio && precio > 0) ? lista - precio : 0;

  const descripcion = juego
    ? [
        precio ? pesos(precio) : null,
        ahorro ? 'Ahorras ' + pesos(ahorro) + ' contra la Microsoft Store' : null,
        [juego.edicion, juego.platform].filter(Boolean).join(' · '),
        'Entrega por código: lo canjeas en tu cuenta y el juego queda a tu nombre.',
      ].filter(Boolean).join(' · ')
    : 'Catálogo de juegos digitales para Xbox One y Xbox Series, con entrega por código.';

  const portada = (juego && juego.image) ? juego.image : PORTADA_POR_DEFECTO;

  const html = `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(titulo)}${precio ? ' — ' + esc(pesos(precio)) : ''} | Vessel Games</title>
<meta name="description" content="${esc(descripcion)}">
<link rel="canonical" href="${esc(canonica)}">

<meta property="og:type" content="product">
<meta property="og:site_name" content="Vessel Games">
<meta property="og:locale" content="es_MX">
<meta property="og:title" content="${esc(titulo)}${precio ? ' — ' + esc(pesos(precio)) : ''}">
<meta property="og:description" content="${esc(descripcion)}">
<meta property="og:image" content="${esc(portada)}">
<meta property="og:image:alt" content="${esc(titulo)}">
<meta property="og:url" content="${esc(canonica)}">
${precio ? `<meta property="product:price:amount" content="${precio}">
<meta property="product:price:currency" content="MXN">` : ''}

<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(titulo)}">
<meta name="twitter:description" content="${esc(descripcion)}">
<meta name="twitter:image" content="${esc(portada)}">

<style>
  body{margin:0;background:#08090f;color:#f7f3ea;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
       display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}
  .f{max-width:420px;text-align:center}
  .f img{width:100%;max-width:260px;border-radius:18px;display:block;margin:0 auto 18px}
  h1{font-size:20px;margin:0 0 8px;line-height:1.3}
  .p{font-size:26px;font-weight:800;color:#19e6c1;margin:0 0 4px}
  .l{color:#8b90a0;text-decoration:line-through;font-size:14px}
  .d{color:#9aa0b0;font-size:13.5px;margin:14px 0 20px;line-height:1.55}
  a{display:inline-block;background:#19e6c1;color:#08221c;text-decoration:none;
    border-radius:999px;padding:13px 30px;font-weight:800}
</style>
</head>
<body>
  <div class="f">
    <img src="${esc(portada)}" alt="${esc(titulo)}">
    <h1>${esc(titulo)}</h1>
    ${precio ? `<p class="p">${esc(pesos(precio))}</p>` : ''}
    ${ahorro ? `<p class="l">${esc(pesos(lista))} en la Microsoft Store</p>` : ''}
    <p class="d">${esc(descripcion)}</p>
    <a href="${esc(destino)}">Ver en la tienda</a>
  </div>

  <!-- Al visitante se le lleva a la tienda; los programas que arman la vista
       previa no ejecutan esto, así que se quedan con las etiquetas de arriba. -->
  <script>location.replace(${JSON.stringify(destino)});</script>
</body>
</html>`;

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'public, max-age=600, s-maxage=600');
  res.status(200).send(html);
};
