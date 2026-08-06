-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 66 — Cuánto tardas en entregar, de verdad
--
-- Hoy la página promete "20 minutos a 2 horas" porque está escrito a
-- mano. Con esto lo dice tu propio historial: "entrega promedio hoy,
-- 34 minutos". Al cliente le da confianza porque es un número que sale
-- de tus entregas, y a ti te avisa cuando te estás tardando más de lo
-- normal sin que tengas que darte cuenta tú.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. La hora en que se entregó
--
--    No existía. Se usaba updated_at, pero esa cambia cada vez que se
--    toca el pedido por cualquier motivo, así que un pedido editado
--    tres días después parecía haber tardado tres días.
-- ─────────────────────────────────────────────────────────────
alter table public.orders add column if not exists entregado_at timestamptz;

create index if not exists orders_entregado_idx on public.orders(entregado_at)
  where entregado_at is not null;


-- ─────────────────────────────────────────────────────────────
-- 2. Se marca sola al entregar
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_marcar_entrega()
returns trigger language plpgsql as $$
begin
  if new.status = 'entregado' and coalesce(old.status,'') <> 'entregado'
     and new.entregado_at is null then
    new.entregado_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists vg_orders_marcar_entrega on public.orders;
create trigger vg_orders_marcar_entrega
  before update on public.orders
  for each row execute function public.vg_marcar_entrega();


-- ─────────────────────────────────────────────────────────────
-- 3. Los pedidos que ya estaban entregados
--
--    Se les pone updated_at como aproximación, y SOLO si es posterior
--    a la creación y da un tiempo creíble (menos de 24 horas). Los que
--    no cumplan se quedan sin marca: es mejor calcular el promedio con
--    menos datos buenos que con muchos inventados.
-- ─────────────────────────────────────────────────────────────
update public.orders
   set entregado_at = updated_at
 where status = 'entregado'
   and entregado_at is null
   and updated_at is not null
   and updated_at > created_at
   and updated_at < created_at + interval '24 hours';


-- ─────────────────────────────────────────────────────────────
-- 4. El promedio
--
--    Se usa la MEDIANA y no el promedio a secas: un pedido que se
--    quedó abierto toda la noche arrastraría el promedio a tres horas
--    y daría una cifra que no representa lo que vives normalmente.
--    La mediana aguanta esos casos raros.
--
--    Se descartan también las entregas de más de 12 horas: esas no son
--    tu ritmo, son un pedido que se quedó pendiente.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_tiempo_entrega(p_dias integer default 7)
returns json
language sql
security definer
stable
set search_path = public
as $$
  with buenas as (
    select extract(epoch from (entregado_at - created_at))/60 as minutos
      from public.orders
     where status = 'entregado'
       and entregado_at is not null
       and coalesce(source,'') <> 'recommendation'
       and entregado_at >= now() - (greatest(1, coalesce(p_dias,7)) || ' days')::interval
       and entregado_at > created_at
       and entregado_at < created_at + interval '12 hours'
  )
  select json_build_object(
    'muestras',  (select count(*) from buenas),
    'mediana',   (select round(percentile_cont(0.5) within group (order by minutos)::numeric)
                    from buenas),
    'mas_rapido',(select round(min(minutos)::numeric) from buenas),
    'dias',      greatest(1, coalesce(p_dias,7))
  );
$$;

-- Lo puede leer cualquiera: es el dato que se enseña en la tienda.
grant execute on function public.vg_tiempo_entrega(integer) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 5. RESULTADO — debe decir OK
--
--    Si "muestras" sale 0 no está roto: es que todavía no hay entregas
--    con hora registrada. Se irá llenando solo con cada pedido que
--    marques como entregado a partir de ahora.
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='orders'
      and column_name='entregado_at')::text || ' de 1 columna' as columna,
  (select count(*) from pg_trigger where tgname='vg_orders_marcar_entrega')::text
    || ' de 1 disparador' as disparador,
  (select count(*) from public.orders where entregado_at is not null)::text
    || ' pedidos con hora de entrega' as historial,
  public.vg_tiempo_entrega(30)::text as promedio_30_dias,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='orders'
                and column_name='entregado_at') = 1
        and (select count(*) from pg_trigger
              where tgname='vg_orders_marcar_entrega') = 1
       then 'OK' else 'REVISAR' end as resultado;
