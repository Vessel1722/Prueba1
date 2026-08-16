-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 78 — La analítica, ahora sí
--
-- La fase 77 dijo OK y la tabla siguió abierta. El fallo fue de la
-- comprobación, no tuyo: miraba que EXISTIERA la política correcta,
-- pero no que no existiera otra permisiva al lado. Como las reglas de
-- fila se suman (basta que UNA deje pasar), la buena no sirve de nada
-- mientras siga viva la mala.
--
-- vg_analytics_events se creó a mano desde el panel de Supabase, y el
-- asistente de ese panel suele dejar puesta una regla del tipo
-- "Enable all access". La fase 77 solo borró las reglas por el nombre
-- que ella misma les daba, así que esa otra ni se enteró.
--
-- Comprobado en vivo después de correr la fase 77, sin sesión:
--   · Leer:  13.766 filas, con ciudad, país y qué miró cada visitante.
--   · Borrar: se insertó una fila de prueba y se borró sin cuenta.
--            content-range devolvió */1 — una fila borrada de verdad.
--            (La fila era de la propia prueba y ya no está.)
--
-- O sea que cualquiera con la clave pública —que está en el HTML,
-- porque tiene que estar— podía vaciarte la analítica entera.
--
-- Aquí no se borra por nombre: se borran TODAS las reglas de esa tabla
-- y se ponen las dos que hacen falta. Y la comprobación del final ya
-- mira lo que hay que mirar.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- 1. ANTES DE NADA — mira qué hay puesto ahora
--
--    Esta consulta no cambia nada. Enseña, de todo el esquema, qué
--    reglas dejan entrar a "anon" (la clave pública del navegador) y
--    para qué operación. Lo que salga con cmd = ALL, DELETE o UPDATE
--    hay que mirarlo con lupa: significa que alguien sin cuenta puede
--    escribir o borrar ahí.
--
--    Guarda el resultado antes de correr el resto, para poder comparar.
-- ═══════════════════════════════════════════════════════════════════

select tablename          as tabla,
       policyname         as regla,
       cmd                as operacion,
       roles::text        as para_quien,
       coalesce(qual, '(sin condición)')       as condicion_lectura,
       coalesce(with_check, '(sin condición)') as condicion_escritura,
       case
         when cmd in ('ALL','DELETE','UPDATE','INSERT')
              and roles::text like '%anon%'
           then '⚠️ ESCRITURA SIN CUENTA'
         when cmd = 'SELECT' and roles::text like '%anon%'
              and coalesce(qual,'true') = 'true'
           then 'lectura pública — ¿es a propósito?'
         else 'ok'
       end as aviso
  from pg_policies
 where schemaname = 'public'
   and roles::text like '%anon%'
 order by
   case when cmd in ('ALL','DELETE','UPDATE','INSERT') then 0 else 1 end,
   tablename, policyname;


-- ═══════════════════════════════════════════════════════════════════
-- 2. Fuera TODAS las reglas de la tabla de analítica
--
--    Se recorren y se borran una a una, se llamen como se llamen.
--    Esta es la diferencia con la fase 77: allí se borraban por
--    nombre, y a la que había puesto el panel no le tocaba.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  for r in
    select policyname
      from pg_policies
     where schemaname = 'public' and tablename = 'vg_analytics_events'
  loop
    execute format('drop policy if exists %I on public.vg_analytics_events', r.policyname);
    raise notice 'Regla borrada: %', r.policyname;
  end loop;
end $$;

alter table public.vg_analytics_events enable row level security;

-- Y que no se pueda saltar: sin esto, el dueño de la tabla se salta
-- sus propias reglas, y varias funciones corren como dueño.
alter table public.vg_analytics_events force row level security;


-- ── Las dos únicas reglas que necesita ──
--
--    Escribir: cualquiera, con cuenta o sin ella. Un visitante que aún
--    no se ha registrado también cuenta para la analítica.
create policy analytics_insert on public.vg_analytics_events
  for insert to anon, authenticated
  with check (true);

--    Leer: solo el administrador, que es quien mira el panel.
create policy analytics_select on public.vg_analytics_events
  for select to authenticated
  using (public.is_admin());

--    Editar y borrar: NADIE desde el navegador. Al no haber regla
--    para esas operaciones, quedan cerradas para todo el mundo. Si
--    algún día hay que limpiar eventos viejos, se hace desde el panel
--    de Supabase o con una función SECURITY DEFINER, no desde la web.


-- ═══════════════════════════════════════════════════════════════════
-- 3. Lo mismo para el catálogo de Xbox
--
--    Esta también se creó a mano. La lectura pública sí es a propósito
--    (son productos en venta), pero conviene que no arrastre ninguna
--    regla suelta de escritura.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  for r in
    select policyname
      from pg_policies
     where schemaname = 'public' and tablename = 'vg_xbox_games'
  loop
    execute format('drop policy if exists %I on public.vg_xbox_games', r.policyname);
  end loop;
