-- ═══════════════════════════════════════════════════════════════════
-- VG FASE 80 · Los cupones dejan de vivir en el navegador
--
-- QUÉ ESTABA PASANDO
--
-- Los cupones eran cuatro líneas escritas dentro de la página:
--
--     var COUPONS = {'VESSEL10':{pct:10}, 'VESSEL20':{pct:20},
--                    'NUEVO15':{pct:15},  'GAMER5':{pct:5}};
--
-- y los que se creaban desde el panel se guardaban en el localStorage
-- del navegador del dueño. De ahí salen tres problemas:
--
--   1. Borrar uno de esos cuatro no servía de nada: se borraba de la
--      memoria de esa pestaña y volvía en cuanto se recargaba, porque
--      está en el código. Es exactamente lo que se vio al probar.
--   2. Un cupón creado desde el panel solo existía en la computadora
--      del dueño. Ningún cliente lo podía usar nunca.
--   3. Cualquiera podía inventarse uno. El descuento se calculaba en
--      el navegador y el servidor no lo comprobaba: bastaba con
--      escribir dos líneas en la consola para pagar lo que uno
--      quisiera.
--
-- QUÉ HACE ESTE ARCHIVO
--
--   · Crea la tabla vg_cupones, que es a partir de ahora la única
--     verdad. Solo el dueño puede tocarla.
--   · La tabla NO se puede leer desde fuera. Si se pudiera, cualquiera
--     leería la lista de códigos activos y los usaría. Para comprobar
--     un código hay una función que responde solo por ese código: hay
--     que saberlo para preguntarlo.
--   · El descuento se aplica en el servidor, al registrar el pedido.
--     Aunque alguien fuerce el navegador, el total que queda guardado
--     es el que sale de aquí.
--
-- CÓMO SE CORRE: Supabase → SQL Editor → New query → pegar todo → Run.
-- Se puede correr más de una vez sin problema.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1 · La tabla ────────────────────────────────────────────────────
create table if not exists public.vg_cupones (
  codigo  text primary key,
  pct     integer not null check (pct >= 1 and pct <= 90),
  activo  boolean not null default true,
  creado  timestamptz not null default now()
);

comment on table public.vg_cupones is
  'Cupones de descuento. Única fuente: el navegador ya no decide nada.';

-- El código siempre en mayúsculas y sin espacios, para que "vessel10",
-- " VESSEL10 " y "VESSEL10" sean el mismo cupón y no tres.
create or replace function public.vg_cupon_normaliza()
returns trigger
language plpgsql
as $$
begin
  new.codigo := upper(btrim(new.codigo));
  if new.codigo = '' then
    raise exception 'El cupón necesita un código.';
  end if;
  return new;
end;
$$;

drop trigger if exists vg_cupones_normaliza on public.vg_cupones;
create trigger vg_cupones_normaliza
  before insert or update on public.vg_cupones
  for each row execute function public.vg_cupon_normaliza();

-- ── 2 · Quién puede tocarla ─────────────────────────────────────────
alter table public.vg_cupones enable row level security;

-- Se borran las políticas por nombre antes de crearlas: correr el
-- archivo dos veces no debe fallar.
drop policy if exists vg_cupones_lee_admin   on public.vg_cupones;
drop policy if exists vg_cupones_escribe_admin on public.vg_cupones;

-- Leer la lista: SOLO el dueño. Nadie más, ni siquiera con sesión.
create policy vg_cupones_lee_admin on public.vg_cupones
  for select using (public.is_admin());

-- Crear, editar y borrar: SOLO el dueño.
create policy vg_cupones_escribe_admin on public.vg_cupones
  for all using (public.is_admin()) with check (public.is_admin());

-- ── 3 · Comprobar un código sin enseñar la lista ────────────────────
--
-- Devuelve el porcentaje si el cupón existe y está activo, y null si
-- no. Es security definer a propósito: se salta la RLS para poder
-- responder, pero solo sobre el código exacto que le preguntan. Quien
-- no conozca el código no obtiene nada, y nadie puede pedir la lista.
create or replace function public.vg_cupon_valido(p_codigo text)
returns integer
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_pct integer;
begin
  if p_codigo is null or btrim(p_codigo) = '' then
    return null;
  end if;

  select pct into v_pct
    from public.vg_cupones
   where codigo = upper(btrim(p_codigo))
     and activo = true;

  return v_pct;   -- null si no existe, está apagado o está mal escrito
