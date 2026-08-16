-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 79 — Las tablas viejas que nadie apagó
--
-- La fase 78 cerró la analítica y de paso dejó a la vista la lista de
-- lo que puede leer un visitante sin cuenta. Ahí aparecieron cuatro
-- tablas que NO están en ninguno de los 35 archivos SQL del proyecto:
-- se crearon a mano, en su día, y se quedaron ahí cuando el código
-- pasó a usar otras.
--
-- Comprobado en vivo, sin sesión, con la clave pública:
--
--   · order_messages    22 mensajes de pedidos, con user_id, el
--                       nombre de quien escribe, el texto y el
--                       adjunto. Conversaciones reales.
--   · vg_chat_messages  12 mensajes más, del chat viejo, con
--                       sender_phone incluido.
--   · vg_token_log      20 movimientos de tokens con el user_id de
--                       cada cliente.
--   · vg_support_messages  vacía, pero abierta igual.
--
-- Ninguna de las cuatro la usa ya el sitio salvo dos rastros de
-- código viejo, que siguen funcionando con las reglas de abajo.
--
-- El catálogo y la configuración (products, products_admin,
-- hero_offer, vg_xbox_games, vg_token_config, vg_token_rewards,
-- vg_site_config, vg_horario) también se leen sin cuenta, y eso está
-- BIEN: son los productos y los precios de una tienda abierta. Se
-- revisó su contenido y no hay nada que no deba verse.
--
-- Aquí no se borra nada. Se cierran. Al final del archivo está el
-- borrado, comentado, para cuando decidas.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- 1. order_messages — el chat de pedidos, versión vieja
--
--    Todavía la lee un rastro del código: fetchMessages() la consulta
--    si falla la tabla nueva (index.html, bloque vg-v10-clean-rebuild).
--    Por eso no se cierra del todo: se deja que cada quien vea los
--    mensajes de SUS pedidos, que es lo que ese código necesita, y
--    nadie vea los de los demás.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  if to_regclass('public.order_messages') is null then
    raise notice 'order_messages no existe, se salta';
    return;
  end if;

  for r in select policyname from pg_policies
            where schemaname='public' and tablename='order_messages'
  loop
    execute format('drop policy if exists %I on public.order_messages', r.policyname);
  end loop;

  execute 'alter table public.order_messages enable row level security';
  execute 'alter table public.order_messages force row level security';

  execute $p$
    create policy ordmsg_lee on public.order_messages
      for select to authenticated
      using (
        public.is_admin()
        or user_id::text = auth.uid()::text
        or public.vg_owns_order(order_id::text)
      )
  $p$;

  -- Escribir en la tabla vieja: solo el administrador. El chat de
  -- verdad es vg_live_chat_messages desde la fase 17.
  execute $p$
    create policy ordmsg_admin on public.order_messages
      for all to authenticated
      using (public.is_admin()) with check (public.is_admin())
  $p$;

  raise notice 'order_messages cerrada';
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 2. vg_chat_messages — el chat de dos versiones atrás
--
--    Cero rastros en el código actual. Solo el administrador, que
--    para eso son conversaciones con clientes y puede necesitarlas.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  if to_regclass('public.vg_chat_messages') is null then
    raise notice 'vg_chat_messages no existe, se salta';
    return;
  end if;

  for r in select policyname from pg_policies
            where schemaname='public' and tablename='vg_chat_messages'
  loop
    execute format('drop policy if exists %I on public.vg_chat_messages', r.policyname);
  end loop;

  execute 'alter table public.vg_chat_messages enable row level security';
  execute 'alter table public.vg_chat_messages force row level security';

  execute $p$
    create policy chatviejo_admin on public.vg_chat_messages
      for all to authenticated
      using (public.is_admin()) with check (public.is_admin())
  $p$;

  raise notice 'vg_chat_messages cerrada';
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 3. vg_support_messages — vacía, pero abierta
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  if to_regclass('public.vg_support_messages') is null then
    raise notice 'vg_support_messages no existe, se salta';
    return;
  end if;

  for r in select policyname from pg_policies
            where schemaname='public' and tablename='vg_support_messages'
  loop
    execute format('drop policy if exists %I on public.vg_support_messages', r.policyname);
  end loop;

  execute 'alter table public.vg_support_messages enable row level security';
  execute 'alter table public.vg_support_messages force row level security';

  execute $p$
    create policy sopviejo_admin on public.vg_support_messages
      for all to authenticated
      using (public.is_admin()) with check (public.is_admin())
  $p$;

  raise notice 'vg_support_messages cerrada';
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 4. vg_token_log — el registro viejo de tokens
--
--    Queda código antiguo que lo lee filtrando por su propio usuario
--    (el bloque de la cuenta, sobre la línea 21962 del index.html).
--    Con la regla de abajo ese código sigue viendo lo suyo.
--
--    Escribir se cierra a propósito. Ese mismo código viejo inserta
--    aquí desde el navegador, y ya no podrá: es el patrón que la
--    fase 76 quitó de la cartera. Da igual para el saldo real —lo
--    lleva vg_token_wallet, que sí es la buena— así que lo único que
--    se pierde es que deje de apuntarse en un registro que ya nadie
--    mira. No rompe ninguna pantalla.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  if to_regclass('public.vg_token_log') is null then
    raise notice 'vg_token_log no existe, se salta';
    return;
  end if;

  for r in select policyname from pg_policies
            where schemaname='public' and tablename='vg_token_log'
  loop
    execute format('drop policy if exists %I on public.vg_token_log', r.policyname);
  end loop;

  execute 'alter table public.vg_token_log enable row level security';
  execute 'alter table public.vg_token_log force row level security';

  execute $p$
    create policy tokenlog_lee on public.vg_token_log
      for select to authenticated
      using (public.is_admin() or user_id::text = auth.uid()::text)
  $p$;

  execute $p$
    create policy tokenlog_admin on public.vg_token_log
      for all to authenticated
      using (public.is_admin()) with check (public.is_admin())
  $p$;

  raise notice 'vg_token_log cerrada';
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 5. RESULTADO — las cinco filas tienen que decir OK
-- ═══════════════════════════════════════════════════════════════════

