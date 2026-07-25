-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 17 — LIMPIEZA DE POLÍTICAS RLS
--
-- ¿Por qué hace falta esto?
-- La verificación encontró 53 políticas en orders / vg_live_chat_messages
-- / vg_support_tickets, cuando deberían ser 10. Son restos acumulados de
-- migraciones anteriores (incluido el flujo viejo de WhatsApp).
--
-- El problema NO es que sobren: es que en PostgreSQL las políticas
-- permisivas se combinan con OR. Basta UNA vieja del tipo
-- "using (true)" para que le gane a las nuevas y se caiga el candado
-- del chat condicional (el cliente podría escribir sin que el admin
-- haya contestado, que es justo lo que queremos impedir).
--
-- Este script borra TODAS las políticas de esas tres tablas y deja
-- solamente las 10 correctas. Es idempotente.
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. ANTES: guarda un registro de lo que había (por si acaso)
--    Mira la pestaña de resultados: te lista lo que se va a borrar.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_policies_backup_f17 (
  respaldado_en timestamptz default now(),
  tabla         text,
  politica      text,
  comando       text,
  roles         text,
  expresion_using text,
  expresion_check text
);

insert into public.vg_policies_backup_f17 (tabla, politica, comando, roles, expresion_using, expresion_check)
select tablename, policyname, cmd, roles::text, qual, with_check
  from pg_policies
 where schemaname = 'public'
   and tablename in ('orders','vg_live_chat_messages','vg_support_tickets');


-- ─────────────────────────────────────────────────────────────
-- 2. BORRAR todas las políticas de las 3 tablas
-- ─────────────────────────────────────────────────────────────
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and tablename in ('orders','vg_live_chat_messages','vg_support_tickets')
  loop
    execute format('drop policy if exists %I on %I.%I',
                   r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 3. RLS encendido en las 3 tablas
-- ─────────────────────────────────────────────────────────────
alter table public.orders                enable row level security;
alter table public.vg_live_chat_messages enable row level security;
alter table public.vg_support_tickets    enable row level security;

-- Nota: a propósito NO se usa "force row level security". Forzaría las
-- políticas también sobre el dueño de la tabla, y las funciones
-- SECURITY DEFINER (vg_create_order_v17, vg_owns_order, is_admin)
-- corren precisamente como ese dueño: se arriesga a romper la creación
-- de pedidos y a provocar recursión entre políticas. No aporta nada
-- porque el service_role evade RLS por otra vía (BYPASSRLS).


-- ─────────────────────────────────────────────────────────────
-- 4. RECREAR solo las 10 políticas correctas
--    (los ::text aguantan user_id de tipo uuid o text)
-- ─────────────────────────────────────────────────────────────

-- ── PEDIDOS (3) ──
create policy orders_select_own on public.orders
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());

create policy orders_insert_own on public.orders
  for insert to authenticated
  with check (user_id::text = auth.uid()::text or public.is_admin());

-- Solo el admin actualiza pedidos. Así el cliente no puede
-- desbloquearse el chat cambiando chat_unlocked por su cuenta.
create policy orders_update_admin on public.orders
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ── CHAT (4) ──
create policy chat_select on public.vg_live_chat_messages
  for select to authenticated
  using (public.vg_owns_order(thread_ref) or public.is_admin());

-- ★ LA REGLA ESTRICTA ★
-- El cliente solo puede escribir si el pedido es suyo Y el admin
-- ya escribió primero (chat_unlocked = true).
create policy chat_insert_client on public.vg_live_chat_messages
  for insert to authenticated
  with check (
    sender_role = 'client'
    and public.vg_owns_order(thread_ref)
    and public.vg_chat_is_unlocked(thread_ref)
  );

create policy chat_insert_admin on public.vg_live_chat_messages
  for insert to authenticated
  with check (public.is_admin());

create policy chat_update on public.vg_live_chat_messages
  for update to authenticated
  using (public.vg_owns_order(thread_ref) or public.is_admin())
  with check (public.vg_owns_order(thread_ref) or public.is_admin());

-- ── TICKETS (3) ──
create policy tickets_select on public.vg_support_tickets
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());

create policy tickets_insert on public.vg_support_tickets
  for insert to authenticated
  with check (user_id::text = auth.uid()::text);

create policy tickets_update on public.vg_support_tickets
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 5. RESULTADO — debe decir "10 de 10 · OK"
-- ─────────────────────────────────────────────────────────────
select
  count(*)::text || ' de 10' as politicas,
  case when count(*) = 10 then 'OK' else 'REVISAR' end as resultado
from pg_policies
where schemaname = 'public'
  and tablename in ('orders','vg_live_chat_messages','vg_support_tickets');

-- Para ver el detalle de las que quedaron:
-- select tablename, policyname, cmd from pg_policies
--  where schemaname='public'
--    and tablename in ('orders','vg_live_chat_messages','vg_support_tickets')
--  order by tablename, policyname;

-- El respaldo de lo que había quedó en: public.vg_policies_backup_f17
-- Cuando confirmes que todo funciona, puedes borrarlo con:
-- drop table public.vg_policies_backup_f17;
