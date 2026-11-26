/* GET /api/contenido-inicio
 *
 * Lo que se muestra en el inicio de la tienda y que Miguel edita
 * desde el panel admin (pestaña "Inicio"): la cinta informativa, las
 * promociones del héroe y las ofertas destacadas.
 *
 * Lee la tabla vg_inicio_contenido (solo filas activas). Si la tabla
 * no existe o está vacía, devuelve el contenido por defecto (el mismo
 * de la muestra del inicio estilo Kinguin) para que el inicio nunca
 * se quede vacío. La escritura no pasa por aquí: el panel admin
 * escribe directo a Supabase con la sesión del administrador.
 */

const SUPA_URL = process.env.SUPABASE_URL || '';
const SUPA_ANON = process.env.SUPABASE_ANON_KEY || '';

const POR_DEFECTO = {
  cinta: [
    { id: 'd1', texto: 'Entrega inmediata · Precios en MXN' },
    { id: 'd2', texto: 'Xbox Cuentas: 1,640 juegos en cuenta nueva, más baratos que en México' },
    { id: 'd3', texto: 'Diamantes Free Fire y CODPoints al mejor precio' },
  ],
  heroes: [
    { id: 'h1', titulo: 'Xbox Cuentas', subtitulo: '1,640 juegos en cuenta nueva desde $20 MXN', enlace: 'retro', imagen: '' },
    { id: 'h2', titulo: 'Fortnite', subtitulo: 'Skins, lotes y pases al mejor precio', enlace: 'fortnite', imagen: '' },
    { id: 'h3', titulo: 'CODPoints de Warzone', subtitulo: 'Recarga tu cuenta y juega hoy mismo', enlace: 'gaming', imagen: '' },
    { id: 'h4', titulo: 'Game Pass', subtitulo: 'Ultimate y Core desde $90 MXN', enlace: 'gaming', imagen: '' },
  ],
  ofertas: [
    { id: 'o1', titulo: 'Gears Of War 3', subtitulo: 'Xbox 360 · Cuenta nueva', precio: 45, precio_mx: 57.25, enlace: 'retro', imagen: '' },
    { id: 'o2', titulo: 'Alan Wake', subtitulo: 'Xbox 360 · Cuenta nueva', precio: 185, precio_mx: 529, enlace: 'retro', imagen: '' },
  ],
};

async function leerTabla() {
  const url = SUPA_URL + '/rest/v1/vg_inicio_contenido?select=*&activo=eq.true&order=tipo.asc,orden.asc';
  const r = await fetch(url, {
    headers: { apikey: SUPA_ANON, Authorization: 'Bearer ' + SUPA_ANON },
  });
  if (!r.ok) throw new Error('Supabase HTTP ' + r.status);
  return r.json();
}

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=300, stale-while-revalidate=600');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  let fuente = 'respaldo';
  let cinta = POR_DEFECTO.cinta;
  let heroes = POR_DEFECTO.heroes;
  let ofertas = POR_DEFECTO.ofertas;
  try {
    if (!SUPA_URL || !SUPA_ANON) throw new Error('sin variables de Supabase');
    const filas = await leerTabla();
    if (Array.isArray(filas) && filas.length) {
      fuente = 'supabase';
      const porTipo = (t) => filas.filter((f) => f.tipo === t).sort((a, b) => (a.orden || 0) - (b.orden || 0));
      const c = porTipo('cinta');
      const h = porTipo('heroe');
      const o = porTipo('oferta');
      if (c.length) cinta = c.map((f) => ({ id: f.id, texto: f.titulo }));
      if (h.length) heroes = h.map((f) => ({ id: f.id, titulo: f.titulo, subtitulo: f.subtitulo || '', enlace: f.enlace || '', imagen: f.imagen || '' }));
      if (o.length) ofertas = o.map((f) => ({ id: f.id, titulo: f.titulo, subtitulo: f.subtitulo || '', precio: Number(f.precio || 0), precio_mx: Number(f.precio_mx || 0), enlace: f.enlace || '', imagen: f.imagen || '' }));
    }
  } catch (e) { /* cae al contenido por defecto */ }
  res.status(200).json({ cinta, heroes, ofertas, fuente });
};
