-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 23 — Sistema de tokens y referidos funcional
--
-- Reglas que implementa:
--   · 0.25 tokens por cada compra propia.
--   · 1 token completo al que refirió, cuando su invitado hace su
--     PRIMERA compra usando el link de referido.
--   · El admin puede sumar o restar tokens a mano (para corregir errores).
--
-- DECISIÓN IMPORTANTE — cuándo se acreditan:
--   Los tokens se otorgan cuando el pedido pasa a ENTREGADO, no al
--   crearlo. Si se dieran al crear el pedido, cualquiera podría generar
--   pedidos falsos sin pagar y llenarse de tokens. Al atarlo a la
--   entrega, solo se premian las compras que tú ya validaste.
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Configuración de las recompensas (editable sin tocar código)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_config (
  clave  text primary key,
  valor  numeric,
  nota   text
);
alter table public.vg_token_config add column if not exists valor numeric;
alter table public.vg_token_config add column if not exists nota  text;

insert into public.vg_token_config (clave, valor, nota) values
  ('por_compra_propia', 0.25, 'Tokens que gana el cliente por cada compra suya entregada'),
  ('por_referido',      1.00, 'Tokens que gana quien refirió, en la primera compra de su invitado')
on conflict (clave) do update set valor = excluded.valor, nota = excluded.nota;


-- ─────────────────────────────────────────────────────────────
-- 2. Wallet (ya existía en la Fase 0; se asegura y se completa)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_wallet (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid unique,
  balance         numeric default 0,
  total_purchases integer default 0,
  total_earned    numeric default 0,
  updated_at      timestamptz default now()
);
alter table public.vg_token_wallet add column if not exists user_id         uuid;
alter table public.vg_token_wallet add column if not exists balance         numeric default 0;
alter table public.vg_token_wallet add column if not exists total_purchases integer default 0;
alter table public.vg_token_wallet add column if not exists total_earned    numeric default 0;
alter table public.vg_token_wallet add column if not exists total_referidos integer default 0;
alter table public.vg_token_wallet add column if not exists updated_at      timestamptz default now();

-- El "on conflict (user_id)" de más abajo necesita que user_id sea único
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.vg_token_wallet'::regclass
       and contype in ('u','p')
       and pg_get_constraintdef(oid) like '%(user_id)%'
  ) then
    begin
      alter table public.vg_token_wallet add constraint vg_token_wallet_user_unico unique (user_id);
    exception when others then
      raise notice 'No se pudo crear la restricción única de user_id: %', sqlerrm;
    end;
  end if;
end $$;


-- ─────────────────────────────────────────────────────────────
-- 3. Historial de movimientos
--    Sin esto no hay forma de auditar por qué alguien tiene X tokens,
--    ni de evitar pagar dos veces el mismo pedido.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_token_tx (
  id          bigserial primary key,
  created_at  timestamptz default now(),
  user_id     uuid,
  cantidad    numeric,                   -- positiva suma, negativa resta
  motivo      text,                      -- compra | referido | ajuste_admin | canje
  order_id    text,                      -- pedido que lo originó, si aplica
  detalle     text,
  hecho_por   uuid                       -- admin que hizo el ajuste manual
);

-- Si la tabla ya existía con otra estructura, el "create table if not
-- exists" de arriba no la habría tocado y faltarían columnas (ese fue
-- el error 42703: column "motivo" does not exist). Se agregan una a una.
alter table public.vg_token_tx add column if not exists created_at timestamptz default now();
alter table public.vg_token_tx add column if not exists user_id    uuid;
alter table public.vg_token_tx add column if not exists cantidad   numeric;
alter table public.vg_token_tx add column if not exists motivo     text;
alter table public.vg_token_tx add column if not exists order_id   text;
alter table public.vg_token_tx add column if not exists detalle    text;
alter table public.vg_token_tx add column if not exists hecho_por  uuid;

-- Columnas viejas obligatorias que bloquearían los INSERT nuevos
do $$
declare col text;
begin
  foreach col in array array['tipo','type','amount','monto','reason','descripcion','concepto','balance_after']
  loop
    begin
      execute format('alter table public.vg_token_tx alter column %I drop not null', col);
    exception when undefined_column then null;
    end;
  end loop;