end $$;

alter table public.vg_xbox_games enable row level security;
alter table public.vg_xbox_games force row level security;

create policy xbox_lee on public.vg_xbox_games
  for select to anon, authenticated using (true);

create policy xbox_admin on public.vg_xbox_games
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ═══════════════════════════════════════════════════════════════════
-- 4. Una red que se pone sola: nada de escribir sin cuenta
--
--    Este bloque recorre TODAS las tablas del esquema y quita el
--    permiso de escritura a "anon" allí donde alguien lo haya dejado
--    puesto sin querer. No toca lecturas ni toca a los usuarios con
--    sesión: solo cierra la escritura anónima, que nunca debería
--    existir salvo en la analítica, que se vuelve a crear justo abajo.
--
--    Si prefieres mirar antes y decidir tú, comenta este bloque y
--    quédate con la consulta del punto 1.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record; v_n integer := 0;
begin
  for r in
    select tablename, policyname, cmd
      from pg_policies
     where schemaname = 'public'
       and roles::text like '%anon%'
       and cmd in ('ALL','INSERT','UPDATE','DELETE')
       and not (tablename = 'vg_analytics_events' and policyname = 'analytics_insert')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
    raise notice 'Escritura anónima retirada: %.% (%)', r.tablename, r.policyname, r.cmd;
    v_n := v_n + 1;
  end loop;
  raise notice 'Reglas de escritura anónima retiradas: %', v_n;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 5. RESULTADO — esta vez comprueba lo que hay que comprobar
--
--    La fase 77 preguntaba "¿existe la regla buena?". Eso siempre
--    daba OK. Lo que hay que preguntar es "¿queda alguna mala?".
-- ═══════════════════════════════════════════════════════════════════

select 'Analítica: nadie la lee sin ser admin' as que,
  (select count(*)::text from pg_policies
    where schemaname='public' and tablename='vg_analytics_events') || ' reglas en total' as detalle,
  case when (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_analytics_events'
                and cmd in ('SELECT','ALL') and roles::text like '%anon%') = 0
        and (select relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relname='vg_analytics_events')
       then 'OK' else 'REVISAR' end as resultado
union all
select 'Analítica: nadie la borra',
  'reglas DELETE/UPDATE/ALL',
  case when (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_analytics_events'
                and cmd in ('DELETE','UPDATE','ALL')) = 0
       then 'OK' else 'REVISAR' end
union all
select 'Analítica: la página sigue pudiendo apuntar',
  'regla analytics_insert',
  case when (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_analytics_events'
                and cmd='INSERT' and roles::text like '%anon%') = 1
       then 'OK' else 'REVISAR' end
union all
select 'Xbox: lectura pública, escritura de admin',
  (select count(*)::text from pg_policies
    where schemaname='public' and tablename='vg_xbox_games') || ' reglas',
  case when (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_xbox_games'
                and cmd in ('ALL','INSERT','UPDATE','DELETE')
                and roles::text like '%anon%') = 0
       then 'OK' else 'REVISAR' end
union all
select 'En todo el esquema: nadie escribe sin cuenta',
  (select count(*)::text from pg_policies
    where schemaname='public' and roles::text like '%anon%'
      and cmd in ('ALL','INSERT','UPDATE','DELETE')) || ' reglas de escritura anónima',
  case when (select count(*) from pg_policies
              where schemaname='public' and roles::text like '%anon%'
                and cmd in ('ALL','INSERT','UPDATE','DELETE')
                and not (tablename='vg_analytics_events' and cmd='INSERT')) = 0
       then 'OK' else 'REVISAR' end
union all
select 'Ninguna tabla sin reglas de fila',
  (select count(*)::text from pg_tables t
    where t.schemaname='public'
      and not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                       where n.nspname='public' and c.relname=t.tablename and c.relrowsecurity))
    || ' tablas abiertas',
  case when (select count(*) from pg_tables t
              where t.schemaname='public'
                and not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                                 where n.nspname='public' and c.relname=t.tablename and c.relrowsecurity)) = 0
       then 'OK' else 'REVISAR' end;


-- ═══════════════════════════════════════════════════════════════════
-- 6. Y una última, para leer con calma
--
--    Deja a la vista qué puede hacer un visitante sin cuenta en cada
--    tabla. Lo normal es ver solo SELECT en el catálogo y el INSERT
--    de la analítica. Cualquier otra cosa, a mirar.
-- ═══════════════════════════════════════════════════════════════════

select tablename as tabla,
       string_agg(distinct cmd, ', ' order by cmd) as que_puede_hacer_sin_cuenta
  from pg_policies
 where schemaname = 'public' and roles::text like '%anon%'
 group by tablename
 order by tablename;
