-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 73 — Que el operador vea lo que tiene que ver
--
-- La fase 71 creó el rol, pero los permisos de la base seguían
-- preguntando solo por is_admin. Resultado: al operador no lo dejaban
-- ni abrir el panel, y si entraba habría visto todo vacío.
--
-- Aquí se le da acceso a lo justo:
--
--   · pedidos            ver y cambiar de estado
--   · chat de entrega    ver y escribir
--   · tickets            ver y responder
--
-- Y a nada más. Ni usuarios, ni tokens, ni comprobantes de pago
-- ajenos, ni la configuración.
--
-- Las reglas nuevas se AÑADEN, no reemplazan a las que ya hay. En
-- Postgres varias reglas permisivas se suman con O, así que lo que ya
-- funcionaba sigue funcionando igual.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- ¿Es operador, y solo operador?
--
--    Se separa de vg_puede_atender a propósito. Esa dice "sí" también
--    a los administradores; esta sirve para reglas que se aplican
--    únicamente al operador.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_es_operador()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select rol = 'operador' from public.vg_users
      where id::text = auth.uid()::text), false);
$$;

grant execute on function public.vg_es_operador() to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 1. Pedidos: ver todos y cambiarles el estado
--
--    No se le da permiso de BORRAR. Un operador que se equivoca debe
--    poder cancelar un pedido, no hacerlo desaparecer.
-- ─────────────────────────────────────────────────────────────
drop policy if exists orders_operador_lee on public.orders;
create policy orders_operador_lee on public.orders
  for select to authenticated using (public.vg_es_operador());

drop policy if exists orders_operador_edita on public.orders;
create policy orders_operador_edita on public.orders
  for update to authenticated
  using (public.vg_es_operador()) with check (public.vg_es_operador());


-- ─────────────────────────────────────────────────────────────
-- 2. Chat de entrega: leer y contestar
-- ─────────────────────────────────────────────────────────────
drop policy if exists chat_operador_lee on public.vg_live_chat_messages;
create policy chat_operador_lee on public.vg_live_chat_messages
  for select to authenticated using (public.vg_es_operador());

drop policy if exists chat_operador_escribe on public.vg_live_chat_messages;
create policy chat_operador_escribe on public.vg_live_chat_messages
  for insert to authenticated with check (public.vg_es_operador());


-- ─────────────────────────────────────────────────────────────
-- 3. Tickets de soporte: leer y responder
-- ─────────────────────────────────────────────────────────────
drop policy if exists tickets_operador_lee on public.vg_support_tickets;
create policy tickets_operador_lee on public.vg_support_tickets
  for select to authenticated using (public.vg_es_operador());

drop policy if exists tickets_operador_edita on public.vg_support_tickets;
create policy tickets_operador_edita on public.vg_support_tickets
  for update to authenticated
  using (public.vg_es_operador()) with check (public.vg_es_operador());


-- ─────────────────────────────────────────────────────────────
-- 4. Su propia ficha, para saber quién es
--
--    Sin esto el panel no puede averiguar su rol y lo trataría como
--    cliente. Solo lee la suya, no la de nadie más.
-- ─────────────────────────────────────────────────────────────
drop policy if exists usuarios_lee_la_suya on public.vg_users;
create policy usuarios_lee_la_suya on public.vg_users
  for select to authenticated using (id::text = auth.uid()::text);


-- ─────────────────────────────────────────────────────────────
-- 5. RESULTADO — debe decir OK
--
--    "operadores" te dice cuántas cuentas tienen ese rol ahora mismo.
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='vg_es_operador')::text
    || ' de 1 funcion' as funcion,
  (select count(*) from pg_policies
    where schemaname='public' and policyname like '%operador%')::text
    || ' de 6 reglas' as reglas,
  (select count(*) from public.vg_users where rol = 'operador')::text
    || ' operador(es) dados de alta' as operadores,
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='vg_es_operador') = 1
        and (select count(*) from pg_policies
              where schemaname='public' and policyname like '%operador%') >= 6
       then 'OK' else 'REVISAR' end as resultado;
