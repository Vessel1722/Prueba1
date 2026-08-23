/* Vessel Games · las reglas de precio y las tuberías hacia Kinguin y Supabase.
 *
 * Este archivo no es una ruta: Vercel ignora los que empiezan con guion bajo.
 *
 * OJO: las reglas de abajo son las mismas que las de nucleo.mjs, en la carpeta
 * vessel-precios de tu PC. Si cambias una, cámbiala en las dos, o la tienda y
 * el script te van a dar precios distintos.
 */

// ═══════════════ LAS REGLAS ═══════════════
const CFG = {
  cuota: 0.16,                  // cuota de servicio de Kinguin (medida: 15.5%)
  gananciaMinima: 100,
  /* En los juegos de dos pesos los extras se acumulaban y salía un precio que
     espantaba: uno de $35 de costo terminaba en $220. Debajo de este costo se
     gana una cantidad fija y no se le suma nada, así que sale en $165. */
  bandaBarata: { hasta: 150, ganancia: 130 },
  escalones: [[200, 100], [400, 140], [700, 190], [1200, 260], [Infinity, 340]],
  extraDemanda: [[8, 80], [4, 40]],
  extraAAA: [[1500, 60], [900, 30]],
  extrasAlLleno: 400,           // por debajo de este costo, los extras entran a medias
  pisoPorcentual: 0.15,
  topeVenta: 5000,
  debajoDeStore: 0.90,
  margenAjustado: 0.12,
  tipoCambioRespaldo: 20.310158,
};
// ══════════════════════════════════════════

const LIB = 'https://www.kinguin.net/services/library/api/v1/products/search?';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';

function ganancia(costo, ofertas, listaMXN) {
  if (CFG.bandaBarata && costo <= CFG.bandaBarata.hasta) return CFG.bandaBarata.ganancia;

  let base = CFG.escalones[CFG.escalones.length - 1][1];
  for (const [tope, v] of CFG.escalones) if (costo <= tope) { base = v; break; }

  /* Los extras entran poco a poco: si no, un juego de $151 saltaba de $280 a
     $335 por un peso más de costo. */
  const factor = Math.min(1, costo / CFG.extrasAlLleno);
  let extra = 0;
  for (const [min, v] of CFG.extraDemanda) if ((ofertas || 0) >= min) { extra += v; break; }
  for (const [min, v] of CFG.extraAAA) if ((listaMXN || 0) >= min) { extra += v; break; }

  return Math.max(base + extra * factor, costo * CFG.pisoPorcentual, CFG.gananciaMinima);
}

const redondear = (n) => Math.ceil(n / 5) * 5;

/* Devuelve el precio de venta, o null si este juego no se debe publicar. */
function precioDeVenta(costo, ofertas, listaMXN) {
  let venta = redondear(costo + ganancia(costo, ofertas, listaMXN));
  if (venta > CFG.topeVenta) return { venta: null, motivo: 'pasa del tope de $' + CFG.topeVenta };

  if (listaMXN > 0 && venta >= listaMXN) {
    const rebajado = redondear(listaMXN * CFG.debajoDeStore);
    const minimo = Math.max(CFG.gananciaMinima, costo * CFG.margenAjustado);
    if (rebajado - costo >= minimo) return { venta: rebajado, ajustado: true };
    return { venta: null, motivo: 'no queda debajo del precio de la Microsoft Store' };
  }
  return { venta, ajustado: false };
}

const slugDe = (titulo, edicion) =>
  (titulo + '-' + edicion).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 90);

/* ───────── Géneros ─────────
   Kinguin manda sus géneros por id (FPS, RPG, Carreras…) y las etiquetas de
   IGDB, que van más de modo de juego (multijugador, cooperativo, mundo
   abierto). Se juntan en una lista corta y en español, que es lo que ve el
   cliente en los filtros de la tienda.
   OJO: esta tabla es la misma que la de nucleo.mjs en la carpeta
   vessel-precios. Si cambias una, cambia la otra. */
