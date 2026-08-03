-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 50 — Renovaciones y reseñas automáticas
--
--   1. Cada pedido puede tener un periodo (1 mes, 3 meses...) y una
--      fecha de vencimiento. Con eso el cliente ve cuándo se le acaba
--      y tú ves a quién escribirle antes de que se vaya.
--
--   2. Al marcar un pedido como entregado, se deja solo un mensaje en
--      su chat pidiendo la reseña. Cero trabajo extra.
--
-- No se crean tablas nuevas: todo cuelga de orders, que ya existe.
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Columnas de renovación
-- ─────────────────────────────────────────────────────────────
alter table public.orders add column if not exists periodo_meses  numeric;
alter table public.orders add column if not exists vence_at       timestamptz;
alter table public.orders add column if not exists renovado_de    uuid;
alter table public.orders add column if not exists aviso_resena   boolean default false;

create index if not exists orders_vence_idx on public.orders(vence_at)
  where vence_at is not null;


-- ─────────────────────────────────────────────────────────────
-- 2. ADMIN — marcar entregado y fijar el vencimiento de una vez
--
--    p_meses = null  → producto que no vence (recargas, códigos)
--    p_meses = 1     → vence en un mes desde hoy
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_entregar(
  p_order uuid,
  p_meses numeric default null
)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_vence timestamptz;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  if p_meses is not null and p_meses > 0 then
    v_vence := now() + (p_meses || ' months')::interval;
  end if;

  update public.orders
     set status        = 'entregado',
         periodo_meses = p_meses,
         vence_at      = v_vence
   where id = p_order;

  return json_build_object('ok', true, 'vence_at', v_vence);
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3. CLIENTE — sus suscripciones activas
--
--    Devuelve lo que sigue vigente y lo que venció hace poco, que es
--    justo a quien hay que ofrecerle renovar.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_mis_suscripciones()
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_res json;
begin
  if v_uid is null then return '[]'::json; end if;

  select coalesce(json_agg(x order by x.vence_at), '[]'::json) into v_res
    from (
      select o.id,
             coalesce(nullif(trim(o.product_name),''),
                      nullif(trim((o.items -> 0 ->> 'title')),''),
                      'Suscripción')            as producto,
             o.product_option                    as opcion,
             o.total,
             o.periodo_meses,
             o.vence_at,
             greatest(0, extract(day from (o.vence_at - now()))::int) as dias,
             (o.vence_at < now())                as vencida
        from public.orders o
       where o.user_id::text = v_uid::text
         and o.vence_at is not null
         and o.status = 'entregado'
         and o.vence_at > now() - interval '30 days'
    ) x;

  return v_res;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 4. ADMIN — a quién le vence pronto
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_por_vencer(p_dias integer default 7)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_res json;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  select coalesce(json_agg(x order by x.vence_at), '[]'::json) into v_res
    from (
      select o.id,
             coalesce(nullif(trim(o.product_name),''),
                      nullif(trim((o.items -> 0 ->> 'title')),''),
                      'Suscripción')  as producto,
             o.total,
             o.vence_at,
             extract(day from (o.vence_at - now()))::int as dias,
             coalesce(nullif(trim(u.name),''), o.customer_name, 'Cliente') as cliente,
             coalesce(u.phone, o.customer_phone, '') as telefono
        from public.orders o
        left join public.vg_users u on u.id::text = o.user_id::text
       where o.vence_at is not null
         and o.status = 'entregado'
         and o.vence_at between now() - interval '3 days'
                            and now() + (p_dias || ' days')::interval
    ) x;

  return v_res;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 5. Pedir la reseña sola, al entregar
--
--    Se dispara cuando el estado pasa a 'entregado'. La bandera
--    aviso_resena evita repetirlo si vuelves a guardar el pedido.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_pedir_resena()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.status = 'entregado'
     and coalesce(old.status,'') <> 'entregado'
     and coalesce(new.aviso_resena, false) = false
     and coalesce(new.source,'') <> 'recommendation'
  then
    begin
      insert into public.vg_live_chat_messages
        (thread_type, thread_ref, order_id, sender_role, sender_name, message)
      values
        ('order', new.id::text, new.id::text, 'system', 'Vessel Games',
         '¡Listo! Tu pedido quedó entregado.' || chr(10) || chr(10) ||
         'Si todo salió bien, ¿nos dejas tu reseña? Nos ayuda un montón y ' ||
         'le sirve a quien está por comprar por primera vez.' || chr(10) || chr(10) ||
         'Puedes dejarla en la página de inicio, en la sección de reseñas.' || chr(10) ||
         'Y si algo no salió como esperabas, contéstanos por aquí y lo arreglamos.');

      new.aviso_resena := true;
    exception when others then
      raise warning 'vg_pedir_resena: no se pudo dejar el mensaje (%)', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists vg_orders_pedir_resena on public.orders;
create trigger vg_orders_pedir_resena
  before update on public.orders
  for each row execute function public.vg_pedir_resena();


-- ─────────────────────────────────────────────────────────────
-- 6. Permisos
-- ─────────────────────────────────────────────────────────────
grant execute on function public.vg_admin_entregar(uuid,numeric)  to authenticated;
grant execute on function public.vg_mis_suscripciones()           to authenticated;
grant execute on function public.vg_admin_por_vencer(integer)     to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 7. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='orders'
      and column_name in ('periodo_meses','vence_at','renovado_de','aviso_resena')
  )::text || ' de 4 columnas' as columnas,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
    ('vg_admin_entregar','vg_mis_suscripciones','vg_admin_por_vencer','vg_pedir_resena')
  )::text || ' de 4 funciones' as funciones,
  (select count(*) from pg_trigger where tgname='vg_orders_pedir_resena')::text
    || ' de 1 disparador' as disparador,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='orders'
                and column_name in ('periodo_meses','vence_at','renovado_de','aviso_resena')) = 4
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_admin_entregar','vg_mis_suscripciones','vg_admin_por_vencer','vg_pedir_resena')) = 4
        and (select count(*) from pg_trigger where tgname='vg_orders_pedir_resena') = 1
       then 'OK' else 'REVISAR' end as resultado;
