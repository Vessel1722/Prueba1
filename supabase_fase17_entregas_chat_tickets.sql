-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 17
-- Entrega interna + chat condicional + tickets de soporte
-- (reemplaza el flujo de entregas por WhatsApp)
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente: puedes correrlo varias veces sin romper nada.
--
-- Requiere haber corrido antes: supabase_setup_fase0.sql
-- (de ahí vienen vg_users, is_admin() y el trigger de alta de usuario)
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- 1. PEDIDOS — columnas que necesita el nuevo flujo
--    Se agregan con "if not exists" para no tocar lo que ya funciona.
-- ═══════════════════════════════════════════════════════════════════
alter table public.orders add column if not exists customer_name    text;
alter table public.orders add column if not exists customer_phone   text;
alter table public.orders add column if not exists customer_email   text;
alter table public.orders add column if not exists product_title    text;
alter table public.orders add column if not exists product_option   text;
alter table public.orders add column if not exists delivery_data    text;
alter table public.orders add column if not exists currency         text default 'MXN';

-- Comprobante de pago (se guarda como data URL para no depender del bucket)
alter table public.orders add column if not exists proof_data_url   text;
alter table public.orders add column if not exists proof_file_name  text;
alter table public.orders add column if not exists proof_mime       text;

-- Banderas de la bandeja del admin / notificaciones del cliente
alter table public.orders add column if not exists unread_admin     boolean default true;
alter table public.orders add column if not exists unread_client    boolean default false;

-- ─────────────────────────────────────────────────────────────
-- CLAVE DEL MÓDULO 2: el chat del cliente nace BLOQUEADO.
-- Solo se pone en true cuando el admin manda el primer mensaje
-- (lo hace el trigger de la sección 4). El cliente NUNCA puede
-- cambiar esta columna por sí mismo (ver RLS en la sección 6).
-- ─────────────────────────────────────────────────────────────
alter table public.orders add column if not exists chat_unlocked    boolean default false;

-- Momento en que se entregó (para métricas y para el chip "Entregado")
alter table public.orders add column if not exists delivered_at     timestamptz;

create index if not exists orders_user_idx       on public.orders(user_id);
create index if not exists orders_created_idx    on public.orders(created_at desc);
create index if not exists orders_status_idx     on public.orders(status);


-- ═══════════════════════════════════════════════════════════════════
-- 2. CHAT DE ENTREGA (mensajes por pedido)
-- ═══════════════════════════════════════════════════════════════════
create table if not exists public.vg_live_chat_messages (
  id             bigserial primary key,
  created_at     timestamptz default now(),
  thread_type    text default 'order',      -- 'order' | 'ticket'
  thread_ref     text not null,             -- id del pedido (o del ticket) en texto
  order_id       text,
  sender_role    text not null,             -- 'client' | 'admin' | 'system'
  sender_name    text,
  sender_phone   text,
  message        text,
  attachment_url text,
  is_delivery    boolean default false,     -- marca el mensaje final de entrega
  read_by_client boolean default false,
  read_by_admin  boolean default false
);

-- columnas que pudieran faltar si la tabla ya existía de antes
alter table public.vg_live_chat_messages add column if not exists is_delivery boolean default false;
alter table public.vg_live_chat_messages add column if not exists thread_type text default 'order';

create index if not exists chat_thread_idx  on public.vg_live_chat_messages(thread_type, thread_ref, created_at);
create index if not exists chat_role_idx    on public.vg_live_chat_messages(sender_role);


