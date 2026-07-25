-- ═══════════════════════════════════════════════════════════════════
-- FASE 17 · ARREGLO — columnas faltantes en vg_support_tickets
--
-- Síntoma:
--   No se pudo enviar: Could not find the 'account_email' column of
--   'vg_support_tickets' in the schema cache
--
-- Causa (la misma del chat):
--   La tabla ya existía con otra estructura, así que el
--   "create table if not exists" del script principal la dejó intacta
--   y nunca se agregaron las columnas nuevas.
--
-- Incluye además el cambio pedido: correo y contraseña dejan de ser
-- obligatorios, porque solo aplican a servicios de streaming o de
-- cuentas. Un código, unas monedas o un trámite no tienen credenciales
-- que reportar.
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Columnas del formulario de reporte
-- ─────────────────────────────────────────────────────────────
alter table public.vg_support_tickets add column if not exists created_at          timestamptz default now();
alter table public.vg_support_tickets add column if not exists updated_at          timestamptz default now();
alter table public.vg_support_tickets add column if not exists user_id             uuid;
alter table public.vg_support_tickets add column if not exists order_id            text;
alter table public.vg_support_tickets add column if not exists product_name        text;
alter table public.vg_support_tickets add column if not exists purchase_date       date;
alter table public.vg_support_tickets add column if not exists subscription_period text;
alter table public.vg_support_tickets add column if not exists account_email       text;
alter table public.vg_support_tickets add column if not exists account_password    text;
alter table public.vg_support_tickets add column if not exists problem_description text;
alter table public.vg_support_tickets add column if not exists status              text default 'abierto';
alter table public.vg_support_tickets add column if not exists customer_name       text;
alter table public.vg_support_tickets add column if not exists customer_phone      text;
alter table public.vg_support_tickets add column if not exists admin_notes         text;


-- ─────────────────────────────────────────────────────────────
-- 2. Correo y contraseña YA NO son obligatorios
--    Solo aplican a streaming / cuentas (Netflix, Max, Disney,
--    Prime Video, perfiles...). Para códigos, monedas, licencias o
--    trámites el cliente deja esos campos vacíos.
-- ─────────────────────────────────────────────────────────────
alter table public.vg_support_tickets alter column account_email    drop not null;
alter table public.vg_support_tickets alter column account_password drop not null;

-- Estos sí siguen siendo obligatorios (son los que identifican la falla)
do $$
begin
  begin alter table public.vg_support_tickets alter column product_name        set not null; exception when others then null; end;
  begin alter table public.vg_support_tickets alter column problem_description set not null; exception when others then null; end;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 3. Quitar NOT NULL de posibles columnas viejas que estorben
-- ─────────────────────────────────────────────────────────────
do $$
declare col text;
begin
  foreach col in array array['titulo','title','asunto','subject','descripcion','mensaje','body','correo','password','email']
  loop
    begin
      execute format('alter table public.vg_support_tickets alter column %I drop not null', col);
    exception when undefined_column then null;
    end;
  end loop;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 4. Índices
-- ─────────────────────────────────────────────────────────────
create index if not exists tickets_user_idx    on public.vg_support_tickets(user_id);
create index if not exists tickets_status_idx  on public.vg_support_tickets(status);
create index if not exists tickets_created_idx on public.vg_support_tickets(created_at desc);


-- ─────────────────────────────────────────────────────────────
-- 5. Recargar el caché del esquema (esto es lo que quita el error
--    "in the schema cache")
-- ─────────────────────────────────────────────────────────────
notify pgrst, 'reload schema';


-- ─────────────────────────────────────────────────────────────
-- 6. RESULTADO — deben aparecer las 14 columnas
-- ─────────────────────────────────────────────────────────────
select
  count(*)::text || ' de 14 columnas' as tickets,
  case when count(*) = 14 then 'OK' else 'REVISAR' end as resultado
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'vg_support_tickets'
  and column_name in ('created_at','updated_at','user_id','order_id','product_name',
                      'purchase_date','subscription_period','account_email','account_password',
                      'problem_description','status','customer_name','customer_phone','admin_notes');