select 'order_messages cerrada' as que,
  coalesce((select string_agg(distinct cmd, ', ') from pg_policies
    where schemaname='public' and tablename='order_messages' and roles::text like '%anon%'),
    'nada sin cuenta') as sin_cuenta_puede,
  case when to_regclass('public.order_messages') is null
         or (select count(*) from pg_policies
              where schemaname='public' and tablename='order_messages'
                and roles::text like '%anon%') = 0
       then 'OK' else 'REVISAR' end as resultado
union all
select 'vg_chat_messages cerrada',
  coalesce((select string_agg(distinct cmd, ', ') from pg_policies
    where schemaname='public' and tablename='vg_chat_messages' and roles::text like '%anon%'),
    'nada sin cuenta'),
  case when to_regclass('public.vg_chat_messages') is null
         or (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_chat_messages'
                and roles::text like '%anon%') = 0
       then 'OK' else 'REVISAR' end
union all
select 'vg_support_messages cerrada',
  coalesce((select string_agg(distinct cmd, ', ') from pg_policies
    where schemaname='public' and tablename='vg_support_messages' and roles::text like '%anon%'),
    'nada sin cuenta'),
  case when to_regclass('public.vg_support_messages') is null
         or (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_support_messages'
                and roles::text like '%anon%') = 0
       then 'OK' else 'REVISAR' end
union all
select 'vg_token_log cerrada',
  coalesce((select string_agg(distinct cmd, ', ') from pg_policies
    where schemaname='public' and tablename='vg_token_log' and roles::text like '%anon%'),
    'nada sin cuenta'),
  case when to_regclass('public.vg_token_log') is null
         or (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_token_log'
                and roles::text like '%anon%') = 0
       then 'OK' else 'REVISAR' end
union all
select 'Sin cuenta solo se ve el catálogo',
  (select count(*)::text from pg_policies
    where schemaname='public' and roles::text like '%anon%'
      and tablename not in ('products','products_admin','hero_offer','vg_xbox_games',
                            'vg_token_config','vg_token_rewards','vg_site_config',
                            'vg_horario','vg_analytics_events')) || ' tablas de más',
  case when (select count(*) from pg_policies
              where schemaname='public' and roles::text like '%anon%'
                and tablename not in ('products','products_admin','hero_offer','vg_xbox_games',
                                      'vg_token_config','vg_token_rewards','vg_site_config',
                                      'vg_horario','vg_analytics_events')) = 0
       then 'OK' else 'REVISAR' end;


-- ═══════════════════════════════════════════════════════════════════
-- 6. La foto final: qué puede hacer un visitante sin cuenta
--
--    Lo esperado, y nada más:
--      products, products_admin, hero_offer, vg_xbox_games,
--      vg_token_config, vg_token_rewards, vg_site_config,
--      vg_horario  →  SELECT   (el catálogo de una tienda abierta)
--      vg_analytics_events     →  INSERT   (apuntar visitas)
-- ═══════════════════════════════════════════════════════════════════

select tablename as tabla,
       string_agg(distinct cmd, ', ' order by cmd) as que_puede_hacer_sin_cuenta
  from pg_policies
 where schemaname = 'public' and roles::text like '%anon%'
 group by tablename
 order by tablename;


-- ═══════════════════════════════════════════════════════════════════
-- 7. CUANDO DECIDAS — borrar las tablas viejas
--
--    Ya están cerradas, así que no corre prisa. Pero son cuatro
--    tablas que nadie usa guardando conversaciones de clientes: lo
--    que no se guarda no se puede filtrar.
--
--    ANTES de borrar, haz el respaldo desde el panel (pestaña
--    Exportar) y comprueba que esos 22 y 12 mensajes viejos no te
--    hacen falta. Luego quita las comillas y córrelo.
-- ═══════════════════════════════════════════════════════════════════
/*
drop table if exists public.vg_chat_messages;
drop table if exists public.vg_support_messages;
drop table if exists public.order_messages;
drop table if exists public.vg_token_log;
*/