-- ═══════════════════════════════════════════════════════════════════
-- 3. TICKETS DE SOPORTE (reporte de fallas)
--
-- ⚠️ NOTA DE SEGURIDAD IMPORTANTE (léela):
--    La columna account_password guarda, en texto plano, la contraseña
--    de la cuenta del servicio que el cliente reporta como fallando.
--    Es lo que pediste y para cuentas compartidas tiene sentido, pero
--    implica que:
--      · Solo el dueño del ticket y los admins pueden leerla (RLS abajo).
--      · NO debe exportarse a CSV/JSON junto con el resto de los datos.
--      · Conviene borrar el ticket (o vaciar esa columna) cuando se
--        resuelva. La sección 8 trae una función para eso.
-- ═══════════════════════════════════════════════════════════════════
-- La llave foránea hacia vg_users se agrega aparte (sección 3b) para que,
-- si los tipos no coinciden en una instalación vieja, la tabla se cree
-- igual y solo se quede sin la restricción — en vez de tumbar el script.
create table if not exists public.vg_support_tickets (
  id                  uuid primary key default gen_random_uuid(),
  created_at          timestamptz default now(),
  updated_at          timestamptz default now(),
  user_id             uuid,

  -- Campos obligatorios del formulario
  order_id            text,          -- pedido al que pertenece (del desplegable)
  product_name        text not null, -- producto adquirido
  purchase_date       date not null, -- fecha de compra
  subscription_period text not null, -- tiempo de suscripción adquirido
  account_email       text not null, -- correo del producto afectado
  account_password    text not null, -- contraseña del producto afectado
  problem_description text not null, -- descripción detallada del problema

  -- Gestión interna
  status              text default 'abierto',  -- abierto | en_proceso | resuelto | cerrado
  customer_name       text,
  customer_phone      text,
  admin_notes         text
);

create index if not exists tickets_user_idx    on public.vg_support_tickets(user_id);
create index if not exists tickets_status_idx  on public.vg_support_tickets(status);
create index if not exists tickets_created_idx on public.vg_support_tickets(created_at desc);


-- ── 3b. Llave foránea opcional de tickets → vg_users ──
-- Si los tipos coinciden se agrega; si no, se ignora sin romper nada.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'vg_support_tickets_user_fk'
  ) then
    alter table public.vg_support_tickets
      add constraint vg_support_tickets_user_fk
      foreign key (user_id) references public.vg_users(id) on delete set null;
  end if;
exception when others then
  raise notice 'FK de tickets omitida (tipos distintos): %', sqlerrm;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 4. TRIGGER — el admin desbloquea el chat al escribir el primer mensaje
--    Esta es la regla estricta del módulo 2, aplicada en la base de
--    datos (no solo en la interfaz): mientras chat_unlocked sea false,
--    la política RLS de la sección 6 rechaza cualquier INSERT del cliente.
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.vg_chat_after_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.thread_type = 'order' then
    if new.sender_role = 'admin' then
      -- El admin escribió: se abre la caja de texto del cliente
      -- y se le marca notificación pendiente.
      update public.orders
         set chat_unlocked = true,
             unread_client = true,
             unread_admin  = false
       where id::text = new.thread_ref;

    elsif new.sender_role = 'client' then
      -- El cliente respondió: el admin tiene algo pendiente por leer.
      update public.orders
         set unread_admin = true
       where id::text = new.thread_ref;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists vg_chat_after_insert_trg on public.vg_live_chat_messages;
create trigger vg_chat_after_insert_trg
  after insert on public.vg_live_chat_messages
  for each row execute function public.vg_chat_after_insert();


-- ═══════════════════════════════════════════════════════════════════
-- 5. FUNCIONES DE APOYO
-- ═══════════════════════════════════════════════════════════════════

-- ¿Este pedido es del usuario que está conectado?
--
-- OJO con los ::text — no son adorno. En instalaciones viejas la
-- columna orders.user_id quedó como text en vez de uuid, y comparar
-- text = uuid directamente truena con:
--   ERROR 42883: operator does not exist: text = uuid
-- Comparando ambos lados como texto funciona con cualquiera de los dos
-- tipos, sin tener que migrar la tabla.
create or replace function public.vg_owns_order(p_ref text)
returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from public.orders o
     where o.id::text = p_ref
       and o.user_id::text = auth.uid()::text
  );
$$;