const GENEROS_ID = {
  1: 'Acción', 2: 'Aventura', 3: 'Estrategia', 4: 'RPG', 5: 'MMO',
  7: 'Carreras', 8: 'Deportes', 9: 'Shooter', 12: 'Simulación',
  16: 'Simulación', 17: 'Indie', 19: 'Casual', 20: 'Puzzle',
  23: 'Mundo abierto', 27: 'Puzzle', 28: 'Terror', 29: 'Plataformas',
  30: 'Aventura', 31: 'Historia', 33: 'Shooter', 34: 'Novela visual',
  35: 'Supervivencia', 37: 'Lucha', 40: 'Hack and slash', 41: 'Cooperativo',
};

const GENEROS_TAG = {
  'multiplayer': 'Multijugador', 'co-operative': 'Cooperativo',
  'single player': 'Un jugador', 'split screen': 'Pantalla dividida',
  'battle royale': 'Battle Royale', 'massively multiplayer online (mmo)': 'MMO',
  'open world': 'Mundo abierto', 'survival': 'Supervivencia', 'horror': 'Terror',
  'sandbox': 'Sandbox', 'science fiction': 'Ciencia ficción', 'fantasy': 'Fantasía',
  'stealth': 'Sigilo', 'warfare': 'Bélico', 'kids': 'Para niños',
  'sport': 'Deportes', 'racing': 'Carreras', 'party': 'Fiesta',
};

function generosDe(p) {
  const a = p.attributes || {};
  const salida = [];
  for (const id of a.genres || []) {
    const g = GENEROS_ID[id];
    if (g && salida.indexOf(g) < 0) salida.push(g);
  }
  for (const t of a.igdbTags || []) {
    const g = GENEROS_TAG[String(t).toLowerCase()];
    if (g && salida.indexOf(g) < 0) salida.push(g);
  }
  return salida;
}

const REG = 'AR|TR|BR|US|EU|UK|GB|IN|MX|CA|AU|DE|NG|EG|SA|ZA|SG|KR|TW|CL|CO|CH|LATAM|NA|ROW|GLOBAL|EMEA|APAC';

function tituloLimpio(nombre) {
  let t = String(nombre);
  t = t.replace(/\s*[-–]?\s*(XBOX|Xbox)\s*(One|Series)[^]*$/i, ' ');
  t = t.replace(/\b(CD Key|Digital Download|Key|Account|PRE-?ORDER|Pre-?purchase)\b/gi, ' ');

  /* Kinguin marca así los códigos que hay que canjear con VPN:
     "Far Cry 6 AR VPN Activated XBOX One CD Key". La línea de los paréntesis
     de abajo solo lo quita cuando viene entre ellos, así que suelto se
     colaba al título de la tienda: llegó a haber 22 fichas publicadas que
     decían "VPN Activated". Eso no puede salir —la región y el VPN son
     información interna, van en vg_xbox_costos— y además partía el catálogo
     en dos: el mismo juego competía consigo mismo y ganaba el peor.
     La MISMA regla está en vessel-precios/nucleo.mjs. Si se cambia una hay
     que cambiar la otra: este cron y esa herramienta hacen el mismo trabajo
     sobre la misma base, y el que corra después manda. */
  t = t.replace(/\bVPN\s*(Activated|Required|Needed|Only)?\b/gi, ' ');

  t = t.replace(new RegExp('\\s+\\b(' + REG + ')\\b\\s*', 'g'), ' ');
  t = t.replace(/\s*\(.*?(key|region|vpn).*?\)\s*/gi, ' ');
  t = t.replace(/^Copy of\s+/i, '');
  return t.replace(/[\s/|-]+$/, '').replace(/\s{2,}/g, ' ').trim();
}

function regionDe(p) {
  const c = (p.attributes.region && p.attributes.region.activationCountries) || [];
  if (c.length > 100) return 'Global';
  if (c.indexOf('MX') >= 0) return 'Latam';
  const uno = { AR: 'Argentina', TR: 'Turquía', BR: 'Brasil', US: 'Estados Unidos', GB: 'Reino Unido', IN: 'India', CA: 'Canadá', AU: 'Australia', DE: 'Alemania', EG: 'Egipto', NG: 'Nigeria', ZA: 'Sudáfrica', SG: 'Singapur', KR: 'Corea', TW: 'Taiwán', CL: 'Chile', CO: 'Colombia', CH: 'Suiza', SA: 'Arabia Saudita' };
  if (c.length === 1) return uno[c[0]] || c[0];
  if (c.length <= 60) return 'Europa';
  return 'Otra región';
}