end $$;

create index if not exists tokentx_user_idx  on public.vg_token_tx(user_id, created_at desc);
create index if not exists tokentx_order_idx on public.vg_token_tx(order_id, motivo);

-- Evita acreditar dos veces el mismo concepto para el mismo pedido
create unique index if not exists tokentx_unico_por_pedido
  on public.vg_token_tx(order_id, motivo, user_id)
  where order_id is not null and motivo in ('compra','referido');


-- ─────────────────────────────────────────────────────────────
-- 4. Función central: mover tokens y dejar rastro
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_token_mover(
  p_user     uuid,
  p_cantidad numeric,
  p_motivo   text,
  p_order    text default null,
  p_detalle  text default null,
  p_admin    uuid default null
)
returns numeric
language plpgsql security definer
set search_path = public
as $$
declare v_saldo numeric;
begin
  if p_user is null or p_cantidad is null or p_cantidad = 0 then
    return null;
  end if;

  begin
    insert into public.vg_token_tx (user_id, cantidad, motivo, order_id, detalle, hecho_por)
    values (p_user, p_cantidad, p_motivo, p_order, p_detalle, p_admin);
  exception when unique_violation then
    -- Ya se había acreditado este pedido por este motivo: no se repite
    select balance into v_saldo from public.vg_token_wallet where user_id = p_user;
    return v_saldo;
  end;

  insert into public.vg_token_wallet (user_id, balance, total_earned)
  values (p_user, p_cantidad, greatest(p_cantidad, 0))
  on conflict (user_id) do update
    set balance      = public.vg_token_wallet.balance + p_cantidad,
        total_earned = public.vg_token_wallet.total_earned + greatest(p_cantidad, 0),
        updated_at   = now();

  select balance into v_saldo from public.vg_token_wallet where user_id = p_user;
  return v_saldo;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 5. Acreditar al entregar un pedido
--    Se dispara solo cuando el pedido cambia a 'entregado'.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_tokens_al_entregar()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_por_compra   numeric;
  v_por_referido numeric;
  v_padrino      uuid;
  v_es_primera   boolean;
begin
  -- Solo cuando ACABA de pasar a entregado
  if new.status is distinct from 'entregado' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'entregado' then return new; end if;
  if new.user_id is null then return new; end if;

  select valor into v_por_compra   from public.vg_token_config where clave='por_compra_propia';
  select valor into v_por_referido from public.vg_token_config where clave='por_referido';

  -- a) Tokens para quien compró
  perform public.vg_token_mover(
    new.user_id, coalesce(v_por_compra,0.25), 'compra', new.id::text,
    'Compra entregada: ' || coalesce(new.product_title,'pedido')
  );

  update public.vg_token_wallet
     set total_purchases = coalesce(total_purchases,0) + 1
   where user_id = new.user_id;

  -- b) Tokens para quien lo refirió, solo en su PRIMERA compra entregada
  select referred_by into v_padrino from public.vg_users where id = new.user_id;
  if v_padrino is not null then
    select count(*) = 1 into v_es_primera
      from public.vg_token_tx
     where user_id = new.user_id and motivo = 'compra';

    if v_es_primera then
      perform public.vg_token_mover(
        v_padrino, coalesce(v_por_referido,1.00), 'referido', new.id::text,
        'Primera compra de un invitado tuyo'
      );
      update public.vg_token_wallet
         set total_referidos = coalesce(total_referidos,0) + 1
       where user_id = v_padrino;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists vg_tokens_entrega_trg on public.orders;
create trigger vg_tokens_entrega_trg
  after insert or update of status on public.orders
  for each row execute function public.vg_tokens_al_entregar();