-- ¿El chat de este pedido ya fue desbloqueado por el admin?
create or replace function public.vg_chat_is_unlocked(p_ref text)
returns boolean
language sql security definer stable
set search_path = public
as $$
  select coalesce((
    select o.chat_unlocked from public.orders o where o.id::text = p_ref
  ), false);
$$;

-- Crear pedido (entrega interna, ya sin WhatsApp).
-- SECURITY DEFINER para poder escribir todas las columnas de forma
-- controlada; siempre amarra el pedido al usuario conectado.
create or replace function public.vg_create_order_v17(
  p_items           jsonb,
  p_total           numeric,
  p_product_title   text default null,
  p_product_option  text default null,
  p_delivery_data   text default null,
  p_proof_data_url  text default null,
  p_proof_file_name text default null,
  p_proof_mime      text default null,
  p_source          text default 'web'
)
returns public.orders
language plpgsql security definer
set search_path = public
as $$
declare
  v_user   public.vg_users;
  v_order  public.orders;
begin
  if auth.uid() is null then
    raise exception 'Inicia sesión para registrar tu pedido.';
  end if;

  select * into v_user from public.vg_users where id::text = auth.uid()::text;

  insert into public.orders (
    source, status, total, currency, items,
    user_id, customer_name, customer_phone, customer_email,
    client_name, client_phone,
    product_title, product_option, delivery_data,
    proof_data_url, proof_file_name, proof_mime,
    unread_admin, unread_client, chat_unlocked
  ) values (
    coalesce(p_source,'web'), 'pendiente', coalesce(p_total,0), 'MXN',
    coalesce(p_items,'[]'::jsonb),
    auth.uid(),
    coalesce(v_user.name,''), coalesce(v_user.phone,''), coalesce(v_user.email,''),
    coalesce(v_user.name,''), coalesce(v_user.phone,''),
    p_product_title, p_product_option, p_delivery_data,
    p_proof_data_url, p_proof_file_name, p_proof_mime,
    true,   -- al admin le llega como no leído
    false,
    false   -- ← chat BLOQUEADO hasta que el admin escriba
  )
  returning * into v_order;

  -- Mensaje de sistema inicial (no desbloquea el chat)
  insert into public.vg_live_chat_messages (
    thread_type, thread_ref, order_id, sender_role, sender_name, message
  ) values (
    'order', v_order.id::text, v_order.id::text, 'system', 'Sistema',
    'Pedido recibido. Un administrador lo revisará en breve.'
  );

  return v_order;
end;
$$;

-- Entregar pedido: manda el mensaje final y marca el pedido entregado
-- en una sola operación (evita estados a medias).
create or replace function public.vg_deliver_order_v17(
  p_order_id text,
  p_message  text
)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede entregar pedidos.';
  end if;

  insert into public.vg_live_chat_messages (
    thread_type, thread_ref, order_id, sender_role, sender_name,
    message, is_delivery, read_by_admin
  ) values (
    'order', p_order_id, p_order_id, 'admin', 'Vessel Games',
    p_message, true, true
  );

  update public.orders
     set status        = 'entregado',
         delivered_at  = now(),
         chat_unlocked = true,
         unread_client = true,
         unread_admin  = false
   where id::text = p_order_id;

  return true;
end;
$$;

