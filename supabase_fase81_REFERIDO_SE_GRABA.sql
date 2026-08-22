-- ═══════════════════════════════════════════════════════════════════
-- VG FASE 81 · El referido se graba al crear la cuenta, no después
--
-- QUÉ ESTABA PASANDO
--
-- El programa de referidos no pagaba nunca. Se probó de verdad: entrar
-- por el enlace ?ref=CODIGO, registrarse como cliente nuevo, comprar.
-- El token no llegó.
--
-- La causa no estaba en el reparto de tokens. El disparador que paga
-- (vg_tokens_al_entregar, fase 23) está bien y sí se ejecuta. Lo que
-- pasa es que llega a esta línea y se da media vuelta:
--
--     select referred_by into v_padrino from public.vg_users ...
--     if v_padrino is not null then      -- ← aquí siempre era NULL
--
-- Es decir: el padrino nunca quedaba apuntado en la ficha del ahijado.
--
-- Y no quedaba apuntado por cómo se hacía el alta. Cuando un cliente
-- se registra, quien crea su ficha es el disparador handle_new_user,
-- que copia nombre, WhatsApp, lada y correo — pero nunca el referido.
-- Nacía siempre con referred_by en NULL. Para taparlo, la página
-- lanzaba justo después un UPDATE desde el navegador:
--
--     await c.from('vg_users').update({ referred_by: rf.data })
--                             .eq('id', r.data.user.id);
--
-- Ese remiendo falla por tres motivos, y los tres a la vez:
--
--   1. Se lanza ANTES de comprobar si el alta dejó sesión abierta. Si
--      en Supabase está activa la confirmación por correo, signUp()
--      devuelve el usuario pero NO la sesión: el navegador sigue
--      siendo "anon". Y la política vg_users_update_own es "for update
--      TO AUTHENTICATED". PostgREST no da error: responde que todo
--      bien y modifica CERO filas.
--   2. Nadie mira el resultado. El update va sin .select(), sin leer
--      .error, y todo dentro de un catch vacío. Falle lo que falle, el
--      cliente ve "¡Cuenta creada!" igual.
--   3. El código pendiente se borra pase lo que pase, porque el
--      removeItem está fuera del if. Si el enlace falla al primer
--      intento, no hay segundo: se pierde para siempre.
--
-- QUÉ HACE ESTE ARCHIVO
--
-- Mueve el enlace del padrino al único sitio donde no puede fallar:
-- DENTRO del mismo disparador que crea la ficha. Es SECURITY DEFINER,
-- corre dentro de la base, se salta RLS, no necesita sesión abierta y
-- ocurre en la misma transacción que el alta. Si la cuenta se crea, el
-- referido queda grabado; no hay estado intermedio posible.
--
-- El código de referido viaja ahora en los datos del alta (el mismo
-- sitio por donde ya viajaban el nombre y el WhatsApp). Eso hay que
-- mandarlo desde la página: va en el cambio de index.html que
-- acompaña a este archivo.
--
-- Además:
--   · find_referrer deja de distinguir mayúsculas y aguanta espacios.
--   · Se añade una función para reparar a mano las cuentas que ya se
--     registraron sin quedar enlazadas (la de la prueba, entre otras).
--   · Se añade un diagnóstico para ver de un vistazo cómo está todo.
--
-- LO QUE NO CAMBIA: el token se sigue pagando en la PRIMERA COMPRA
-- ENTREGADA del invitado, no al registrarse. Si se quiere cambiar eso,
-- es otra decisión y otro archivo.
--
-- CÓMO SE CORRE: Supabase → SQL Editor → New query → pegar todo → Run.
-- Se puede correr más de una vez sin problema.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1 · Buscar al padrino sin tropezar con mayúsculas ───────────────
--
-- Los códigos que genera la base salen en mayúsculas, pero por la
-- página andan tres capturas distintas del mismo ?ref: una lo guarda
-- crudo, otra lo pasa a mayúsculas, otra lo recorta. Con que una sola
-- deje el código en minúsculas, el '=' de antes no encontraba nada y
-- el referido se perdía en silencio. Se compara normalizado.
--
-- Sigue siendo SECURITY DEFINER a propósito: así responde por un
-- código concreto sin abrir la tabla de usuarios a nadie.
create or replace function public.find_referrer(code text)
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select id
    from public.vg_users
   where upper(trim(referral_code)) = upper(trim(code))
   limit 1;
