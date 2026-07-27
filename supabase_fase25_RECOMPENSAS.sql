-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 25 — Canje de recompensas con tokens
--
-- Qué agrega:
--   · Catálogo de recompensas (cuántos tokens cuesta cada una).
--   · El cliente puede solicitar su recompensa cuando le alcanza.
--   · A ti te llega el aviso al panel admin, en tiempo real y con sonido.
--   · Al canjear, su contador vuelve a 0 y empieza a acumular de nuevo
--     con su siguiente compra.
--
-- Requiere: supabase_fase23_TOKENS.sql
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Catálogo de recompensas
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_rewards (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  descripcion text,
  costo       numeric not null,
  icono       text,
  activo      boolean default true,
  orden       integer default 0,
  created_at  timestamptz default now()
);
alter table public.vg_token_rewards add column if not exists descripcion text;
alter table public.vg_token_rewards add column if not exists icono       text;
alter table public.vg_token_rewards add column if not exists activo      boolean default true;
alter table public.vg_token_rewards add column if not exists orden       integer default 0;

-- Recompensas iniciales (las mismas que ya anunciabas en el sitio).
-- Se insertan solo si el catálogo está vacío, para no pisar tus cambios.
insert into public.vg_token_rewards (nombre, descripcion, costo, icono, orden)
select * from (values
  ('VIX',         '1 mes de VIX Premium',        5::numeric,  '📺', 1),
  ('Paramount+',  '1 mes de Paramount+',         7::numeric,  '🎬', 2),
  ('MAX',         '1 mes de MAX',                9::numeric,  '🎥', 3),
  ('Crunchyroll', '1 mes de Crunchyroll',        10::numeric, '🍥', 4),
  ('Netflix',     '1 mes de Netflix',            20::numeric, '🍿', 5)
) as v(nombre, descripcion, costo, icono, orden)
where not exists (select 1 from public.vg_token_rewards);


-- ─────────────────────────────────────────────────────────────
-- 2. Solicitudes de canje
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_redemptions (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz default now(),
  user_id       uuid,
  reward_id     uuid,
  reward_nombre text,
  costo         numeric,
  saldo_previo  numeric,
  estado        text default 'solicitada',   -- solicitada | entregada | rechazada
  nota_admin    text,
  entregada_at  timestamptz,
  cliente_nombre text,
  cliente_email  text,
  cliente_phone  text
);
alter table public.vg_token_redemptions add column if not exists nota_admin     text;
alter table public.vg_token_redemptions add column if not exists entregada_at   timestamptz;
alter table public.vg_token_redemptions add column if not exists cliente_nombre text;
alter table public.vg_token_redemptions add column if not exists cliente_email  text;
alter table public.vg_token_redemptions add column if not exists cliente_phone  text;
alter table public.vg_token_redemptions add column if not exists saldo_previo   numeric;

create index if not exists canjes_user_idx   on public.vg_token_redemptions(user_id, created_at desc);
create index if not exists canjes_estado_idx on public.vg_token_redemptions(estado, created_at desc);


-- ─────────────────────────────────────────────────────────────
-- 3. Cómo se descuenta al canjear
--    'reiniciar' → el saldo vuelve a 0 (lo que pediste).
--    'restar'    → solo se resta el costo de la recompensa.
--    Para cambiarlo:
--      update public.vg_token_config set valor=1 where clave='canje_solo_resta';
-- ─────────────────────────────────────────────────────────────
insert into public.vg_token_config (clave, valor, nota) values
  ('canje_solo_resta', 0, '0 = al canjear el saldo vuelve a 0 · 1 = solo se resta el costo')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────
