-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · ARREGLO — columnas faltantes en la tabla products
-- Tu tabla "products" ya existía con columnas distintas antes de correr
-- el SQL de la Fase 0, así que "crear tabla si no existe" no le agregó
-- lo que faltaba (por eso el Catálogo no funcionaba: falta la columna
-- "title" y probablemente otras).
-- Este script agrega SOLO lo que falte, sin tocar lo que ya tienes.
-- Es idempotente: puedes correrlo varias veces sin romper nada.
-- ═══════════════════════════════════════════════════════════════════

alter table public.products add column if not exists legacy_id     text;
alter table public.products add column if not exists title         text;
alter table public.products add column if not exists description   text;
alter table public.products add column if not exists category      text;
alter table public.products add column if not exists category_name text;
alter table public.products add column if not exists image         text;
alter table public.products add column if not exists price_label   text;
alter table public.products add column if not exists badge         text;
alter table public.products add column if not exists stock         text;
alter table public.products add column if not exists options       jsonb default '[]'::jsonb;
alter table public.products add column if not exists sort_order    integer default 0;
alter table public.products add column if not exists active        boolean default true;
alter table public.products add column if not exists created_at    timestamptz default now();
alter table public.products add column if not exists updated_at    timestamptz default now();

-- por si title quedó con filas viejas en NULL, evita que la tabla se
-- quede en un estado raro al usarla (no falla si ya no hay filas NULL)
update public.products set title = coalesce(title, 'Sin título') where title is null;

-- asegurar el índice único de legacy_id (usado por "Migrar catálogo actual")
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'products_legacy_id_key') then
    alter table public.products add constraint products_legacy_id_key unique (legacy_id);
  end if;
exception when others then null;
end $$;

create index if not exists products_category_idx on public.products(category);
create index if not exists products_active_idx   on public.products(active);

-- refrescar el caché de esquema de PostgREST para que la API vea las
-- columnas nuevas de inmediato (si no, a veces tarda unos minutos)
notify pgrst, 'reload schema';

-- LISTO. Vuelve a abrir el panel admin → 📦 Catálogo, ya debería funcionar.