/* La dirección de la ficha en Kinguin lleva el número del producto delante
   del nombre: /category/122709/cuphead-...  Sin el número contesta con un
   redirección a su página de 404, que es lo que salía al darle a "Comprar".
   La ficha abre ya con la oferta más barata de ese producto seleccionada,
   que es justo la que se usó para calcular el precio. */
function urlDeKinguin(p) {
  const a = p.attributes || {};
  const id = p.externalId;
  const nombre = a.urlKey || '';
  if (id && nombre) return 'https://www.kinguin.net/category/' + id + '/' + nombre;
  if (id) return 'https://www.kinguin.net/category/' + id;
  return 'https://www.kinguin.net/listing?phrase=' + encodeURIComponent(p.name || '') + '&platforms=10,20&hideUnavailable=1&active=1';
}

async function json(url) {
  const r = await fetch(url, { headers: { 'user-agent': UA, accept: 'application/json' } });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function enTanda(items, n, fn) {
  const salida = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (i < items.length) {
      const k = i++;
      try { salida[k] = await fn(items[k], k); } catch (e) { salida[k] = null; }
    }
  }));
  return salida;
}

/* El tipo de cambio que Kinguin le aplica a México, leído de su propia página.
   Si no se puede, se usa el de respaldo: más vale cotizar de más que de menos. */
async function tipoDeCambio() {
  try {
    const r = await fetch('https://www.kinguin.net/listing?platforms=20&size=1', {
      headers: { 'user-agent': UA, 'accept-language': 'es-MX,es;q=0.9' },
    });
    const h = await r.text();
    const i = h.indexOf('window._preloadedState');
    if (i < 0) return CFG.tipoCambioRespaldo;
    const s = h.indexOf('=', i) + 1, e = h.indexOf('</script>', s);
    const j = JSON.parse(h.slice(s, e).trim().replace(/;\s*$/, ''));
    const c = j && j.currencies && j.currencies.current;
    return (c && c.code === 'MXN' && c.rate) ? c.rate : CFG.tipoCambioRespaldo;
  } catch (e) { return CFG.tipoCambioRespaldo; }
}

/* Convierte productos crudos de Kinguin en {slug: {costoBase, ofertas, …}},
   quedándose siempre con la oferta más barata de cada juego. */
function agrupar(crudos, tipoCambio) {
  const mapa = new Map();
  for (const p of crudos) {
    const a = p.attributes || {};
    if (a.marketingProductType !== 'GAME') continue;
    if (!p.active || !p.visible || p.isDeleted) continue;
    const centavos = (p.price && p.price.calculated) || 0;
    if (centavos < 100) continue;
    if (/beta|early access|\bdemo\b/i.test(p.name)) continue;

    const titulo = tituloLimpio(p.name);
    if (titulo.length < 3) continue;
    const edicion = a.edition || 'Standard';
    const slug = slugDe(titulo, edicion);
    const costoBase = (centavos / 100) * tipoCambio;

    const previo = mapa.get(slug);
    if (!previo) {
      mapa.set(slug, {
        slug, titulo, edicion, costoBase, ofertas: 1,
        generos: generosDe(p),
        region: regionDe(p),
        url: urlDeKinguin(p),
        plataforma: ((a.platforms || []).indexOf('20') >= 0 && (a.platforms || []).indexOf('10') >= 0)
          ? 'Xbox One / Series' : (a.platform === 20 ? 'Xbox Series' : 'Xbox One'),
        portada: p.coverImageUrl || p.hiImageUrl || p.imageUrl || '',
      });
    } else {
      previo.ofertas++;
      /* Los géneros se juntan de todas las ofertas del mismo juego: unas los
         traen y otras no. */
      for (const g of generosDe(p)) if (previo.generos.indexOf(g) < 0) previo.generos.push(g);
      if (costoBase < previo.costoBase) {
        previo.costoBase = costoBase;
        previo.region = regionDe(p);
        previo.url = urlDeKinguin(p);
      }
    }
  }
  return mapa;
}