$$;

grant execute on function public.find_referrer(text) to anon, authenticated;


-- ── 2 · El alta graba el referido ───────────────────────────────────
--
-- Esta es la corrección de fondo. El disparador ya creaba la ficha y
-- la cartera; ahora resuelve también el código del padrino y lo deja
-- puesto en la misma operación.
--
-- Se mantiene todo lo que hacía antes (fase 26: nombre, WhatsApp,
-- lada, correo, cartera a cero) para no romper nada.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code    text;
  v_padrino uuid;
begin
  -- El código de referido viaja en los datos del alta. Se aceptan dos
  -- nombres porque por la página conviven dos maneras de llamarlo.
  v_code := coalesce(
    nullif(trim(new.raw_user_meta_data->>'ref'), ''),
    nullif(trim(new.raw_user_meta_data->>'referral_code'), '')
  );

  if v_code is not null then
    select id into v_padrino
      from public.vg_users
     where upper(trim(referral_code)) = upper(v_code)
     limit 1;

    -- Nadie se refiere a sí mismo. No debería poder pasar aquí (el
    -- código del recién llegado se genera en este mismo insert), pero
    -- la restricción vg_users_no_autoreferido de la fase 77 haría
    -- fallar el alta entera, y quedarse sin cuenta por un referido
    -- mal puesto sería mucho peor que quedarse sin el token.
    if v_padrino = new.id then
      v_padrino := null;
    end if;
  end if;

  insert into public.vg_users (id, name, phone, phone_cc, email, referred_by)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', ''),
    coalesce(new.raw_user_meta_data->>'phone', ''),
    coalesce(nullif(new.raw_user_meta_data->>'phone_cc',''), '+52'),
    new.email,
    v_padrino
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


-- ── 2b · Quién puede usar las herramientas de abajo ─────────────────
--
-- Las tres funciones que siguen son solo para el dueño. El guardia
-- obvio sería 'if not public.is_admin()', pero is_admin() se apoya en
-- auth.uid(), y auth.uid() sale NULL cuando no hay sesión web — que es
-- justo el caso del SQL Editor de Supabase. Con ese guardia, las tres
-- fallaban precisamente en el sitio donde se van a usar.
--
-- Así que se permite el paso en dos casos: cuando quien llama es un
-- administrador identificado, o cuando no hay ninguna sesión web
-- detrás (SQL Editor o clave de servicio). El segundo caso es seguro
-- porque a estas funciones se les quita el permiso a 'anon' y solo se
-- les da a 'authenticated': por la web no hay manera de llegar aquí
-- sin sesión.
create or replace function public.vg_es_el_dueno()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select auth.uid() is null or public.is_admin();
$$;

revoke all on function public.vg_es_el_dueno() from public, anon;
grant execute on function public.vg_es_el_dueno() to authenticated;