-- Borrar las credenciales de un ticket ya resuelto (higiene de datos)
create or replace function public.vg_ticket_wipe_credentials(p_ticket_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  update public.vg_support_tickets
     set account_password = '[borrada]',
         updated_at = now()
   where id = p_ticket_id;
  return true;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════
-- 6. RLS — Row Level Security
-- ═══════════════════════════════════════════════════════════════════
alter table public.orders                 enable row level security;
alter table public.vg_live_chat_messages  enable row level security;
alter table public.vg_support_tickets     enable row level security;

-- Limpiar políticas viejas (incluidas las permisivas del flujo WhatsApp)
drop policy if exists "allow insert orders"     on public.orders;
drop policy if exists "allow select orders"     on public.orders;
drop policy if exists "allow update orders"     on public.orders;
drop policy if exists orders_select_own         on public.orders;
drop policy if exists orders_insert_own         on public.orders;
drop policy if exists orders_update_admin       on public.orders;
drop policy if exists chat_select               on public.vg_live_chat_messages;
drop policy if exists chat_insert_client        on public.vg_live_chat_messages;
drop policy if exists chat_insert_admin         on public.vg_live_chat_messages;
drop policy if exists chat_update               on public.vg_live_chat_messages;
drop policy if exists tickets_select            on public.vg_support_tickets;
drop policy if exists tickets_insert            on public.vg_support_tickets;
drop policy if exists tickets_update            on public.vg_support_tickets;

-- ── PEDIDOS ──
-- (mismo motivo que arriba para los ::text: aguanta user_id uuid o text)
-- El cliente ve solo los suyos; el admin ve todos.
create policy orders_select_own on public.orders
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());

-- El cliente puede crear pedidos a su nombre (además del RPC).
create policy orders_insert_own on public.orders
  for insert to authenticated
  with check (user_id::text = auth.uid()::text or public.is_admin());

-- Solo el admin actualiza pedidos (estado, entrega, chat_unlocked).
-- Así el cliente NO puede desbloquearse el chat por su cuenta.
create policy orders_update_admin on public.orders
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ── CHAT ──
-- Lees el chat si el pedido es tuyo, o si eres admin.
create policy chat_select on public.vg_live_chat_messages
  for select to authenticated
  using (public.vg_owns_order(thread_ref) or public.is_admin());

-- ★ REGLA ESTRICTA DEL MÓDULO 2 ★
-- El cliente solo puede INSERTAR mensajes si:
--   a) el pedido es suyo, y
--   b) el admin ya escribió primero (chat_unlocked = true).
-- Si el admin no contesta, este INSERT es rechazado por la base de
-- datos, no solo por la interfaz.
create policy chat_insert_client on public.vg_live_chat_messages
  for insert to authenticated
  with check (
    sender_role = 'client'
    and public.vg_owns_order(thread_ref)
    and public.vg_chat_is_unlocked(thread_ref)
  );

-- El admin puede escribir siempre (y es quien desbloquea el chat).
create policy chat_insert_admin on public.vg_live_chat_messages
  for insert to authenticated
  with check (public.is_admin());

-- Marcar como leído
create policy chat_update on public.vg_live_chat_messages
  for update to authenticated
  using (public.vg_owns_order(thread_ref) or public.is_admin())
  with check (public.vg_owns_order(thread_ref) or public.is_admin());

-- ── TICKETS ──
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


-- ═══════════════════════════════════════════════════════════════════
-- 7. REALTIME — para la alerta con sonido del panel admin
--    Sin esto, el panel tendría que estar preguntando cada X segundos.
-- ═══════════════════════════════════════════════════════════════════
do $$
begin
  begin
    alter publication supabase_realtime add table public.orders;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.vg_live_chat_messages;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.vg_support_tickets;
  exception when duplicate_object then null;
  end;
end $$;

-- Realtime necesita la fila completa para los UPDATE
alter table public.orders                replica identity full;
alter table public.vg_live_chat_messages replica identity full;
alter table public.vg_support_tickets    replica identity full;


-- ═══════════════════════════════════════════════════════════════════
-- 8. COMPROBACIÓN RÁPIDA
--    Corre esto después para confirmar que todo quedó bien.
-- ═══════════════════════════════════════════════════════════════════
-- select column_name from information_schema.columns
--  where table_name='orders' and column_name in
--        ('chat_unlocked','proof_data_url','delivery_data','unread_admin');
--
-- select tablename, policyname from pg_policies
--  where tablename in ('orders','vg_live_chat_messages','vg_support_tickets')
--  order by tablename, policyname;

-- ═══════════════════════════════════════════════════════════════════
-- LISTO — Fase 17 completa.
-- ═══════════════════════════════════════════════════════════════════