/* Baja el catálogo Xbox entero de Kinguin.
 *
 * Kinguin no devuelve más de 10,000 productos por consulta y su catálogo de
 * Xbox tiene unos 26,000: pidiendo "todo lo de Xbox One" se veía el 38% y
 * faltaban juegos tan normales como el GTA Trilogy. Partiendo por bandas de
 * precio ninguna llega al tope. Los números van en céntimos de euro. */
const BANDAS = [
  [0, 200], [200, 400], [400, 700], [700, 1200],
  [1200, 2000], [2000, 3500], [3500, 6000], [6000, 999999],
];

async function bajarCatalogo(concurrencia) {
  const vistos = new Set();
  const crudos = [];

  function guardar(lote) {
    for (const p of lote || []) {
      if (!p || vistos.has(p.id)) continue;   // el mismo producto sale en las dos plataformas
      vistos.add(p.id);
      crudos.push(p);
    }
  }

  const trabajos = [];
  for (const plat of [10, 20]) for (const b of BANDAS) trabajos.push({ plat, desde: b[0], hasta: b[1] });

  await enTanda(trabajos, 4, async (t) => {
    const base = LIB + 'platforms=' + t.plat + '&size=100&priceFrom=' + t.desde + '&priceTo=' + t.hasta;
    let total = 0;
    try {
      const primera = await json(base + '&page=0');
      total = (primera.page && primera.page.totalElements) || 0;
      guardar(primera._embedded && primera._embedded.products);
    } catch (e) { return; }

    const paginas = Math.min(Math.ceil(total / 100), 100) - 1;
    if (paginas <= 0) return;
    const lotes = await enTanda(Array.from({ length: paginas }, (_, i) => i + 1), concurrencia, async (p) => {
      const j = await json(base + '&page=' + p);
      return (j._embedded && j._embedded.products) || [];
    });
    for (const l of lotes) guardar(l);
  });

  return crudos;
}

/* ───────── Microsoft: lo que cuesta HOY en la tienda de Xbox México ─────────
 *
 * Devuelve el precio que de verdad se paga, no el de lista. Microsoft manda
 * los dos: MSRP es el tachado y ListPrice el vigente. Battlefield 6 Phantom
 * estaba a 1,999 de lista y 1,299 por rebaja, y mirar el de lista dejaba
 * publicarlo a 1,390 —más caro que la propia tienda de Xbox—.
 *
 * Las rebajas de Microsoft duran días, así que esto se relee en cada repaso:
 * un juego que hoy no conviene puede convenir la semana que viene, y al revés.
 */
const MS_CATALOGO = 'https://displaycatalog.mp.microsoft.com/v7.0/';

async function preciosDeMicrosoft(ids) {
  const precios = {};
  const limpios = [...new Set((ids || []).filter(Boolean))];
  const bloques = [];
  for (let i = 0; i < limpios.length; i += 20) bloques.push(limpios.slice(i, i + 20));

  /* Se reintenta lo que falle. enTanda se traga los errores, y estas
     consultas van de veinte en veinte: cuando una se caía, esos veinte
     juegos se quedaban sin precio de la Store y pasaban sin comprobar que no
     salieran más caros que Microsoft. Una auditoría encontró 23 publicados
     por encima del precio oficial justo por esto, uno a $4,065 contra $999. */
  let fallidos = 0;
  await enTanda(bloques, 8, async (bloque) => {
    let r = null;
    for (let intento = 0; intento < 3 && !r; intento++) {
      try {
        r = await json(`${MS_CATALOGO}products?bigIds=${bloque.join(',')}&market=MX&languages=es-MX&MS-CV=DGU1mcuYo0WMMp%2BF.1`);
      } catch (e) {
        if (intento === 2) { fallidos++; return; }
        await new Promise((ok) => setTimeout(ok, 400 * (intento + 1)));
      }
    }
    if (!r) { fallidos++; return; }
    for (const prod of r.Products || []) {
      let ahora = 0;
      for (const s of prod.DisplaySkuAvailabilities || []) {
        for (const av of s.Availabilities || []) {
          const p = av.OrderManagementData && av.OrderManagementData.Price;
          if (!p || p.CurrencyCode !== 'MXN') continue;
          const efectivo = p.ListPrice || p.MSRP || 0;
          if (efectivo > 0 && (ahora === 0 || efectivo < ahora)) ahora = efectivo;
        }
      }
      if (ahora > 0) precios[prod.ProductId] = Math.round(ahora);
    }
  });
  /* Se avisa de lo que se perdió: un precio que falta no es un precio
     bueno, y el resumen del panel debe poder decirlo. */
  if (fallidos) precios.__fallidos = fallidos;
  return precios;
}