-- ── 3 · Reparar una cuenta que ya se registró sin enlazar ───────────
--
-- Las cuentas creadas antes de este archivo tienen referred_by en
-- NULL y ya no hay forma de arreglarlo desde el navegador: el
-- congelador de la fase 77 solo deja tocar ese campo al dueño.
--
-- Esto sirve, entre otras, para la cuenta con la que se hizo la
-- prueba. Se le pasa el WhatsApp o el correo del ahijado y el código
-- del padrino:
--
--   select public.vg_referido_reparar('6641234567', 'A3F91C2D');
--
-- Solo el dueño puede llamarla.
create or replace function public.vg_referido_reparar(
  p_ahijado text,   -- WhatsApp o correo del que se registró
  p_codigo  text    -- código de referido del padrino
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ahijado uuid;
  v_padrino uuid;
  v_actual  uuid;
  v_tel     text;
begin
  if not public.vg_es_el_dueno() then
    raise exception 'Solo el administrador puede reparar un referido.';
  end if;

  v_tel := regexp_replace(coalesce(p_ahijado,''), '\D', '', 'g');

  select id, referred_by into v_ahijado, v_actual
    from public.vg_users
   where lower(trim(email)) = lower(trim(p_ahijado))
      or (v_tel <> '' and regexp_replace(coalesce(phone,''), '\D', '', 'g') = v_tel)
   limit 1;

  if v_ahijado is null then
    return 'No encontré a nadie con ese WhatsApp ni con ese correo.';
  end if;

  select public.find_referrer(p_codigo) into v_padrino;

  if v_padrino is null then
    return 'Ese código de referido no es de nadie.';
  end if;

  if v_padrino = v_ahijado then
    return 'Es el mismo código de esa cuenta: nadie se refiere a sí mismo.';
  end if;

  if v_actual is not null then
    if v_actual = v_padrino then
      return 'Ya estaba enlazado con ese padrino. No hice nada.';
    end if;
    return 'Esa cuenta ya tiene otro padrino apuntado. No lo cambio sin querer: '
        || 'bórralo antes a mano si de verdad hay que cambiarlo.';
  end if;

  update public.vg_users set referred_by = v_padrino where id = v_ahijado;

  return 'Listo. Enlazado. El token le llegará al padrino cuando el pedido '
      || 'de esta cuenta pase a "entregado" (si ya hay uno entregado, '
      || 'ese ya pasó: usa vg_referido_pagar_pendiente).';
end;
$$;

revoke all on function public.vg_referido_reparar(text, text) from public, anon;
grant execute on function public.vg_referido_reparar(text, text) to authenticated;


-- ── 4 · Pagar un referido que se quedó atrás ────────────────────────
--
-- El disparador paga en el momento en que el pedido pasa a
-- "entregado". Si el enlace del padrino se reparó DESPUÉS de esa
-- entrega, ese momento ya pasó y no vuelve. Esto lo paga a mano, una
-- sola vez, con la misma función de siempre (vg_token_mover), que ya
-- se protege sola contra pagar dos veces el mismo pedido.
--
--   select public.vg_referido_pagar_pendiente('6641234567');
--
-- Solo el dueño puede llamarla.
create or replace function public.vg_referido_pagar_pendiente(
  p_ahijado text   -- WhatsApp o correo del invitado
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ahijado  uuid;
  v_padrino  uuid;
  v_pedido   text;
  v_valor    numeric;
  v_tel      text;
  v_saldo    numeric;
begin
  if not public.vg_es_el_dueno() then
    raise exception 'Solo el administrador puede pagar un referido a mano.';
  end if;

  v_tel := regexp_replace(coalesce(p_ahijado,''), '\D', '', 'g');

  select id, referred_by into v_ahijado, v_padrino
    from public.vg_users
   where lower(trim(email)) = lower(trim(p_ahijado))
      or (v_tel <> '' and regexp_replace(coalesce(phone,''), '\D', '', 'g') = v_tel)
   limit 1;

  if v_ahijado is null then
    return 'No encontré a nadie con ese WhatsApp ni con ese correo.';
  end if;

  if v_padrino is null then
    return 'Esa cuenta no tiene padrino apuntado. Usa antes vg_referido_reparar.';
  end if;

  -- Su primera compra entregada
  select id::text into v_pedido
    from public.orders
   where user_id = v_ahijado
     and status = 'entregado'
   order by created_at
   limit 1;

  if v_pedido is null then
    return 'Ese invitado todavía no tiene ninguna compra entregada. '
        || 'En cuanto marques su pedido como "entregado", el token sale solo.';
  end if;

  select valor into v_valor from public.vg_token_config where clave = 'por_referido';

  select public.vg_token_mover(
    v_padrino, coalesce(v_valor, 1.00), 'referido', v_pedido,
    'Primera compra de un invitado tuyo (acreditado a mano)'
  ) into v_saldo;

  if v_saldo is null then
    return 'No se pudo acreditar.';
  end if;

  update public.vg_token_wallet
     set total_referidos = coalesce(total_referidos, 0) + 1
   where user_id = v_padrino;

  return 'Acreditado. El padrino se queda con ' || v_saldo::text || ' tokens. '
      || '(Si ya se le había pagado este pedido, no se repite y el saldo no cambia.)';
end;
$$;

revoke all on function public.vg_referido_pagar_pendiente(text) from public, anon;
grant execute on function public.vg_referido_pagar_pendiente(text) to authenticated;


-- ── 5 · Diagnóstico ─────────────────────────────────────────────────
--
-- Para ver de un vistazo si el programa está funcionando de verdad, y
-- para revisar una prueba concreta sin pelearse con SQL:
--
--   select * from public.vg_referido_diagnostico();
--
-- Solo el dueño.
create or replace function public.vg_referido_diagnostico()
returns table (
  concepto text,
  valor    text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.vg_es_el_dueno() then
    raise exception 'Solo el administrador puede ver el diagnóstico.';
  end if;

  return query
  select 'Cuentas en total'::text,
         count(*)::text from public.vg_users;

  return query
  select 'Cuentas con padrino apuntado'::text,
         count(*)::text from public.vg_users where referred_by is not null;

  return query
  select 'Cuentas SIN padrino (normales o rotas)'::text,
         count(*)::text from public.vg_users where referred_by is null;

  return query
  select 'Tokens pagados por referido'::text,
         coalesce(count(*), 0)::text
    from public.vg_token_tx where motivo = 'referido';

  return query
  select 'Pedidos entregados con dueño conocido'::text,
         count(*)::text
    from public.orders where status = 'entregado' and user_id is not null;

  return query
  select 'Pedidos entregados SIN dueño (no pagan nada)'::text,
         count(*)::text
    from public.orders where status = 'entregado' and user_id is null;

  return query
  select 'El alta graba el referido'::text,
         case when exists (
           select 1 from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname = 'handle_new_user'
              and pg_get_functiondef(p.oid) like '%referred_by%'
         ) then 'SÍ' else 'NO — vuelve a correr este archivo' end;

  return query
  select 'Disparador de alta puesto'::text,
         case when exists (
           select 1 from pg_trigger
            where tgname = 'on_auth_user_created' and not tgisinternal
         ) then 'SÍ' else 'NO' end;

  return query
  select 'Disparador que paga puesto'::text,
         case when exists (
           select 1 from pg_trigger
            where tgname = 'vg_tokens_entrega_trg' and not tgisinternal
         ) then 'SÍ' else 'NO — corre supabase_fase23_TOKENS.sql' end;

  return query
  select 'Se paga por referido'::text,
         coalesce((select valor::text from public.vg_token_config
                    where clave = 'por_referido'), '1.00 (por defecto)');
end;
$$;

revoke all on function public.vg_referido_diagnostico() from public, anon;
grant execute on function public.vg_referido_diagnostico() to authenticated;


-- ── 6 · Comprobación ────────────────────────────────────────────────
--
-- Las cuatro filas tienen que decir OK.
select 'El alta graba el referido' as paso,
  case when exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='handle_new_user'
       and pg_get_functiondef(p.oid) like '%referred_by%'
  ) then 'OK' else 'FALTA' end as estado
union all
select 'find_referrer no distingue mayúsculas',
  case when exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='find_referrer'
       and pg_get_functiondef(p.oid) like '%upper%'
  ) then 'OK' else 'FALTA' end
union all
select 'Herramientas de reparación',
  case when (
    select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('vg_referido_reparar','vg_referido_pagar_pendiente',
                         'vg_referido_diagnostico')
  ) = 3 then 'OK' else 'FALTAN' end
union all
select 'Disparador de alta puesto',
  case when exists (
    select 1 from pg_trigger where tgname='on_auth_user_created' and not tgisinternal
  ) then 'OK' else 'FALTA' end;
