-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 33
--   1. Premios de tokens editables desde el panel (con foto)
--   2. Portada del inicio editable desde el panel (video o imagen)
--
-- Requiere: supabase_fase23_TOKENS.sql, supabase_fase25_RECOMPENSAS.sql
--           y supabase_fase21_STORAGE_IMAGENES.sql
-- Es idempotente: puedes correrlo las veces que quieras.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Foto en los premios
--    La tabla ya existía, así que se añade la columna suelta.
--    "create table if not exists" no habría hecho nada.
-- ─────────────────────────────────────────────────────────────
alter table public.vg_token_rewards add column if not exists imagen text;


-- ─────────────────────────────────────────────────────────────
-- 2. El cliente tiene que recibir la foto
--    vg_mis_recompensas no seleccionaba 'imagen', así que por mucho que
--    la guardaras en el panel, la tarjeta del cliente nunca la vería.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_mis_recompensas()
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_saldo numeric; v_res json;
begin
  select coalesce(balance,0) into v_saldo from public.vg_token_wallet where user_id = v_uid;
  v_saldo := coalesce(v_saldo,0);

  select json_build_object(
    'saldo', v_saldo,
    'pendiente', (
      select json_build_object('nombre', reward_nombre, 'fecha', created_at)
        from public.vg_token_redemptions
       where user_id = v_uid and estado='solicitada'
       order by created_at desc limit 1
    ),
    'recompensas', coalesce((
      select json_agg(x) from (
        select r.id, r.nombre, r.descripcion, r.costo, r.icono, r.imagen,
               (v_saldo >= r.costo) as alcanza
          from public.vg_token_rewards r
         where r.activo = true
         order by r.orden, r.costo
      ) x
    ), '[]'::json),
    'historial', coalesce((
      select json_agg(h) from (
        select reward_nombre, costo, estado, created_at, nota_admin, entregada_at
          from public.vg_token_redemptions
         where user_id = v_uid
         order by created_at desc limit 10
      ) h
    ), '[]'::json)
  ) into v_res;

  return v_res;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3. Guardar y borrar premios desde el panel
