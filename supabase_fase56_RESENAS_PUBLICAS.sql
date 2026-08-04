-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 56 — Que las reseñas se vean
--
-- Dos síntomas, una sola causa.
--
--   1. La pestaña Recomendaciones sale vacía aunque haya reseñas.
--   2. En la página de inicio, la sección "Clientes recientes" muestra
--      siempre a Luis M., Karla R. y Diego A. — tres ejemplos de relleno
--      que vienen escritos en el código. Ninguna reseña real aparecería
--      ahí aunque la publicaras.
--
-- La causa: las reseñas viven en la tabla orders, y desde la auditoría
-- de seguridad un visitante sin cuenta no puede leer esa tabla. Bien
-- así: ahí están los comprobantes de pago y los teléfonos de tus
-- clientes. Lo que estaba mal era pedirle las reseñas por ese camino.
--
-- Esta función devuelve SOLO las reseñas que ya aprobaste, y solo el
-- nombre, el servicio, el texto, las estrellas y la fecha. Nada de
-- teléfonos, comprobantes ni totales. Es la única puerta que se abre.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Las reseñas aprobadas, para quien sea
--
--    security definer para que pueda leer orders por dentro, pero solo
--    saca las columnas de arriba y solo de las filas ya publicadas: no
--    hay forma de asomarse a un pedido real desde aquí.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_resenas_publicas(p_limite integer default 6)
returns json
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(json_agg(x order by x.orden desc), '[]'::json)
    from (
      select
        coalesce(
          nullif(trim(o.client_name), ''),
          nullif(trim((o.items -> 0 ->> 'customer')), ''),
          'Cliente VG'
        )                                              as name,
        coalesce(
          nullif(trim((o.items -> 0 ->> 'service')), ''),
          'Servicio digital'
        )                                              as service,
        coalesce(
          nullif(trim((o.items -> 0 ->> 'review')), ''),
          nullif(trim(o.notes), '')
        )                                              as text,
        greatest(1, least(5,
          coalesce((o.items -> 0 ->> 'stars')::numeric, 5)::int
        ))                                             as stars,
        o.created_at                                   as date,
        o.created_at                                   as orden
      from public.orders o
     where o.source = 'recommendation'
       and o.status in ('validado', 'entregado')
       and coalesce(
             nullif(trim((o.items -> 0 ->> 'review')), ''),
             nullif(trim(o.notes), '')
           ) is not null
     order by o.created_at desc
     limit greatest(1, least(24, coalesce(p_limite, 6)))
    ) x;
$$;

-- anon es quien entra sin cuenta: justo el que más necesita leerlas
grant execute on function public.vg_resenas_publicas(integer) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2. RESULTADO — debe decir OK
--
--    "resenas_visibles" es cuántas verá un visitante ahora mismo. Si
--    sale 0 no está roto: es que todavía no has publicado ninguna desde
--    la pestaña Recomendaciones. Mientras sea 0 se siguen mostrando los
--    tres ejemplos de relleno.
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='vg_resenas_publicas')::text
    || ' de 1 funcion' as funcion,
  (select count(*) from public.orders
    where source='recommendation')::text || ' resena(s) en total' as total,
  json_array_length(public.vg_resenas_publicas(24))::text
    || ' resena(s) visibles' as resenas_visibles,
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname='public' and p.proname='vg_resenas_publicas') = 1
       then 'OK' else 'REVISAR' end as resultado;