/* ───────── Encontrar la ficha de Microsoft por el nombre ─────────

   El panel enseña el precio de la Xbox Store leyendo ms_id, y 390 juegos de
   la tienda no tienen ninguno: a ésos el panel no les enseñaba precio y no
   había forma de saber si estaban por debajo de la tienda oficial o no.
   Aquí se busca la ficha en el momento, igual que hace la herramienta de la
   PC (vessel-precios/nucleo.mjs). Las reglas de abajo son LAS MISMAS que las
   de ese archivo: si cambias una, cambia la otra, o cada uno emparejará los
   juegos con una ficha distinta.

   Lo que NO hace: tocar la portada. Emparejar por nombre fue lo que cruzó
   328 carátulas entre juegos de la misma saga. De aquí solo sale el número
   de la ficha y el precio; la foto se queda como está. */
const EDICIONES = /\b(standard|deluxe|gold|ultimate|premium|complete|legendary|definitive|goty|game of the year|digital|collector'?s?|anniversary|special|enhanced|vault|legend|tournament|super deluxe|year \d|edici[oó]n|est[aá]ndar|completa?|definitiva|mejorada|especial|coleccionista)\b/gi;
const sinEdicion = (t) => String(t).replace(EDICIONES, ' ').replace(/\bedition\b/gi, ' ').replace(/[-–:+]\s*$/, '').replace(/\s{2,}/g, ' ').trim();
const norm = (s) => String(s).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();

function parecido(a, b) {
  const A = new Set(norm(a).split(' ')), B = new Set(norm(b).split(' '));
  let inter = 0;
  for (const w of A) if (B.has(w)) inter++;
  return inter / Math.max(A.size, B.size);
}

/* Palabras que NO distinguen un juego de otro dentro de una misma saga. */
const RELLENO = new Set([
  'the', 'of', 'and', 'a', 'an', 'for', 'de', 'del', 'la', 'el', 'y', 'para',
  'game', 'games', 'xbox', 'one', 'series', 'pc', 'windows',
  'bundle', 'pack', 'lote', 'edition', 'ed', 'remaster', 'remastered', 'hd',
  'cross', 'gen', 'crossgen', 'multigeneracion', 'plus', 'contiene',
  'vpn', 'activated', 'required', 'needed', 'only',
]);

const NUMEROS = {
  one: '1', two: '2', three: '3', four: '4', five: '5',
  six: '6', seven: '7', eight: '8', nine: '9', ten: '10',
  dos: '2', tres: '3', cuatro: '4', cinco: '5',
};

/* La 'x' NO está aquí a propósito: "Mega Man X" y "Mega Man 10" son dos
   juegos distintos, y convertirla los haría iguales. */
const ROMANOS = {
  i: '1', ii: '2', iii: '3', iv: '4', v: '5', vi: '6', vii: '7',
  viii: '8', ix: '9', xi: '11', xii: '12', xiii: '13',
};

function fichas(t) {
  return norm(sinEdicion(t)).split(' ')
    .map((w) => NUMEROS[w] || w)
    .filter((w) => w && !RELLENO.has(w))
    .map((w) => ROMANOS[w] || w);
}

/* Microsoft mezcla el juego con sus añadidos, y colarse en un DLC trae el
   precio de lista del DLC, que es el que decide si el juego se puede
   publicar. */
const NO_ES_EL_JUEGO = /\b(dlc|contenido extra|mejora|complemento|pase de temporada|season pass|add-?on|upgrade|demo|trial|prueba)\b/i;

function mismoJuego(nuestro, suyo) {
  if (NO_ES_EL_JUEGO.test(suyo) && !NO_ES_EL_JUEGO.test(nuestro)) return false;
  const A = fichas(nuestro), B = fichas(suyo);
  if (!A.length || !B.length) return false;
  if (A.slice().sort().join(' ') === B.slice().sort().join(' ')) return true;
  /* "Far Cry 6" y "FARCRY 6": las mismas letras, distinto espaciado. */
  return A.join('') === B.join('');
}

/* Una edición cara no vale por la normal. "TopSpin 2K25" a secas emparejó
   con la "Edición Deluxe" de Microsoft, que cuesta más: sinEdicion() quita
   la palabra de los dos lados, así que para mismoJuego() eran el mismo. El
   daño es doble —enseñas un precio oficial que no es el de tu juego, y como
   es más alto, la regla que impide vender por encima de la tienda se relaja
   justo donde debería apretar—. Si lo nuestro es la normal, la suya también
   tiene que serlo. Al revés no se mira: cuando sí vendemos una edición
   especial, Microsoft la nombra de mil maneras ("Ultimate" es "Edición
   digital definitiva") y exigir la palabra exacta dejaría fuera aciertos. */
const EDICION_CARA = /\b(deluxe|ultimate|premium|gold|complete|completa|definitive|definitiva|collector|coleccionista|goty|legendary|legendaria|anniversary|aniversario)\b/;

function edicionQueNoEs(nuestroTitulo, nuestraEdicion, suyo) {
  const ed = norm(nuestraEdicion || '');
  const somosNormales = !ed || ed === 'standard' || ed === 'estandar';
  const suyoNorm = norm(suyo);
  if (somosNormales) {
    if (EDICION_CARA.test(norm(nuestroTitulo))) return false;
    return EDICION_CARA.test(suyoNorm);
  }
  /* Y al revés. "NBA 2K25: Tournament Edition" emparejaba con la "NBA 2K25
     Edición Estándar" de Microsoft, que cuesta menos: sinEdicion() quita la
     palabra de los dos lados y para mismoJuego() eran iguales. Comparar una
     edición cara contra el precio de la normal la obliga a bajar de un
     precio que no es el suyo, y acaba escondida sin motivo. Cuando la suya
     dice "estándar" con todas las letras, no es la nuestra.

     Solo se mira esa palabra, no la ausencia de la nuestra: Microsoft
     nombra las ediciones especiales de mil maneras —"Ultimate" es "Edición
     digital definitiva"— y exigir la palabra exacta tiraría aciertos. */
  return /\b(estandar|standard)\b/.test(suyoNorm);
}

/* El buscador de Microsoft es caprichoso: "Battlefield" devuelve diez juegos
   pero "Battlefield 6" devuelve cero. Se prueba de lo más preciso a lo más
   general y se elige el que más se parezca. */
function consultas(titulo) {
  const base = sinEdicion(titulo);
  const palabras = base.split(/\s+/).filter(Boolean);
  const salida = [titulo, base, palabras.slice(0, 2).join(' '), palabras[0]];
  return salida.filter((v, i, a) => v && v.length >= 3 && a.indexOf(v) === i);
}

async function buscarEnMicrosoft(titulo, edicion) {
  if (!titulo) return null;
  let mejor = null, score = 0;
  for (const intento of consultas(titulo)) {
    try {
      const r = await json(MS_CATALOGO + 'productFamilies/autosuggest?market=MX&languages=es-MX&productFamilyNames=Games&query=' + encodeURIComponent(intento.slice(0, 60)));
      for (const grupo of r.Results || []) {
        for (const c of grupo.Products || []) {
          if (!mismoJuego(titulo, c.Title)) continue;
          if (edicionQueNoEs(titulo, edicion, c.Title)) continue;
          let s = parecido(titulo, c.Title);
          /* Entre "Diablo IV Deluxe" y "Diablo IV Standard" hay que quedarse
             con la que estamos vendiendo, que es la que cuesta lo mismo. */
          const ed = String(edicion || '').toLowerCase();
          if (ed && ed !== 'standard' && norm(c.Title).includes(norm(ed))) s += 0.15;
          if (s > score) { score = s; mejor = c; }
        }
      }
      if (score >= 0.75) break;
    } catch (e) { /* se prueba la siguiente */ }
  }
  if (!mejor || score < 0.45) return null;
  return { id: mejor.ProductId, titulo: mejor.Title, parecido: Number(score.toFixed(2)) };
}

/* Busca un juego suelto por nombre. Para el botón de "precio de ahora". */
async function buscarUno(frase) {
  const j = await json(LIB + 'phrase=' + encodeURIComponent(frase) + '&platforms=10,20&size=100');
  return (j._embedded && j._embedded.products) || [];
}

/* ───────── Supabase por REST, sin librerías ───────── */
function supa(ruta, opciones) {
  const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '') + '/rest/v1/' + ruta;
  const key = process.env.SUPABASE_SERVICE_KEY || '';
  const cab = Object.assign({
    apikey: key,
    Authorization: 'Bearer ' + key,
    'Content-Type': 'application/json',
  }, (opciones && opciones.headers) || {});
  return fetch(url, Object.assign({}, opciones, { headers: cab })).then(async (r) => {
    const t = await r.text();
    if (!r.ok) throw new Error('Supabase ' + r.status + ': ' + t.slice(0, 160));
    return t ? JSON.parse(t) : null;
  });
}

