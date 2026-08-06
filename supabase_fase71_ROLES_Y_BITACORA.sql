-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 71 — Segundo administrador y registro de acciones
--
-- Paso 1 de 5. Aquí solo va la base en la base de datos; la parte que
-- se ve en el panel viene después.
--
-- Dos cosas que van juntas a propósito:
--
--   · Un rol de OPERADOR: puede atender pedidos y contestar el chat,
--     pero no borrar usuarios, ni tocar precios, ni ver la conexión.
--
--   · Una BITÁCORA de quién hizo qué. Delegar sin registro es apostar.
--     Con registro, delegar es normal.
--
-- NO se toca is_admin(). Esa función ya decide quién es administrador
-- en media página, y cambiarla ahora sería mover el suelo. Se añade al
-- lado, no encima.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. El rol
--
--    Tres valores posibles:
--      null        cliente normal
--      'operador'  atiende pedidos y chat
--      'admin'     todo
--
--    Quien ya es administrador por is_admin() lo sigue siendo aunque
--    esta columna esté vacía. Así nadie se queda fuera de su panel por
--    correr este SQL.
-- ─────────────────────────────────────────────────────────────
alter table public.vg_users add column if not exists rol text;

alter table public.vg_users drop constraint if exists vg_users_rol_valido;
alter table public.vg_users add constraint vg_users_rol_valido
  check (rol is null or rol in ('operador','admin'));


-- ─────────────────────────────────────────────────────────────
-- 2. ¿Puede atender pedidos?
--
--    Cierto para administradores y para operadores. Es el permiso que
--    hace falta para entregar y para contestar el chat.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_puede_atender()
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if auth.uid() is null then return false; end if;
  if public.is_admin() then return true; end if;
  return exists (
    select 1 from public.vg_users
     where id::text = auth.uid()::text
       and rol in ('operador','admin')
  );
end;
$$;

grant execute on function public.vg_puede_atender() to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3. La bitácora
--
--    Una fila por acción. No se borra nunca desde la página: un
--    registro que se puede borrar no sirve de nada.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_bitacora (
  id         bigserial primary key,
  creado_at  timestamptz default now(),
  quien      uuid,
  quien_nom  text,
  accion     text not null,
  sobre      text,
  detalle    text
);

create index if not exists vg_bitacora_fecha_idx on public.vg_bitacora(creado_at desc);

alter table public.vg_bitacora enable row level security;

-- Solo los administradores completos la leen. Un operador no tiene por
-- qué ver lo que hacen los demás.
drop policy if exists bitacora_lee_admin on public.vg_bitacora;
create policy bitacora_lee_admin on public.vg_bitacora
  for select to authenticated using (public.is_admin());

-- Nadie escribe directo: solo por la función de abajo, que es la que
-- pone quién fue. Si la página pudiera escribir a mano, cualquiera
-- podría firmar con el nombre de otro.
drop policy if exists bitacora_no_escribe on public.vg_bitacora;


-- ─────────────────────────────────────────────────────────────
-- 4. Apuntar una acción
--
--    El "quién" no lo manda la página: lo saca la función de la sesión.
--    Así nadie puede apuntar algo a nombre de otro.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_apuntar(
  p_accion  text,
  p_sobre   text default null,
  p_detalle text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_nom text;
begin
  if auth.uid() is null then return; end if;

  select coalesce(nullif(trim(name),''), email, 'Sin nombre')
    into v_nom from public.vg_users where id::text = auth.uid()::text;

  insert into public.vg_bitacora (quien, quien_nom, accion, sobre, detalle)
  values (auth.uid(), coalesce(v_nom,'Desconocido'),
          left(coalesce(p_accion,'?'), 60),
          left(coalesce(p_sobre,''), 60),
          left(coalesce(p_detalle,''), 400));
exception when others then
  -- Que no se pueda apuntar nunca debe impedir la acción en sí.
  null;
end;
$$;

grant execute on function public.vg_apuntar(text,text,text) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 5. Los cambios de estado se apuntan solos
--
--    Lo importante es que quede registrado aunque nadie se acuerde de
--    llamar a la función desde la página.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_apuntar_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_nom text;
begin
  if coalesce(new.status,'') = coalesce(old.status,'') then return new; end if;
  if auth.uid() is null then return new; end if;

  begin
    select coalesce(nullif(trim(name),''), email, 'Sin nombre')
      into v_nom from public.vg_users where id::text = auth.uid()::text;

    insert into public.vg_bitacora (quien, quien_nom, accion, sobre, detalle)
    values (auth.uid(), coalesce(v_nom,'Desconocido'), 'cambio de estado',
            'pedido ' || new.id::text,
            coalesce(old.status,'(nuevo)') || ' → ' || coalesce(new.status,'?'));
  exception when others then null;
  end;

  return new;
end;
$$;

drop trigger if exists vg_orders_apuntar on public.orders;
create trigger vg_orders_apuntar
  after update on public.orders
  for each row execute function public.vg_apuntar_pedido();


-- ─────────────────────────────────────────────────────────────
-- 6. CÓMO NOMBRAR A UN OPERADOR
--
--    Cuando quieras que alguien te ayude, con su correo:
--
--      update public.vg_users set rol = 'operador'
--       where email = 'correo-de-tu-ayudante@ejemplo.com';
--
--    Para quitarle el permiso:
--
--      update public.vg_users set rol = null
--       where email = 'correo-de-tu-ayudante@ejemplo.com';
--
--    Para ver el registro de los últimos días:
--
--      select creado_at, quien_nom, accion, sobre, detalle
--        from public.vg_bitacora
--       order by creado_at desc limit 50;
-- ─────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────
-- 7. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_users' and column_name='rol')::text
    || ' de 1 columna' as columna,
  (select count(*) from information_schema.tables
    where table_schema='public' and table_name='vg_bitacora')::text
    || ' de 1 tabla' as tabla,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('vg_puede_atender','vg_apuntar','vg_apuntar_pedido'))::text
    || ' de 3 funciones' as funciones,
  (select count(*) from pg_trigger where tgname='vg_orders_apuntar')::text
    || ' de 1 disparador' as disparador,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_users'
                and column_name='rol') = 1
        and (select count(*) from information_schema.tables
              where table_schema='public' and table_name='vg_bitacora') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname in ('vg_puede_atender','vg_apuntar','vg_apuntar_pedido')) = 3
        and (select count(*) from pg_trigger where tgname='vg_orders_apuntar') = 1
       then 'OK' else 'REVISAR' end as resultado;
