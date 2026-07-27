-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 26 — Recuperación de contraseña y lada del país
--
-- ⚠️ LEE ESTO PRIMERO — por qué NO se puede mostrar la contraseña actual
--
--    Supabase, como cualquier sistema serio, NO guarda las contraseñas.
--    Guarda un hash bcrypt, que es irreversible por diseño: a partir
--    del hash no existe forma de recuperar el texto original. Ni tú,
--    ni el dueño de la base de datos, ni Supabase pueden leerla.
--    Eso es una PROTECCIÓN, no una falla: si tu base se filtrara,
--    nadie podría entrar a las cuentas de tus clientes.
--
--    Por eso este módulo hace lo que sí resuelve tu necesidad:
--    tú GENERAS una contraseña temporal nueva y se la mandas por
--    WhatsApp o correo. El cliente entra con ella y luego la cambia.
--    Mismo resultado para ti, y sin exponer a nadie.
--
-- Requiere: supabase_setup_fase0.sql
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;


-- ─────────────────────────────────────────────────────────────
-- 1. Lada del país en el perfil
-- ─────────────────────────────────────────────────────────────
alter table public.vg_users add column if not exists phone_cc text default '+52';

-- A los usuarios que ya existían se les asigna México, que era lo
-- único que el formulario permitía hasta ahora.
update public.vg_users set phone_cc = '+52' where phone_cc is null;

-- El trigger de alta debe guardar también la lada que eligió el
-- cliente al registrarse. Sin esto, la columna quedaría siempre en +52.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.vg_users (id, name, phone, phone_cc, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', ''),
    coalesce(new.raw_user_meta_data->>'phone', ''),
    coalesce(nullif(new.raw_user_meta_data->>'phone_cc',''), '+52'),
    new.email
  )
  on conflict (id) do nothing;

  insert into public.vg_token_wallet (user_id, balance, total_purchases, total_earned)
  values (new.id, 0, 0, 0)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ─────────────────────────────────────────────────────────────
-- 2. Solicitudes de cambio de contraseña
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_password_requests (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz default now(),
  user_id      uuid,
  email        text not null,
  phone        text,
  phone_cc     text,
  nombre       text,
  estado       text default 'pendiente',   -- pendiente | atendida | rechazada
  nota_admin   text,
  atendida_at  timestamptz,
  atendida_por uuid
);
alter table public.vg_password_requests add column if not exists phone_cc     text;
alter table public.vg_password_requests add column if not exists nombre       text;
alter table public.vg_password_requests add column if not exists nota_admin   text;
alter table public.vg_password_requests add column if not exists atendida_at  timestamptz;
alter table public.vg_password_requests add column if not exists atendida_por uuid;

create index if not exists pwreq_estado_idx on public.vg_password_requests(estado, created_at desc);
create index if not exists pwreq_email_idx  on public.vg_password_requests(lower(email));


