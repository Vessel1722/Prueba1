-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 0 — Base de datos + seguridad (Supabase Auth)
-- Pega TODO esto en:  Supabase → SQL Editor → New query → Run
-- Es idempotente: puedes correrlo varias veces sin romper nada.
-- ═══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- 1. TABLA DE USUARIOS (perfil, ligado a Auth)
--    El id de vg_users = el id del usuario en Supabase Auth (auth.uid()).
-- ─────────────────────────────────────────────
create table if not exists public.vg_users (
  id             uuid primary key,
  name           text,
  phone          text,
  email          text,
  referral_code  text unique default upper(substring(replace(gen_random_uuid()::text,'-',''),1,8)),
  referred_by    uuid references public.vg_users(id),
  total_purchases integer default 0,
  is_admin       boolean default false,
  created_at     timestamptz default now()
);

-- columnas que pudieran faltar si la tabla ya existía
alter table public.vg_users add column if not exists email    text;
alter table public.vg_users add column if not exists is_admin boolean default false;

-- ─────────────────────────────────────────────
-- 2. WALLET DE TOKENS
-- ─────────────────────────────────────────────
create table if not exists public.vg_token_wallet (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid unique references public.vg_users(id) on delete cascade,
  balance         numeric default 0,
  total_purchases integer default 0,
  total_earned    numeric default 0,
  updated_at      timestamptz default now()
);

-- ─────────────────────────────────────────────
-- 3. PEDIDOS
-- ─────────────────────────────────────────────
create table if not exists public.orders (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz default now(),
  source       text,
  status       text default 'pendiente',
  total        numeric default 0,
  items        jsonb default '[]'::jsonb,
  proof        jsonb,
  user_id      uuid references public.vg_users(id),
  client_name  text,
  client_phone text,
  notes        text
);

-- ─────────────────────────────────────────────
-- 4. CATÁLOGO (para la Fase 3 — CRUD de servicios)
--    active=false oculta el producto sin borrarlo.
-- ─────────────────────────────────────────────
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  legacy_id     text unique,        -- id numérico del catálogo viejo (para migrar sin duplicar)
  title         text not null,
  description   text,
  category      text,               -- sección: "juegos", "streaming", etc.
  category_name text,               -- nombre visible de la sección
  image         text,
  price_label   text,
  badge         text,
  stock         text,
  options       jsonb default '[]'::jsonb,  -- [{name, price}]
  sort_order    integer default 0,
  active        boolean default true,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
create index if not exists products_category_idx on public.products(category);
create index if not exists products_active_idx   on public.products(active);

-- Asegurar la restricción única de legacy_id aunque la tabla ya existiera
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'products_legacy_id_key') then
    alter table public.products add constraint products_legacy_id_key unique (legacy_id);
  end if;
exception when others then null;
end $$;

-- Mantener tabla vieja de overrides por compatibilidad (no estorba)
create table if not exists public.products_admin (
  product_id  text primary key,
  title       text,
  category    text,
  image       text,
  price_label text,
  stock       text,
  badge       text,
  options     jsonb default '[]'::jsonb,
  updated_at  timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════════
-- 5. FUNCIONES DE SEGURIDAD
-- ═══════════════════════════════════════════════════════════════════

-- ¿El usuario actual es admin? (SECURITY DEFINER = puede leer is_admin
-- sin depender de las políticas RLS, evita recursión infinita)
create or replace function public.is_admin()
returns boolean
language sql security definer stable
set search_path = public
as $$
  select coalesce((select is_admin from public.vg_users where id = auth.uid()), false);
$$;

-- Buscar el id del que refirió, por su código (sin exponer toda la tabla)
create or replace function public.find_referrer(code text)
returns uuid
language sql security definer stable
set search_path = public
as $$
  select id from public.vg_users where referral_code = code limit 1;
$$;

-- Al crear un usuario en Auth, crea automáticamente su fila en vg_users
-- y su wallet. Así el registro no depende de que el cliente inserte bien.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.vg_users (id, name, phone, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', ''),
    coalesce(new.raw_user_meta_data->>'phone', ''),
    new.email
  )
  on conflict (id) do nothing;

  insert into public.vg_token_wallet (user_id, balance, total_purchases, total_earned)
  values (new.id, 0, 0, 0)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ═══════════════════════════════════════════════════════════════════
-- 6. RLS (Row Level Security)
--    OJO: A propósito NO tocamos las políticas de `orders` ni de tu
--    sistema de chat aquí, para no romper el flujo de pedidos que ya
--    funciona. Eso lo endurecemos en una fase posterior, ya con Auth
--    probado. Solo aseguramos identidad (usuarios/wallet/catálogo).
-- ═══════════════════════════════════════════════════════════════════
alter table public.vg_users        enable row level security;
alter table public.vg_token_wallet enable row level security;
alter table public.products        enable row level security;

-- Limpiar políticas viejas permisivas / previas
drop policy if exists anon_all_users              on public.vg_users;
drop policy if exists vg_users_insert_own          on public.vg_users;
drop policy if exists vg_users_select_own          on public.vg_users;
drop policy if exists vg_users_update_own          on public.vg_users;
drop policy if exists wallet_select                on public.vg_token_wallet;
drop policy if exists wallet_insert                on public.vg_token_wallet;
drop policy if exists wallet_update                on public.vg_token_wallet;
drop policy if exists products_public_read         on public.products;
drop policy if exists products_admin_write         on public.products;

-- ── vg_users ──
-- Cada quien inserta/lee/edita SU fila. El admin ve/edita todo.
-- También puedes leer a los que TÚ referiste (para el contador de referidos).
create policy vg_users_insert_own on public.vg_users
  for insert to authenticated
  with check (id = auth.uid());

create policy vg_users_select_own on public.vg_users
  for select to authenticated
  using (id = auth.uid() or referred_by = auth.uid() or public.is_admin());

create policy vg_users_update_own on public.vg_users
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- ── wallet ──  (lectura propia; escritura propia o admin)
create policy wallet_select on public.vg_token_wallet
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy wallet_insert on public.vg_token_wallet
  for insert to authenticated
  with check (user_id = auth.uid() or public.is_admin());

create policy wallet_update on public.vg_token_wallet
  for update to authenticated
  using (user_id = auth.uid() or public.is_admin())
  with check (user_id = auth.uid() or public.is_admin());

-- ── products (catálogo) ──
-- Lectura PÚBLICA (la tienda la ve todo el mundo). Escritura solo admin.
create policy products_public_read on public.products
  for select to anon, authenticated
  using (true);

create policy products_admin_write on public.products
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- (orders / products_admin / storage: se dejan como están para no romper
--  el flujo de pedidos y comprobantes que ya funciona. Se endurecen luego.)

-- ═══════════════════════════════════════════════════════════════════
-- 8. HACERTE ADMIN
--    Corre esto DESPUÉS de haber creado tu cuenta admin desde la web
--    (o desde Authentication → Users → Add user).
--    Cambia el correo por el tuyo:
-- ═══════════════════════════════════════════════════════════════════
-- update public.vg_users set is_admin = true
-- where id = (select id from auth.users where email = 'TU-CORREO-ADMIN@ejemplo.com');

-- ═══════════════════════════════════════════════════════════════════
-- LISTO. Fase 0 completa.
-- ═══════════════════════════════════════════════════════════════════