--
--    Se hace con funciones y no dejando que el navegador escriba
--    directo en la tabla: así la comprobación de administrador vive en
--    la base de datos, donde nadie la puede saltar tocando el código de
--    la página desde las herramientas del navegador.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_guardar_premio(
  p_id          uuid    default null,
  p_nombre      text    default '',
  p_descripcion text    default '',
  p_costo       numeric default 0,
  p_icono       text    default '🎁',
  p_imagen      text    default null,
  p_activo      boolean default true,
  p_orden       integer default 0
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  if length(trim(coalesce(p_nombre,''))) = 0 then
    raise exception 'El premio necesita un nombre.';
  end if;
  if coalesce(p_costo,0) <= 0 then
    raise exception 'El costo en tokens debe ser mayor que cero.';
  end if;

  if p_id is null then
    insert into public.vg_token_rewards (nombre, descripcion, costo, icono, imagen, activo, orden)
    values (trim(p_nombre), nullif(trim(coalesce(p_descripcion,'')),''), p_costo,
            nullif(trim(coalesce(p_icono,'')),''), nullif(trim(coalesce(p_imagen,'')),''),
            coalesce(p_activo,true), coalesce(p_orden,0))
    returning id into v_id;
  else
    update public.vg_token_rewards
       set nombre      = trim(p_nombre),
           descripcion = nullif(trim(coalesce(p_descripcion,'')),''),
           costo       = p_costo,
           icono       = nullif(trim(coalesce(p_icono,'')),''),
           imagen      = nullif(trim(coalesce(p_imagen,'')),''),
           activo      = coalesce(p_activo,true),
           orden       = coalesce(p_orden,0)
     where id = p_id
    returning id into v_id;

    if v_id is null then raise exception 'No encontré ese premio.'; end if;
  end if;

  return v_id;
end;
$$;


create or replace function public.vg_admin_borrar_premio(p_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  -- Los canjes ya hechos guardan el nombre y el costo por su cuenta, así
  -- que borrar el premio no rompe el historial de nadie.
  delete from public.vg_token_rewards where id = p_id;
  return true;
end;
$$;


-- El panel necesita ver también los premios desactivados para poder
-- reactivarlos. La política de lectura pública solo muestra los activos.
create or replace function public.vg_admin_premios()
returns setof public.vg_token_rewards
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  return query
    select * from public.vg_token_rewards order by orden, costo;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 4. Ajustes del sitio (por ahora, la portada)
--
--    Tabla genérica clave/valor para no tener que crear una tabla nueva
--    cada vez que quieras poder cambiar algo desde el panel.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_site_config (
  clave      text primary key,
  valor      text,
  updated_at timestamptz default now(),
  updated_by uuid
);
alter table public.vg_site_config add column if not exists valor      text;
alter table public.vg_site_config add column if not exists updated_at timestamptz default now();
alter table public.vg_site_config add column if not exists updated_by uuid;

insert into public.vg_site_config (clave, valor) values
  ('portada_tipo',   'video'),   -- 'video' | 'imagen'
  ('portada_url',    ''),        -- vacío = se queda la portada que trae la página
  ('portada_poster', '')         -- imagen mientras carga el video
on conflict (clave) do nothing;


create or replace function public.vg_admin_guardar_config(p_clave text, p_valor text)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  insert into public.vg_site_config (clave, valor, updated_at, updated_by)
  values (p_clave, p_valor, now(), auth.uid())
  on conflict (clave) do update
    set valor = excluded.valor, updated_at = now(), updated_by = auth.uid();
  return true;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 5. Permisos
-- ─────────────────────────────────────────────────────────────
alter table public.vg_site_config enable row level security;

drop policy if exists siteconf_lectura on public.vg_site_config;
drop policy if exists siteconf_admin   on public.vg_site_config;

-- Cualquiera puede leer: la portada la tiene que ver todo el mundo,
-- incluso sin iniciar sesión.
create policy siteconf_lectura on public.vg_site_config
  for select to anon, authenticated using (true);

create policy siteconf_admin on public.vg_site_config
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

grant execute on function public.vg_admin_guardar_premio(uuid,text,text,numeric,text,text,boolean,integer) to authenticated;
grant execute on function public.vg_admin_borrar_premio(uuid)   to authenticated;
grant execute on function public.vg_admin_premios()             to authenticated;
grant execute on function public.vg_admin_guardar_config(text,text) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 6. El almacén tiene que aceptar video
--
--    El bucket se creó solo para fotos: 5 MB y nada más que imágenes.
--    Un video de portada no cabía ni por tipo ni por tamaño.
--    60 MB da de sobra para un clip corto en buena calidad; más que eso
--    tardaría demasiado en cargar y conviene subirlo a otro lado y
--    pegar el enlace.
-- ─────────────────────────────────────────────────────────────
update storage.buckets
   set file_size_limit    = 62914560,          -- 60 MB
       allowed_mime_types = array[
         'image/jpeg','image/png','image/webp','image/gif','image/avif',
         'video/mp4','video/webm','video/quicktime'
       ]
 where id = 'catalogo';


notify pgrst, 'reload schema';


-- ─────────────────────────────────────────────────────────────
-- 7. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_token_rewards' and column_name='imagen'
  )::text || ' de 1 (foto en premios)' as premios,
  (select count(*) from information_schema.tables
    where table_schema='public' and table_name='vg_site_config'
  )::text || ' de 1 (ajustes del sitio)' as ajustes,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
    ('vg_admin_guardar_premio','vg_admin_borrar_premio','vg_admin_premios','vg_admin_guardar_config')
  )::text || ' de 4 funciones' as funciones,
  (select case when 'video/mp4' = any(allowed_mime_types) then 'sí' else 'NO' end
     from storage.buckets where id='catalogo') as acepta_video,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_token_rewards' and column_name='imagen') = 1
        and (select count(*) from information_schema.tables
              where table_schema='public' and table_name='vg_site_config') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_admin_guardar_premio','vg_admin_borrar_premio','vg_admin_premios','vg_admin_guardar_config')) = 4
       then 'OK' else 'REVISAR' end as resultado;
