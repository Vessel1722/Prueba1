-- ═══════════════════════════════════════════════════════════════════
--  FASE 82 — Cuentas y Streaming pasan a ser una sola sección
-- ═══════════════════════════════════════════════════════════════════
--
--  Cuentas nunca fue otra cosa que streaming: las dos secciones vendían
--  Netflix, MAX, Disney+, VIX+, Viki y Crunchyroll, unas veces por perfil
--  y otras la cuenta completa. El cliente tenía que salir de una pestaña
--  y entrar en la otra para comparar dos formas de comprar lo mismo.
--
--  Ahora cada servicio es UNA ficha y la forma de comprarlo es una opción
--  dentro de ella:
--
--      Netflix
--        · Perfil 1 Mes ....... $90
--        · Perfil 2 Meses ..... $170
--        · Cuenta Completa .... $245
--
--  Ningún precio cambia. Lo único que cambia es dónde vive cada opción.
--
--  IMPORTANTE — por qué hace falta este archivo:
--  el catálogo que ve la tienda NO es el array del index.html, es esta
--  tabla. El HTML ya quedó fusionado, pero mientras estas filas digan lo
--  de antes, la tienda seguirá pintando "Perfil Netflix" y "Netflix
--  Nueva" por separado, porque las filas de Supabase pisan al array.
--
--  Las 7 filas que se fusionaron NO se borran: se marcan active=false.
--  Así se puede deshacer todo poniéndolas en true otra vez. Cuando
--  lleves un tiempo con esto y no lo eches de menos, bórralas a mano
--  desde el panel de Catálogo.
--
--  Cómo se corre: Supabase → SQL Editor → pegar todo → Run.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- ── 1 · Netflix: perfil + cuenta completa ──────────────────────────
update public.products set
  title         = 'Netflix',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Perfil 1 Mes $90 · Cuenta Completa $245',
  price_label   = '$90 MXN',
  options       = '[{"name":"Perfil 1 Mes","price":90},
                    {"name":"Perfil 2 Meses","price":170},
                    {"name":"Cuenta Completa","price":245}]'::jsonb
where legacy_id = '8';

-- ── 2 · MAX: perfiles + cuenta Platino ─────────────────────────────
update public.products set
  title         = 'MAX',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Perfil 1 Mes $50 · Cuenta Platino $100',
  price_label   = '$50 MXN',
  options       = '[{"name":"Perfil 1 Mes","price":50},
                    {"name":"Perfil 3 Meses","price":125},
                    {"name":"Perfil 6 Meses","price":240},
                    {"name":"Perfil 12 Meses","price":450},
                    {"name":"Cuenta Completa Platino","price":100}]'::jsonb
where legacy_id = '10';

-- ── 3 · Disney+: perfiles + cuenta con ESPN ────────────────────────
update public.products set
  title         = 'Disney+',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Perfil 1 Mes $50 · Cuenta Completa + ESPN $170',
  price_label   = '$50 MXN',
  options       = '[{"name":"Perfil 1 Mes","price":50},
                    {"name":"Perfil 3 Meses","price":135},
                    {"name":"Perfil 6 Meses","price":260},
                    {"name":"Cuenta Completa + ESPN","price":170}]'::jsonb
where legacy_id = '11';

-- ── 4 · Crunchyroll: aquí se juntan TRES fichas ────────────────────
--  Eran "Crunchyroll Fijo", "Crunchyroll Renovable" y "Crunchyroll
--  (Renovación)". Es el mismo servicio con tres formas de comprarlo,
--  así que el nombre de cada opción dice cuál es cuál.
update public.products set
  title         = 'Crunchyroll',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Perfil Fijo 1 Mes $60 · Perfil Renovable 1 Mes $75 · Cuenta Completa 1 Mes $130',
  price_label   = '$60 MXN',
  options       = '[{"name":"Perfil Fijo 1 Mes","price":60},
                    {"name":"Perfil Fijo 3 Meses","price":150},
                    {"name":"Perfil Fijo 6 Meses","price":275},
                    {"name":"Perfil Renovable 1 Mes","price":75},
                    {"name":"Perfil Renovable 3 Meses","price":170},
                    {"name":"Perfil Renovable 6 Meses","price":315},
                    {"name":"Perfil Renovable 12 Meses","price":590},
                    {"name":"Cuenta Completa 1 Mes","price":130},
                    {"name":"Cuenta Completa 12 Meses","price":1120}]'::jsonb
