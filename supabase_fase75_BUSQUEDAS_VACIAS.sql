-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 75 — Qué te piden que no vendes
--
-- Paso 4 de 5.
--
-- Cada vez que alguien busca algo y no aparece nada, se apunta. Esa
-- lista es la mejor pista que vas a tener de qué añadir al catálogo:
-- no son ideas tuyas, es gente que ya vino con la intención de pagar
-- y se fue con las manos vacías.
--
-- Lo escribe cualquier visitante (aún sin cuenta), pero solo por la
-- función: la tabla no se puede tocar directo. Y solo tú la lees.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. La tabla
--
--    Una fila por búsqueda distinta, no por vez. "vbucks" buscado 40
--    veces es una fila con veces=40, no 40 filas.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_busquedas_vacias (
  clave    text primary key,          -- el texto sin acentos ni mayúsculas
  texto    text not null,             -- tal y como lo escribieron
  veces    integer not null default 1,
  primera  timestamptz default now(),
  ultima   timestamptz default now(),
  atendida boolean default false      -- ya lo diste de alta / no aplica
);

create index if not exists vg_busq_veces_idx
  on public.vg_busquedas_vacias(veces desc);

alter table public.vg_busquedas_vacias enable row level security;
-- Sin políticas a propósito: nadie entra por la puerta, solo por las
-- funciones de abajo.


-- ─────────────────────────────────────────────────────────────
-- 2. Apuntar una búsqueda fallida
--
--    Abierta a visitantes sin cuenta: la mayoría de quien busca
--    todavía no se ha registrado, y son justo los que más importan.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_apuntar_busqueda(p_texto text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_txt   text;
  v_clave text;
  v_filas integer;
begin
  v_txt := trim(regexp_replace(coalesce(p_texto,''), '\s+', ' ', 'g'));
  if length(v_txt) < 3 or length(v_txt) > 60 then return; end if;

  -- Sin acentos y en minúsculas, para que "créditos" y "creditos"
  -- sean la misma fila.
  v_clave := translate(lower(v_txt),
              'áàäâéèëêíìïîóòöôúùüûñçÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑÇ',
              'aaaaeeeeiiiioooouuuuncaaaaeeeeiiiioooouuuunc');

  -- Tope de seguridad: si algún día alguien se dedica a escribir
  -- basura, deja de crear filas nuevas pero sigue contando las que ya
  -- existen. Así no se llena la base.
  select count(*) into v_filas from public.vg_busquedas_vacias;

  insert into public.vg_busquedas_vacias (clave, texto)
  select v_clave, v_txt
   where v_filas < 4000
      or exists (select 1 from public.vg_busquedas_vacias b where b.clave = v_clave)
  on conflict (clave) do update
    set veces    = public.vg_busquedas_vacias.veces + 1,
        ultima   = now(),
        texto    = excluded.texto,
        atendida = false;   -- si vuelven a pedirlo, vuelve a la lista
exception when others then
  null;   -- apuntar nunca debe romperle la búsqueda a un cliente
end;
$$;

grant execute on function public.vg_apuntar_busqueda(text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3. Leerla (solo administrador)
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_busquedas_top(p_dias integer default 60)
returns table (clave text, texto text, veces integer,
               ultima timestamptz, atendida boolean)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_admin() then return; end if;

  return query
    select b.clave, b.texto, b.veces, b.ultima, b.atendida
      from public.vg_busquedas_vacias b
     where b.ultima > now() - (greatest(coalesce(p_dias,60),1) || ' days')::interval
     order by b.atendida asc, b.veces desc, b.ultima desc
     limit 150;
end;
$$;

grant execute on function public.vg_busquedas_top(integer) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 4. Marcar una como atendida / quitarla
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_busqueda_atendida(
  p_clave text, p_val boolean default true)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then return false; end if;
  update public.vg_busquedas_vacias set atendida = coalesce(p_val,true)
   where clave = p_clave;
  return found;
end;
$$;

grant execute on function public.vg_busqueda_atendida(text, boolean) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 5. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.tables
    where table_schema='public' and table_name='vg_busquedas_vacias')::text
    || ' de 1 tabla' as tabla,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
      ('vg_apuntar_busqueda','vg_busquedas_top','vg_busqueda_atendida'))::text
    || ' de 3 funciones' as funciones,
  case when (select count(*) from information_schema.tables
              where table_schema='public' and table_name='vg_busquedas_vacias') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
                ('vg_apuntar_busqueda','vg_busquedas_top','vg_busqueda_atendida')) = 3
       then 'OK' else 'REVISAR' end as resultado;
