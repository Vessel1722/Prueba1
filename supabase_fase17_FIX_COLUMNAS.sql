-- ═══════════════════════════════════════════════════════════════════
-- FASE 17 · ARREGLO — columnas faltantes en vg_live_chat_messages
--
-- Síntoma:
--   No se pudo crear el pedido: column "order_id" of relation
--   "vg_live_chat_messages" does not exist
--
-- Causa:
--   La tabla ya existía en tu base con una estructura vieja. El
--   "create table if not exists" del script principal la respetó tal
--   cual (por eso no la rompió), pero eso dejó fuera las columnas que
--   el código nuevo necesita. Aquí se agregan una por una.
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Columnas que usa el chat de entrega
-- ─────────────────────────────────────────────────────────────
alter table public.vg_live_chat_messages add column if not exists created_at     timestamptz default now();
alter table public.vg_live_chat_messages add column if not exists thread_type    text default 'order';
alter table public.vg_live_chat_messages add column if not exists thread_ref     text;
alter table public.vg_live_chat_messages add column if not exists order_id       text;
alter table public.vg_live_chat_messages add column if not exists sender_role    text;
alter table public.vg_live_chat_messages add column if not exists sender_name    text;
alter table public.vg_live_chat_messages add column if not exists sender_phone   text;
alter table public.vg_live_chat_messages add column if not exists message        text;
alter table public.vg_live_chat_messages add column if not exists attachment_url text;
alter table public.vg_live_chat_messages add column if not exists is_delivery    boolean default false;
alter table public.vg_live_chat_messages add column if not exists read_by_client boolean default false;
alter table public.vg_live_chat_messages add column if not exists read_by_admin  boolean default false;


-- ─────────────────────────────────────────────────────────────
-- 2. Columnas que usan los pedidos (por si alguna también faltaba)
-- ─────────────────────────────────────────────────────────────
alter table public.orders add column if not exists customer_name   text;
alter table public.orders add column if not exists customer_phone  text;
alter table public.orders add column if not exists customer_email  text;
alter table public.orders add column if not exists client_name     text;
alter table public.orders add column if not exists client_phone    text;
alter table public.orders add column if not exists product_title   text;
alter table public.orders add column if not exists product_option  text;
alter table public.orders add column if not exists delivery_data   text;
alter table public.orders add column if not exists currency        text default 'MXN';
alter table public.orders add column if not exists items           jsonb default '[]'::jsonb;
alter table public.orders add column if not exists proof_data_url  text;
alter table public.orders add column if not exists proof_file_name text;
alter table public.orders add column if not exists proof_mime      text;
alter table public.orders add column if not exists unread_admin    boolean default true;
alter table public.orders add column if not exists unread_client   boolean default false;
alter table public.orders add column if not exists chat_unlocked   boolean default false;
alter table public.orders add column if not exists delivered_at    timestamptz;
alter table public.orders add column if not exists source          text;
alter table public.orders add column if not exists status          text default 'pendiente';
alter table public.orders add column if not exists total           numeric default 0;


-- ─────────────────────────────────────────────────────────────
-- 3. Quitar NOT NULL de columnas viejas que ya no se llenan
--    (si la tabla traía columnas obligatorias de un diseño anterior,
--     bloquearían los INSERT nuevos)
-- ─────────────────────────────────────────────────────────────
do $$
declare col text;
begin
  foreach col in array array['body','text','contenido','mensaje','usuario','user_name','role','chat_id']
  loop
    begin
      execute format('alter table public.vg_live_chat_messages alter column %I drop not null', col);
    exception when undefined_column then null;
    end;
  end loop;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 4. Índices
-- ─────────────────────────────────────────────────────────────
create index if not exists chat_thread_idx on public.vg_live_chat_messages(thread_type, thread_ref, created_at);
create index if not exists chat_role_idx   on public.vg_live_chat_messages(sender_role);


-- ─────────────────────────────────────────────────────────────
-- 5. Recargar el caché del esquema (para que la API vea los cambios)
-- ─────────────────────────────────────────────────────────────
notify pgrst, 'reload schema';


-- ─────────────────────────────────────────────────────────────
-- 6. RESULTADO — deben aparecer las 12 columnas del chat
-- ─────────────────────────────────────────────────────────────
select
  count(*)::text || ' de 12 columnas' as chat,
  case when count(*) = 12 then 'OK' else 'REVISAR' end as resultado
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'vg_live_chat_messages'
  and column_name in ('created_at','thread_type','thread_ref','order_id','sender_role',
                      'sender_name','sender_phone','message','attachment_url',
                      'is_delivery','read_by_client','read_by_admin');
