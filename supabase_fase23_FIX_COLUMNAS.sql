-- ═══════════════════════════════════════════════════════════════════
-- FASE 23 · ARREGLO — columnas faltantes en las tablas de tokens
--
-- Síntoma:
--   ERROR: 42703: column "motivo" does not exist
--
-- Causa:
--   Alguna de las tablas de tokens ya existía en tu base con otra
--   estructura. El "create table if not exists" la respetó tal cual
--   (por eso no la rompió), pero eso dejó fuera las columnas nuevas.
--
-- Corre PRIMERO este archivo y DESPUÉS vuelve a correr
-- supabase_fase23_TOKENS.sql completo.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Historial de movimientos
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_tx (id bigserial primary key);

alter table public.vg_token_tx add column if not exists created_at timestamptz default now();
alter table public.vg_token_tx add column if not exists user_id    uuid;
alter table public.vg_token_tx add column if not exists cantidad   numeric;
alter table public.vg_token_tx add column if not exists motivo     text;
alter table public.vg_token_tx add column if not exists order_id   text;
alter table public.vg_token_tx add column if not exists detalle    text;
alter table public.vg_token_tx add column if not exists hecho_por  uuid;

-- Si la tabla traía columnas viejas obligatorias, se liberan para que
-- no bloqueen los INSERT nuevos.
do $$
declare col text;
begin
  foreach col in array array['tipo','type','amount','monto','reason','descripcion','concepto','balance_after']
  loop
    begin
      execute format('alter table public.vg_token_tx alter column %I drop not null', col);
    exception when undefined_column then null;
    end;
  end loop;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 2. Wallet
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_wallet (id uuid primary key default gen_random_uuid());

alter table public.vg_token_wallet add column if not exists user_id         uuid;
alter table public.vg_token_wallet add column if not exists balance         numeric default 0;
alter table public.vg_token_wallet add column if not exists total_purchases integer default 0;
alter table public.vg_token_wallet add column if not exists total_earned    numeric default 0;
alter table public.vg_token_wallet add column if not exists total_referidos integer default 0;
alter table public.vg_token_wallet add column if not exists updated_at      timestamptz default now();

-- user_id debe ser único: es la clave del "on conflict (user_id)"
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.vg_token_wallet'::regclass
       and contype in ('u','p')
       and pg_get_constraintdef(oid) like '%(user_id)%'
  ) then
    begin
      alter table public.vg_token_wallet add constraint vg_token_wallet_user_unico unique (user_id);
    exception when others then
      raise notice 'No se pudo crear la restricción única de user_id: %', sqlerrm;
    end;
  end if;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 3. Configuración de recompensas
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_config (clave text primary key);
alter table public.vg_token_config add column if not exists valor numeric;
alter table public.vg_token_config add column if not exists nota  text;

-- valor no puede quedar nulo en las filas que se van a insertar
update public.vg_token_config set valor = 0 where valor is null;


-- ─────────────────────────────────────────────────────────────
-- 4. Recargar el caché del esquema
-- ─────────────────────────────────────────────────────────────
notify pgrst, 'reload schema';


-- ─────────────────────────────────────────────────────────────
-- 5. RESULTADO — deben aparecer las 7 columnas del historial
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_token_tx'
      and column_name in ('created_at','user_id','cantidad','motivo','order_id','detalle','hecho_por')
  )::text || ' de 7 (historial)' as vg_token_tx,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_token_wallet'
      and column_name in ('user_id','balance','total_purchases','total_earned','total_referidos','updated_at')
  )::text || ' de 6 (wallet)' as vg_token_wallet,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_token_tx'
                and column_name in ('created_at','user_id','cantidad','motivo','order_id','detalle','hecho_por')) = 7
        and (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_token_wallet'
                and column_name in ('user_id','balance','total_purchases','total_earned','total_referidos','updated_at')) = 6
       then 'OK — ahora corre supabase_fase23_TOKENS.sql completo'
       else 'REVISAR' end as resultado;