-- 4. Solicitar una recompensa
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_canjear_recompensa(p_reward uuid)
returns json
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_r       public.vg_token_rewards;
  v_saldo   numeric;
  v_u       public.vg_users;
  v_solo_resta boolean;
  v_descuento  numeric;
  v_canje   public.vg_token_redemptions;
  v_pend    integer;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para canjear tu recompensa.';
  end if;

  select * into v_r from public.vg_token_rewards where id = p_reward and activo = true;
  if v_r.id is null then
    raise exception 'Esa recompensa ya no está disponible.';
  end if;

  select coalesce(balance,0) into v_saldo from public.vg_token_wallet where user_id = v_uid;
  v_saldo := coalesce(v_saldo, 0);

  if v_saldo < v_r.costo then
    raise exception 'Te faltan tokens: necesitas % y tienes %.', v_r.costo, v_saldo;
  end if;

  -- Evita que se acumulen solicitudes sin atender del mismo cliente
  select count(*) into v_pend
    from public.vg_token_redemptions
   where user_id = v_uid and estado = 'solicitada';
  if v_pend > 0 then
    raise exception 'Ya tienes una recompensa solicitada. Espera a que te la entreguemos.';
  end if;

  select * into v_u from public.vg_users where id = v_uid;

  select (coalesce(valor,0) = 1) into v_solo_resta
    from public.vg_token_config where clave = 'canje_solo_resta';

  -- Cuánto se descuenta: el costo, o todo el saldo si se reinicia
  v_descuento := case when coalesce(v_solo_resta,false) then v_r.costo else v_saldo end;

  insert into public.vg_token_redemptions (
    user_id, reward_id, reward_nombre, costo, saldo_previo, estado,
    cliente_nombre, cliente_email, cliente_phone
  ) values (
    v_uid, v_r.id, v_r.nombre, v_r.costo, v_saldo, 'solicitada',
    v_u.name, v_u.email, v_u.phone
  ) returning * into v_canje;

  -- Se descuenta al solicitar (no al entregar): así el saldo no puede
  -- gastarse dos veces mientras la solicitud está pendiente.
  perform public.vg_token_mover(
    v_uid, -v_descuento, 'canje', null,
    'Canje solicitado: ' || v_r.nombre
  );

  return json_build_object(
    'ok', true,
    'canje_id', v_canje.id,
    'recompensa', v_r.nombre,
    'descontado', v_descuento,
    'saldo_nuevo', coalesce((select balance from public.vg_token_wallet where user_id = v_uid), 0)
  );
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 5. Ver las recompensas con mi saldo (para pintar la lista)
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
        select r.id, r.nombre, r.descripcion, r.costo, r.icono,
               (v_saldo >= r.costo) as alcanza
          from public.vg_token_rewards r
         where r.activo = true
         order by r.orden, r.costo
      ) x
    ), '[]'::json),
    'historial', coalesce((
      select json_agg(h) from (
        select reward_nombre, costo, estado, created_at
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
-- 6. Admin: marcar una solicitud como entregada o rechazada
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_resolver_canje(
  p_canje  uuid,
  p_estado text,               -- 'entregada' | 'rechazada'
  p_nota   text default null
)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare v_c public.vg_token_redemptions;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede resolver canjes.';
  end if;
  if p_estado not in ('entregada','rechazada') then
    raise exception 'Estado no válido.';
  end if;

  select * into v_c from public.vg_token_redemptions where id = p_canje;
  if v_c.id is null then raise exception 'No se encontró la solicitud.'; end if;
  if v_c.estado <> 'solicitada' then raise exception 'Esa solicitud ya fue resuelta.'; end if;

  update public.vg_token_redemptions
     set estado = p_estado,
         nota_admin = p_nota,
         entregada_at = case when p_estado='entregada' then now() else null end
   where id = p_canje;

  -- Si se rechaza, se le devuelven los tokens que se le descontaron
  if p_estado = 'rechazada' then
    perform public.vg_token_mover(
      v_c.user_id, coalesce(v_c.saldo_previo,0), 'ajuste_admin', null,
      'Devolución por canje rechazado: ' || coalesce(v_c.reward_nombre,''), auth.uid()
    );
  end if;

  return true;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 7. RLS
-- ─────────────────────────────────────────────────────────────
alter table public.vg_token_rewards      enable row level security;
alter table public.vg_token_redemptions  enable row level security;

drop policy if exists rewards_lectura   on public.vg_token_rewards;
drop policy if exists rewards_admin     on public.vg_token_rewards;
drop policy if exists canjes_select     on public.vg_token_redemptions;
drop policy if exists canjes_update     on public.vg_token_redemptions;

-- El catálogo lo puede ver cualquiera (se muestra en la tienda)
create policy rewards_lectura on public.vg_token_rewards
  for select to anon, authenticated using (true);
create policy rewards_admin on public.vg_token_rewards
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Cada quien ve sus canjes; el admin ve todos.
-- No hay política de INSERT a propósito: los canjes solo se crean por
-- la función vg_canjear_recompensa, que valida el saldo. Así nadie
-- puede insertar una solicitud a mano sin tener tokens.
create policy canjes_select on public.vg_token_redemptions
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());
create policy canjes_update on public.vg_token_redemptions
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 8. Realtime, para que el aviso te llegue al instante
-- ─────────────────────────────────────────────────────────────
do $$
begin
  begin
    alter publication supabase_realtime add table public.vg_token_redemptions;
  exception when duplicate_object then null;
  end;
end $$;
alter table public.vg_token_redemptions replica identity full;


-- ─────────────────────────────────────────────────────────────
-- 9. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from public.vg_token_rewards)::text || ' recompensas' as catalogo,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
    ('vg_canjear_recompensa','vg_mis_recompensas','vg_admin_resolver_canje')
  )::text || ' de 3 funciones' as funciones,
  case when (select count(*) from public.vg_token_rewards) >= 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_canjear_recompensa','vg_mis_recompensas','vg_admin_resolver_canje')) = 3
       then 'OK' else 'REVISAR' end as resultado;


-- ═══════════════════════════════════════════════════════════════════
-- Para editar las recompensas más adelante:
--   update public.vg_token_rewards set costo = 15 where nombre = 'Netflix';
--   insert into public.vg_token_rewards (nombre, descripcion, costo, icono, orden)
--     values ('Disney+', '1 mes de Disney+', 12, '🏰', 6);
--   update public.vg_token_rewards set activo = false where nombre = 'VIX';
-- ═══════════════════════════════════════════════════════════════════
