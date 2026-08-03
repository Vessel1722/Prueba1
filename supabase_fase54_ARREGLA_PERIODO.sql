-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 54 — Arregla el periodo al entregar
--
-- El error:
--   invalid input syntax for type uuid: "106"
--
-- Por qué:
--   En la fase 50 di por hecho que orders.id era un uuid, como lo es
--   vg_users.id. No lo es: tus pedidos se numeran 105, 106, 107. Al
--   pasarle "106" a una función que pide uuid, Postgres se niega.
--
-- La solución no es adivinar el tipo, sino dejar de depender de él: la
-- función recibe el número como texto y compara id::text. Así funciona
-- ahora y seguiría funcionando si algún día cambiaras el tipo.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Fuera la versión vieja
--
--    Tiene que irse, no basta con crear la nueva al lado: si quedan
--    las dos, PostgREST no sabe a cuál llamar y responde "no se pudo
--    elegir la mejor función candidata".
-- ─────────────────────────────────────────────────────────────
drop function if exists public.vg_admin_entregar(uuid, numeric);


-- ─────────────────────────────────────────────────────────────
-- 2. La buena
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_entregar(
  p_order text,
  p_meses numeric default null
)
returns json
language plpgsql security definer
set search_path = public
as $$
declare
  v_vence timestamptz;
  v_n     integer;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  if coalesce(trim(p_order),'') = '' then
    raise exception 'Falta indicar el pedido.';
  end if;

  if p_meses is not null and p_meses > 0 then
    v_vence := now() + (p_meses || ' months')::interval;
  end if;

  update public.orders
     set status        = 'entregado',
         periodo_meses = p_meses,
         vence_at      = v_vence
   where id::text = trim(p_order);

  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'No encontré el pedido %.', p_order;
  end if;

  return json_build_object('ok', true, 'vence_at', v_vence);
end;
$$;

grant execute on function public.vg_admin_entregar(text, numeric) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3. La columna renovado_de tenía el mismo error de bulto
--
--    Se creó como uuid para guardar "de qué pedido viene esta
--    renovación", pero un pedido no se identifica con un uuid. Nunca se
--    ha usado (está toda en nulo), así que se puede rehacer sin perder
--    nada. La condición del IF lo comprueba antes de tocarla.
-- ─────────────────────────────────────────────────────────────
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='orders'
       and column_name='renovado_de' and data_type='uuid'
  ) and not exists (
    select 1 from public.orders where renovado_de is not null
  ) then
    alter table public.orders drop column renovado_de;
    alter table public.orders add  column renovado_de text;
  end if;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 4. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select data_type from information_schema.columns
    where table_schema='public' and table_name='orders' and column_name='id')
    as tipo_de_id_de_pedido,
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='vg_admin_entregar')::text
    || ' version(es) de vg_admin_entregar' as versiones,
  case when (select count(*) from pg_proc p
               join pg_namespace n on n.oid = p.pronamespace
              where n.nspname='public' and p.proname='vg_admin_entregar'
                and pg_get_function_identity_arguments(p.oid) like 'text%') = 1
        and (select count(*) from pg_proc p
               join pg_namespace n on n.oid = p.pronamespace
              where n.nspname='public' and p.proname='vg_admin_entregar') = 1
       then 'OK' else 'REVISAR' end as resultado;