where legacy_id = '12';

-- ── 5 · Viki Rakuten: perfiles + cuenta nueva ──────────────────────
update public.products set
  title         = 'Viki Rakuten',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Perfil 1 Mes $50 · Cuenta Nueva $70',
  price_label   = '$50 MXN',
  options       = '[{"name":"Perfil 1 Mes","price":50},
                    {"name":"Perfil 3 Meses","price":90},
                    {"name":"Cuenta Nueva","price":70}]'::jsonb
where legacy_id = '14';

-- ── 6 · VIX+: perfiles + cuenta completa ───────────────────────────
update public.products set
  title         = 'VIX+',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Perfil 1 Mes $50 · Cuenta Completa $90',
  price_label   = '$50 MXN',
  options       = '[{"name":"Perfil 1 Mes","price":50},
                    {"name":"Perfil 3 Meses","price":115},
                    {"name":"Perfil 6 Meses","price":200},
                    {"name":"Perfil 12 Meses","price":350},
                    {"name":"Cuenta Completa","price":90}]'::jsonb
where legacy_id = '16';

-- ── 7 · Spotify: no tenía perfil con el que fusionarse ─────────────
--  Se queda como ficha propia, solo se muda a Streaming y los nombres
--  de las opciones dicen que son cuenta, no perfil.
update public.products set
  title         = 'Spotify',
  category      = 'streaming',
  category_name = 'Streaming',
  description   = 'Cuenta Nueva 1 Mes $80 · Cuenta Nueva 3 Meses $165',
  options       = '[{"name":"Cuenta 1 Mes","price":80},
                    {"name":"Cuenta 3 Meses","price":165}]'::jsonb
where legacy_id = '29';

-- ── 8 · YouTube Premium: igual, solo se muda ───────────────────────
update public.products set
  category      = 'streaming',
  category_name = 'Streaming'
where legacy_id = '31';

-- ── 9 · Las 7 fichas que ya viven dentro de otra ───────────────────
--  13 Crunchyroll Renovable ....→ opciones "Perfil Renovable" de la 12
--  24 Netflix Nueva ............→ "Cuenta Completa" de la 8
--  25 VIX Nueva ................→ "Cuenta Completa" de la 16
--  26 Disney + ESPN ............→ "Cuenta Completa + ESPN" de la 11
--  27 MAX Platino ..............→ "Cuenta Completa Platino" de la 10
--  28 Viki Rakuten Nueva .......→ "Cuenta Nueva" de la 14
--  30 Crunchyroll (Renovación) .→ opciones "Cuenta Completa" de la 12
update public.products set
  active   = false,
  category = 'streaming'
where legacy_id in ('13','24','25','26','27','28','30');

-- ── 10 · Red de seguridad ──────────────────────────────────────────
--  Cualquier producto que siguiera en 'cuentas' (uno creado a mano
--  desde el panel, por ejemplo) se quedaría sin pestaña donde salir,
--  porque esa sección ya no existe en la tienda.
update public.products set
  category      = 'streaming',
  category_name = 'Streaming'
where category = 'cuentas';

commit;

-- ═══════════════════════════════════════════════════════════════════
--  Comprobación — esto es lo que debería devolver
-- ═══════════════════════════════════════════════════════════════════
--  Ni una fila con category = 'cuentas':
select count(*) as quedan_en_cuentas
from public.products
where category = 'cuentas';

--  Y la sección Streaming, ficha por ficha, con sus opciones:
select legacy_id,
       title,
       price_label,
       jsonb_array_length(options) as opciones,
       (select string_agg(o->>'name' || ' $' || (o->>'price'), ' · ')
          from jsonb_array_elements(options) o) as detalle
from public.products
where category = 'streaming' and active
order by sort_order;