-- ─────────────────────────────────────────────────────────────
-- 6. Ajuste manual del admin (sumar o restar por errores)
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_ajustar_tokens(
  p_user     uuid,
  p_cantidad numeric,
  p_motivo   text default 'Ajuste manual'
)
returns numeric
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede ajustar tokens.';
  end if;
  if p_cantidad = 0 then
    raise exception 'La cantidad no puede ser cero.';
  end if;
  return public.vg_token_mover(p_user, p_cantidad, 'ajuste_admin', null, p_motivo, auth.uid());
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 7. Consultar mi wallet (saldo + historial)
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_mi_wallet()
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_res json; v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then return null; end if;

  insert into public.vg_token_wallet (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  select json_build_object(
    'balance',         coalesce(w.balance,0),
    'total_earned',    coalesce(w.total_earned,0),
    'total_purchases', coalesce(w.total_purchases,0),
    'total_referidos', coalesce(w.total_referidos,0),
    'referral_code',   u.referral_code,
    'movimientos', coalesce((
      select json_agg(t) from (
        select cantidad, motivo, detalle, created_at
          from public.vg_token_tx
         where user_id = v_uid
         order by created_at desc limit 25
      ) t
    ), '[]'::json)
  ) into v_res
  from public.vg_users u
  left join public.vg_token_wallet w on w.user_id = u.id
  where u.id = v_uid;

  return v_res;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 8. Buscar usuarios (para que el admin elija a quién ajustar)
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_buscar_usuarios(p_texto text default '')
returns table (
  id uuid, name text, email text, phone text,
  referral_code text, balance numeric, total_earned numeric,
  total_purchases integer, total_referidos integer
)
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede consultar usuarios.';
  end if;
  return query
    select u.id, u.name, u.email, u.phone, u.referral_code,
           coalesce(w.balance,0), coalesce(w.total_earned,0),
           coalesce(w.total_purchases,0), coalesce(w.total_referidos,0)
      from public.vg_users u
      left join public.vg_token_wallet w on w.user_id = u.id
     where p_texto = '' or p_texto is null
        or u.name  ilike '%'||p_texto||'%'
        or u.email ilike '%'||p_texto||'%'
        or u.phone ilike '%'||p_texto||'%'
        or u.referral_code ilike '%'||p_texto||'%'
     order by coalesce(w.balance,0) desc, u.created_at desc
     limit 60;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 9. RLS
-- ─────────────────────────────────────────────────────────────
alter table public.vg_token_wallet enable row level security;
alter table public.vg_token_tx     enable row level security;
alter table public.vg_token_config enable row level security;

drop policy if exists wallet_select        on public.vg_token_wallet;
drop policy if exists wallet_insert        on public.vg_token_wallet;
drop policy if exists wallet_update        on public.vg_token_wallet;
drop policy if exists tokentx_select       on public.vg_token_tx;
drop policy if exists tokenconfig_select   on public.vg_token_config;
drop policy if exists tokenconfig_admin    on public.vg_token_config;

-- Cada quien ve su wallet; el admin ve todas.
create policy wallet_select on public.vg_token_wallet
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());

-- El saldo NO se escribe desde el cliente: solo por las funciones de
-- arriba (SECURITY DEFINER). Así nadie puede regalarse tokens.
create policy wallet_insert on public.vg_token_wallet
  for insert to authenticated
  with check (public.is_admin());
create policy wallet_update on public.vg_token_wallet
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy tokentx_select on public.vg_token_tx
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());

create policy tokenconfig_select on public.vg_token_config
  for select to anon, authenticated using (true);
create policy tokenconfig_admin on public.vg_token_config
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 10. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from public.vg_token_config)::text || ' reglas' as config,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
    ('vg_token_mover','vg_tokens_al_entregar','vg_admin_ajustar_tokens','vg_mi_wallet','vg_admin_buscar_usuarios')
  )::text || ' de 5 funciones' as funciones,
  (select count(*) from pg_trigger where tgname='vg_tokens_entrega_trg' and not tgisinternal)::text || ' de 1 trigger' as trigger,
  case when (select count(*) from public.vg_token_config) = 2
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_token_mover','vg_tokens_al_entregar','vg_admin_ajustar_tokens','vg_mi_wallet','vg_admin_buscar_usuarios')) = 5
       then 'OK' else 'REVISAR' end as resultado;


-- ═══════════════════════════════════════════════════════════════════
-- Para cambiar las recompensas más adelante, sin tocar código:
--   update public.vg_token_config set valor = 0.5 where clave='por_compra_propia';
--   update public.vg_token_config set valor = 2   where clave='por_referido';
-- ═══════════════════════════════════════════════════════════════════
