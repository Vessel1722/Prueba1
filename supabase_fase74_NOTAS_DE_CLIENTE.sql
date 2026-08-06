-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 74 — Notas y etiquetas por cliente
--
-- Paso 3 de 5.
--
-- Lo que sabes de un cliente hoy lo tienes en la cabeza: quién paga
-- rápido, quién reclama por todo, quién revende. Eso no se puede
-- delegar ni se recuerda a los seis meses. Aquí se guarda.
--
--   · notas       texto libre, lo que quieras apuntar
--   · etiquetas   marcas rápidas que se ven de un vistazo en la tabla
--
-- Solo el ADMINISTRADOR las ve y las escribe. Un operador no. Son
-- juicios tuyos sobre personas; no tienen por qué circular.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Las dos columnas
-- ─────────────────────────────────────────────────────────────
alter table public.vg_users add column if not exists notas text;
alter table public.vg_users add column if not exists etiquetas text[];
alter table public.vg_users add column if not exists notas_at timestamptz;


-- ─────────────────────────────────────────────────────────────
-- 2. Guardar
--
--    Por función y no por update directo: así el permiso se comprueba
--    en un solo sitio y queda apuntado en la bitácora.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_guardar_nota(
  p_id        text,
  p_notas     text default null,
  p_etiquetas text[] default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_nom text;
begin
  if not public.is_admin() then
    raise exception 'Solo el administrador puede escribir notas';
  end if;

  update public.vg_users
     set notas     = nullif(trim(coalesce(p_notas,'')), ''),
         etiquetas = coalesce(p_etiquetas, '{}'),
         notas_at  = now()
   where id::text = trim(p_id)
   returning coalesce(nullif(trim(name),''), phone, 'cliente') into v_nom;

  if v_nom is null then return false; end if;

  perform public.vg_apuntar('nota de cliente', v_nom,
    case when coalesce(array_length(p_etiquetas,1),0) > 0
         then array_to_string(p_etiquetas, ', ') else 'sin etiquetas' end);

  return true;
end;
$$;

grant execute on function public.vg_guardar_nota(text,text,text[]) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3. Leer las de varios clientes de una vez
--
--    La tabla del panel muestra 200 filas. Una consulta por fila serían
--    200 viajes; esta es uno solo.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_notas_de(p_ids text[])
returns table (id text, notas text, etiquetas text[])
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_admin() then return; end if;   -- devuelve vacío, no falla

  return query
    select u.id::text, u.notas, u.etiquetas
      from public.vg_users u
     where u.id::text = any(p_ids)
       and (u.notas is not null or coalesce(array_length(u.etiquetas,1),0) > 0);
end;
$$;

grant execute on function public.vg_notas_de(text[]) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 4. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_users'
      and column_name in ('notas','etiquetas','notas_at'))::text
    || ' de 3 columnas' as columnas,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('vg_guardar_nota','vg_notas_de'))::text
    || ' de 2 funciones' as funciones,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_users'
                and column_name in ('notas','etiquetas','notas_at')) = 3
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname in ('vg_guardar_nota','vg_notas_de')) = 2
       then 'OK' else 'REVISAR' end as resultado;