/* ¿Quien llama es el administrador? Se le pregunta a la propia base con el
   token de sesión de quien hace la llamada: si is_admin() dice que sí, es que
   sí. Aquí no se guarda ninguna contraseña ni se confía en el navegador. */
const limpia = (v) => String(v == null ? '' : v).trim().replace(/^["']|["']$/g, '');
const tieneRaros = (v) => /[^\x20-\x7E]/.test(String(v || ''));

async function esAdmin(req) {
  const auth = req.headers.authorization || '';
  const token = limpia(auth.replace(/^Bearer\s+/i, ''));
  if (!token) {
    return { ok: false, motivo: 'El navegador no mandó tu sesión. Sal del panel y vuelve a entrar.' };
  }

  /* La llave del portero. Antes solo se miraba SUPABASE_ANON_KEY, y si esa
     variable faltaba en Vercel, Supabase rechazaba la llamada y la función
     te tomaba por desconocido aunque tu sesión fuera buena. Sirve igual la
     service_role: quien decide el rol es el token de arriba, no ésta.

     Y se limpian: un valor pegado con espacios o con un salto de línea al
     final rompe la llamada entera, y el error que salía —"no se pudo hablar
     con Supabase"— no decía por dónde. */
  const anon = limpia(process.env.SUPABASE_ANON_KEY);
  const servicio = limpia(process.env.SUPABASE_SERVICE_KEY);
  const clave = anon || servicio;
  if (!clave) {
    return { ok: false, motivo: 'A Vercel le faltan SUPABASE_ANON_KEY y SUPABASE_SERVICE_KEY.' };
  }

  /* Una llave con un carácter raro —comillas curvas, un guion largo, un
     acento -- hace que la llamada ni salga. Se dice cuál es la mala para no
     tener que adivinar. */
  const malas = [];
  if (anon && tieneRaros(anon)) malas.push('SUPABASE_ANON_KEY');
  if (servicio && tieneRaros(servicio)) malas.push('SUPABASE_SERVICE_KEY');
  if (tieneRaros(token)) malas.push('tu sesión del navegador');
  if (malas.length) {
    return {
      ok: false,
      motivo: 'Hay caracteres raros en ' + malas.join(' y ') + '. Suele pasar al pegar el valor con comillas o espacios: bórrala en Vercel y pégala de nuevo, sin comillas.',
    };
  }

  const url = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '') + '/rest/v1/rpc/is_admin';
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { apikey: clave, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (!r.ok) {
      const detalle = (await r.text()).slice(0, 120);
      return { ok: false, motivo: 'Supabase rechazó la sesión (' + r.status + '). ' + detalle };
    }
    if ((await r.json()) === true) return { ok: true };
    return { ok: false, motivo: 'Tu usuario existe pero no tiene is_admin en vg_users.' };
  } catch (e) {
    return { ok: false, motivo: 'No se pudo hablar con Supabase: ' + String(e.message).slice(0, 220) };
  }
}

module.exports = {
  CFG, ganancia, redondear, precioDeVenta, slugDe,
  tipoDeCambio, agrupar, bajarCatalogo, buscarUno, enTanda,
  preciosDeMicrosoft, buscarEnMicrosoft, supa, esAdmin,
};