end;
$$;

revoke all on function public.vg_cupon_valido(text) from public;
grant execute on function public.vg_cupon_valido(text) to anon, authenticated;

-- ── 4 · El pedido guarda qué cupón se usó ───────────────────────────
alter table public.orders add column if not exists cupon     text;
alter table public.orders add column if not exists cupon_pct integer;

-- ── 5 · El descuento se aplica AQUÍ, no en el navegador ─────────────
--
-- Va en un disparador aparte y no dentro del que recalcula el total,
-- para no reescribir aquella función entera y arriesgarse a cambiar
-- algo sin querer. El orden importa y está resuelto solo: cuando hay
-- varios disparadores "before insert" en la misma tabla, Postgres los
-- corre en orden alfabético, y "orders_calcula_total" va antes que
-- "orders_cupon". Es decir: primero se recalcula el total de verdad a
-- partir del catálogo, y sobre ESE total se aplica el descuento.
create or replace function public.vg_aplica_cupon()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pct integer;
begin
  if new.cupon is null or btrim(new.cupon) = '' then
    new.cupon     := null;
    new.cupon_pct := null;
    return new;
  end if;

  v_pct := public.vg_cupon_valido(new.cupon);

  if v_pct is null then
    -- Cupón inventado, borrado o apagado. No se bloquea el pedido: se
    -- cobra el precio completo y queda apuntado, que es más útil que
    -- un error en la cara del cliente por un código viejo.
    begin
      perform public.vg_apuntar(
        'cupon rechazado',
        coalesce(new.id::text,'nuevo'),
        coalesce(new.cupon,'')
      );
    exception when others then null;
    end;
    new.cupon     := null;
    new.cupon_pct := null;
    return new;
  end if;

  new.cupon     := upper(btrim(new.cupon));
  new.cupon_pct := v_pct;
  new.total     := round(coalesce(new.total,0) * (1 - v_pct::numeric / 100));
  if new.total < 0 then new.total := 0; end if;

  return new;
end;
$$;

drop trigger if exists orders_cupon on public.orders;
create trigger orders_cupon
  before insert on public.orders
  for each row execute function public.vg_aplica_cupon();

-- ── 6 · El registro del pedido acepta el cupón ──────────────────────
--
-- Se borra la versión anterior por su firma exacta antes de crear la
-- nueva. Sin ese drop, Postgres se quedaría con las dos (una con nueve
-- parámetros y otra con diez) y las llamadas fallarían por ambiguas.
drop function if exists public.vg_create_order_v17(
  jsonb, numeric, text, text, text, text, text, text, text
);

create or replace function public.vg_create_order_v17(
  p_items           jsonb,
  p_total           numeric,
  p_product_title   text default null,
  p_product_option  text default null,
  p_delivery_data   text default null,
  p_proof_data_url  text default null,
  p_proof_file_name text default null,
  p_proof_mime      text default null,
  p_source          text default 'web',
  p_cupon           text default null
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
    unread_admin, unread_client, chat_unlocked,
    cupon
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
    false,  -- ← chat BLOQUEADO hasta que el admin escriba
    p_cupon
  )
  returning * into v_order;

  insert into public.vg_live_chat_messages (
    thread_type, thread_ref, order_id, sender_role, sender_name, message
  ) values (
    'order', v_order.id::text, v_order.id::text, 'system', 'Sistema',
    'Pedido recibido. Un administrador lo revisará en breve.'
  );

  return v_order;
end;
$$;

-- ── 7 · Comprobación ────────────────────────────────────────────────
--
-- Debe salir: la tabla creada, cero cupones (los cuatro del código no
-- se traen a propósito: si los quieres, créalos desde el panel), y la
-- función respondiendo null a un código inventado.
select 'tabla creada'            as paso, count(*)::text as valor from public.vg_cupones
union all
select 'cupon inventado da null' as paso,
       coalesce(public.vg_cupon_valido('NOEXISTE')::text, 'null') as valor
union all
select 'disparador puesto'       as paso, count(*)::text as valor
  from pg_trigger where tgname = 'orders_cupon';
