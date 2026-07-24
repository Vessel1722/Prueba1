-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 5 — Oferta principal editable
-- Pega esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente: puedes correrlo varias veces sin romper nada.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.hero_offer (
  id            text primary key default 'main',
  title         text,
  subtitle      text,
  image         text,
  badge_text    text default 'OFERTAS',
  note          text,
  packages      jsonb default '[]'::jsonb,  -- [{name:"1,166 diamantes", price:161}, ...]
  active        boolean default false,       -- false = mostrar la oferta original de Free Fire
  updated_at    timestamptz default now()
);

alter table public.hero_offer enable row level security;

drop policy if exists hero_offer_public_read on public.hero_offer;
drop policy if exists hero_offer_admin_write on public.hero_offer;

-- Cualquiera puede LEER la oferta (se muestra en la tienda pública)
create policy hero_offer_public_read on public.hero_offer
  for select to anon, authenticated
  using (true);

-- Solo el admin puede escribir (usa la misma función is_admin() de la Fase 0)
create policy hero_offer_admin_write on public.hero_offer
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- LISTO. Fase 5 completa.