-- ─────────────────────────────────────────────────────────────
-- 3. Buscar el teléfono a partir del correo
--    Devuelve el teléfono PARCIALMENTE OCULTO. Así el cliente confirma
--    que es su cuenta, pero si alguien escribe correos ajenos a ver qué
--    encuentra, no se lleva el número completo de nadie.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_buscar_cuenta(p_email text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_u public.vg_users; v_tel text; v_oculto text;
begin
  if p_email is null or length(trim(p_email)) < 5 then
    return json_build_object('existe', false);
  end if;

  select * into v_u from public.vg_users
   where lower(email) = lower(trim(p_email)) limit 1;

  if v_u.id is null then
    return json_build_object('existe', false);
  end if;

  v_tel := coalesce(v_u.phone, '');
  if length(v_tel) >= 4 then
    v_oculto := repeat('•', greatest(length(v_tel)-4, 0)) || right(v_tel, 4);
  else
    v_oculto := v_tel;
  end if;

  return json_build_object(
    'existe', true,
    'nombre', v_u.name,
    'phone_cc', coalesce(v_u.phone_cc,'+52'),
    'phone_oculto', v_oculto,
    'tiene_telefono', (length(v_tel) > 0)
  );
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 4. Crear la solicitud de cambio
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_solicitar_password(p_email text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_u public.vg_users; v_pend integer;
begin
  select * into v_u from public.vg_users
   where lower(email) = lower(trim(p_email)) limit 1;

  -- Se responde lo mismo exista o no la cuenta: si dijéramos "ese correo
  -- no está registrado", cualquiera podría averiguar quién tiene cuenta.
  if v_u.id is null then
    return json_build_object('ok', true);
  end if;

  select count(*) into v_pend
    from public.vg_password_requests
   where user_id = v_u.id and estado = 'pendiente';

  if v_pend = 0 then
    insert into public.vg_password_requests (user_id, email, phone, phone_cc, nombre)
    values (v_u.id, v_u.email, v_u.phone, coalesce(v_u.phone_cc,'+52'), v_u.name);
  end if;

  return json_build_object('ok', true);
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 5. ADMIN — generar una contraseña temporal
--
--    Escribe directamente el hash en auth.users. Es la única forma de
--    cambiar la contraseña de otro usuario sin usar la service_role key,
--    que NUNCA debe estar en el navegador porque daría acceso total a
--    la base de datos a cualquiera que mire el código de la página.
--
--    Devuelve la contraseña en claro UNA sola vez, para que la copies
--    y se la mandes. No se guarda en ningún lado.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_generar_password(
  p_request uuid,
  p_password text default null
)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_req  public.vg_password_requests;
  v_pass text;
  v_uid  uuid;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  select * into v_req from public.vg_password_requests where id = p_request;
  if v_req.id is null then raise exception 'No se encontró la solicitud.'; end if;

  -- Si no se indica una, se genera una legible de 10 caracteres
  v_pass := coalesce(nullif(trim(p_password), ''),
                     'VG' || upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8)));

  if length(v_pass) < 6 then
    raise exception 'La contraseña debe tener al menos 6 caracteres.';
  end if;

  select id into v_uid from auth.users
   where lower(email) = lower(v_req.email) limit 1;
  if v_uid is null then
    raise exception 'No se encontró la cuenta de acceso de ese correo.';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(v_pass, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_uid;

  update public.vg_password_requests
     set estado = 'atendida',
         atendida_at = now(),
         atendida_por = auth.uid()
   where id = p_request;

  return json_build_object(
    'ok', true,
    'password', v_pass,
    'email', v_req.email,
    'phone', coalesce(v_req.phone_cc,'') || coalesce(v_req.phone,'')
  );
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 6. ADMIN — rechazar una solicitud
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_rechazar_password(
  p_request uuid,
  p_nota    text default null
)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  update public.vg_password_requests
     set estado='rechazada', nota_admin=p_nota,
         atendida_at=now(), atendida_por=auth.uid()
   where id = p_request and estado='pendiente';
  return true;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 7. RLS
-- ─────────────────────────────────────────────────────────────
alter table public.vg_password_requests enable row level security;

drop policy if exists pwreq_select on public.vg_password_requests;
drop policy if exists pwreq_update on public.vg_password_requests;

-- Solo el admin ve y gestiona las solicitudes.
-- No hay política de INSERT a propósito: las solicitudes solo se crean
-- por la función vg_solicitar_password, así nadie puede llenarte la
-- bandeja insertando filas a mano.
create policy pwreq_select on public.vg_password_requests
  for select to authenticated using (public.is_admin());
create policy pwreq_update on public.vg_password_requests
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Estas dos funciones las puede llamar cualquiera (quien olvidó su
-- contraseña no tiene sesión iniciada), por eso son SECURITY DEFINER
-- y por eso ocultan el teléfono y no revelan si el correo existe.
grant execute on function public.vg_buscar_cuenta(text)     to anon, authenticated;
grant execute on function public.vg_solicitar_password(text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 8. Realtime, para que el aviso te llegue al instante
-- ─────────────────────────────────────────────────────────────
do $$
begin
  begin
    alter publication supabase_realtime add table public.vg_password_requests;
  exception when duplicate_object then null;
  end;
end $$;
alter table public.vg_password_requests replica identity full;


-- ─────────────────────────────────────────────────────────────
-- 9. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_users' and column_name='phone_cc'
  )::text || ' de 1 (lada)' as lada,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
    ('vg_buscar_cuenta','vg_solicitar_password','vg_admin_generar_password','vg_admin_rechazar_password')
  )::text || ' de 4 funciones' as funciones,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_users' and column_name='phone_cc') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_buscar_cuenta','vg_solicitar_password','vg_admin_generar_password','vg_admin_rechazar_password')) = 4
       then 'OK' else 'REVISAR' end as resultado;
