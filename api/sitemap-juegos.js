/* GET /sitemap-juegos.xml
 *
 * El mapa del sitio con un enlace por juego. Antes había siete direcciones
 * para toda la tienda, así que a quien busca "comprar hogwarts legacy xbox"
 * Google no tenía nada suyo que ofrecerle.
 *
 * Se genera al vuelo leyendo el catálogo, y no como archivo: el catálogo
 * cambia todos los días —el repaso diario da de alta y esconde juegos— y un
 * archivo escrito a mano se quedaría viejo en una semana.
 *
 * No pide sesión: es justo lo contrario, está hecho para que lo lean los
 * buscadores. Solo salen juegos activos, que son los que se pueden comprar.
 */

const BASE = 'https://www.vesselgames.xyz';

const SECCIONES = [
  '', '?seccion=gaming', '?seccion=xbox', '?seccion=retro', '?seccion=fortnite',
  '?seccion=streaming', '?seccion=cuentas', '?seccion=software',
  '?seccion=actas', '?seccion=redes',
];

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

module.exports = async (req, res) => {
  const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  const clave = String(process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_KEY || '').trim();

  const filas = [];
  if (url && clave) {
    try {
      let desde = 0;
      while (true) {
        const r = await fetch(
          `${url}/rest/v1/vg_xbox_games?select=slug,updated_at&status=eq.active&slug=not.is.null&order=slug.asc&limit=1000&offset=${desde}`,
          { headers: { apikey: clave, Authorization: 'Bearer ' + clave } }
        );
        if (!r.ok) break;
        const lote = await r.json();
        filas.push(...lote);
        if (lote.length < 1000) break;
        desde += 1000;
        if (desde >= 20000) break;
      }
    } catch (e) { /* si falla, al menos salen las secciones */ }
  }

  const hoy = new Date().toISOString().slice(0, 10);
  const partes = [];
  partes.push('<?xml version="1.0" encoding="UTF-8"?>');
  partes.push('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');

  for (const s of SECCIONES) {
    partes.push('<url><loc>' + esc(BASE + '/' + s) + '</loc>' +
      '<changefreq>daily</changefreq><priority>' + (s ? '0.8' : '1.0') + '</priority></url>');
  }

  for (const f of filas) {
    if (!f.slug) continue;
    const fecha = f.updated_at ? String(f.updated_at).slice(0, 10) : hoy;
    partes.push('<url><loc>' + esc(BASE + '/?juego=' + encodeURIComponent(f.slug)) + '</loc>' +
      '<lastmod>' + esc(fecha) + '</lastmod>' +
      '<changefreq>weekly</changefreq><priority>0.6</priority></url>');
  }

  partes.push('</urlset>');

  res.setHeader('Content-Type', 'application/xml; charset=utf-8');
  /* Media hora de caché: los buscadores no necesitan el minuto exacto y así
     una visita del robot no se convierte en tres mil lecturas a la base. */
  res.setHeader('Cache-Control', 'public, max-age=1800, s-maxage=1800');
  res.status(200).send(partes.join('\n'));
};
