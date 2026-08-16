-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 77 — Lo que encontró la auditoría
--
-- Diez agujeros. Tres de ellos permiten robar dinero o cuentas, y uno
-- está goteando datos de clientes ahora mismo:
--
--   S1 (CRÍTICO) La tabla de analítica no tiene reglas de fila. Se
--       leen sus 13.730 renglones sin cuenta, con ciudad, país y qué
--       miró cada visitante. Se creó a mano en el panel y las tablas
--       hechas así nacen sin candado. Comprobado en vivo.
--
--   S2 (CRÍTICO) El precio del pedido lo decide el navegador. La
--       función se cree el p_total que le mandan: se puede comprar
--       algo de $500 por un peso y el comprobante cuadra.
--
--   S3 (CRÍTICO) Robo de cuenta por la puerta de recuperación. El
--       cliente puede cambiar su propio correo al del dueño, pedir
--       contraseña nueva, y el dueño se la genera y se la manda al
--       WhatsApp del ladrón sin enterarse.
--
--   S4 (ALTO) El comprobante entra sin mirar qué es ni cuánto pesa.
--   S5 (ALTO) La base no valida NADA: ni un precio, ni un teléfono.
--   S6 (MEDIO) Auto-referido: uno puede apuntarse a sí mismo.
--   S7 (MEDIO) Se puede averiguar quién tiene cuenta, sin límite.
--   S8 (MEDIO) Un operador puede escribir firmando como el cliente.
--   S9 (MEDIO) Un operador puede cambiarle el total a un pedido.
--   S10 (INFO) Dos funciones del chat viven fuera de este repositorio.
--
-- Corre el archivo entero. Es idempotente: se puede repetir.
--
-- IMPORTANTE — el orden importa. La sección 2 cambia la función que
-- registra los pedidos. Si algo sale mal a mitad, al final de este
-- archivo (sección 11) está cómo dejarlo todo como estaba.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- 1. S1 · La analítica deja de ser pública
--
--    La página tiene que poder seguir APUNTANDO eventos sin cuenta
--    (un visitante que aún no se ha registrado también cuenta), pero
--    nadie tiene por qué poder LEERLOS desde el navegador salvo el
--    administrador, que es quien mira el panel de analítica.
--
--    Escribir sí, leer no. Es la forma de un buzón.
-- ═══════════════════════════════════════════════════════════════════

-- Por si la tabla no existiera todavía en algún entorno
create table if not exists public.vg_analytics_events (
  id           bigserial primary key,
  created_at   timestamptz default now(),
  session_id   text,
  event_type   text,
  product_id   text,
  product_name text,
  section      text,
  city         text,
  region       text,
  country      text,
  scroll_depth integer,
  metadata     jsonb
);

alter table public.vg_analytics_events enable row level security;

drop policy if exists analytics_insert on public.vg_analytics_events;
create policy analytics_insert on public.vg_analytics_events
  for insert to anon, authenticated
  with check (true);

drop policy if exists analytics_select on public.vg_analytics_events;
create policy analytics_select on public.vg_analytics_events
  for select to authenticated
  using (public.is_admin());

-- Nadie edita ni borra un evento ya apuntado: sin política de update
-- ni de delete, con RLS activa, esas dos operaciones quedan cerradas
-- para todo el mundo salvo el dueño de la tabla.

create index if not exists vg_analytics_fecha_idx
  on public.vg_analytics_events(created_at desc);


-- ── El catálogo de Xbox, igual que el resto del catálogo ──
--    Leerlo es público a propósito (son productos en venta).
--    Escribirlo, solo el administrador.
create table if not exists public.vg_xbox_games (
  id         bigserial primary key,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  title      text,
  platform   text,
  price      numeric,
  image      text,
  status     text
);

alter table public.vg_xbox_games enable row level security;

drop policy if exists xbox_lee   on public.vg_xbox_games;
drop policy if exists xbox_admin on public.vg_xbox_games;

create policy xbox_lee on public.vg_xbox_games
  for select to anon, authenticated using (true);

create policy xbox_admin on public.vg_xbox_games
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ═══════════════════════════════════════════════════════════════════
-- 2. S2 · El precio lo pone la base, no el navegador
--
--    Cómo funciona ahora:
--
--    Cada artículo del pedido puede traer product_id y option_index
--    (la página los manda desde la fase 77). Con eso se busca el
--    precio REAL en products_admin —que es donde el panel guarda los
--    precios que el dueño edita— y si no está ahí, en products.
--
--    · Si se encuentra el precio → se usa ESE, se ignora el que
--      mandó el navegador, y el artículo queda verificado.
--    · Si NO se encuentra → se acepta el precio del navegador pero
--      el pedido se marca total_verificado = false.
--
--    Ese segundo caso no es dejadez: la tienda vende cosas que no
--    son filas del catálogo (la colección Xbox Retro se arma juego a
--    juego, los pavos de Fortnite salen de la tienda del día, y hay
--    cotizaciones a medida). Rechazarlas sería cerrar la caja para
--    arreglar la cerradura. Se registran, se cobran, y el panel las
--    puede mostrar aparte para que el dueño les eche un ojo.
--
--    Lo que ya NO puede pasar es comprar un producto del catálogo
--    por menos de lo que vale.
-- ═══════════════════════════════════════════════════════════════════

alter table public.orders add column if not exists total_verificado boolean;
alter table public.orders add column if not exists total_cliente    numeric;

comment on column public.orders.total_verificado is
  'true = el total se recalculó contra el catálogo. false = el pedido lleva artículos sin precio de referencia y hay que mirarlo a mano.';
comment on column public.orders.total_cliente is
  'Lo que el navegador dijo que costaba. Si no coincide con total, alguien tocó el precio.';


-- ── Precio real de un artículo, o null si no se puede saber ──
--
--    Se busca primero en products_admin (el precio que edita el
--    dueño desde el panel manda sobre el del catálogo original) y
--    después en products, por legacy_id, que es donde vive el id
--    numérico que usa la página.
create or replace function public.vg_precio_real(
  p_product_id text,
  p_option_index integer
)
returns numeric
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_ops   jsonb;
  v_price numeric;
begin
  if p_product_id is null or p_option_index is null or p_option_index < 0 then
    return null;
  end if;

  -- 1) Lo que el dueño editó en el panel
  select options into v_ops
    from public.products_admin
   where product_id = p_product_id;

  -- 2) Si ahí no hay opciones, el catálogo
  if v_ops is null or jsonb_typeof(v_ops) <> 'array' or jsonb_array_length(v_ops) = 0 then
    select options into v_ops
      from public.products
     where legacy_id = p_product_id
        or id::text  = p_product_id;
  end if;

  if v_ops is null or jsonb_typeof(v_ops) <> 'array' then
    return null;
  end if;
  if p_option_index >= jsonb_array_length(v_ops) then
    return null;
  end if;

  begin
    v_price := (v_ops -> p_option_index ->> 'price')::numeric;
  exception when others then
    return null;   -- precio no numérico en el catálogo: no se puede verificar
  end;

  if v_price is null or v_price < 0 then
    return null;
  end if;
  return v_price;
end;
$$;

grant execute on function public.vg_precio_real(text, integer) to authenticated;


-- ── El recálculo va en un DISPARADOR, no en la función ──
--
--    Esto es importante y costó verlo. La página no siempre registra
--    el pedido por vg_create_order_v17: createOrder() prueba antes
--    con vg_create_order_v10fixed (otra función creada a mano, fuera
--    de este repositorio) y, si esa falla, hace un INSERT DIRECTO
--    sobre orders. La política orders_insert_own lo permite: solo
--    comprueba que el user_id sea el tuyo, no cuánto pones de total.
--
--    Arreglar solo la función habría dejado dos puertas abiertas de
--    tres. Puesto en un disparador BEFORE INSERT, da igual por dónde
--    entre el pedido: el total se recalcula siempre.
--
--    El administrador queda fuera: si él registra un pedido a mano
--    con un precio pactado, se respeta.
create or replace function public.vg_calcula_total_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_it         jsonb;
  v_precio     numeric;
  v_total      numeric := 0;
  v_verificado boolean := true;
begin
  if public.is_admin() then
    new.total_verificado := true;
    return new;
  end if;

  -- ── S4 · El comprobante tiene que ser una imagen, y de un tamaño ──
  if new.proof_data_url is not null and length(new.proof_data_url) > 0 then
    if new.proof_data_url !~* '^data:image/(png|jpeg|jpg|webp|gif);base64,' then
      raise exception 'El comprobante tiene que ser una imagen.';
    end if;
    -- ~8 MB de imagen ocupan ~11 millones de caracteres en base64
    if length(new.proof_data_url) > 11000000 then
      raise exception 'El comprobante es demasiado grande. Manda una foto más ligera.';
    end if;
  end if;

  -- ── S2 (segunda barrera) · Ningún texto trae etiquetas HTML ──
  --    El panel de administración pinta estos campos. Un artículo
  --    llamado "<img src=x onerror=...>" ejecutaba código en la
  --    sesión del dueño. En el HTML ya se escapa; esto es el
  --    cinturón además de los tirantes, porque los mismos textos
  --    acaban en más de una pantalla.
  if coalesce(new.items::text,'') ~ '<[a-zA-Z/!]'
     or coalesce(new.product_title,'')  ~ '<[a-zA-Z/!]'
     or coalesce(new.product_option,'') ~ '<[a-zA-Z/!]'
     or coalesce(new.delivery_data,'')  ~ '<[a-zA-Z/!]'
     or coalesce(new.client_name,'')    ~ '<[a-zA-Z/!]' then
    raise exception 'Los datos del pedido no son válidos.';
  end if;

  if new.items is null or jsonb_typeof(new.items) <> 'array'
     or jsonb_array_length(new.items) = 0 then
    raise exception 'El pedido no tiene artículos.';
  end if;
  if jsonb_array_length(new.items) > 50 then
    raise exception 'Demasiados artículos en un solo pedido.';
  end if;

  -- Se guarda lo que dijo el navegador antes de tocarlo
  new.total_cliente := coalesce(new.total, 0);

  for v_it in select * from jsonb_array_elements(new.items) loop
    v_precio := public.vg_precio_real(
      nullif(v_it ->> 'product_id', ''),
      nullif(v_it ->> 'option_index', '')::integer
    );

    if v_precio is null then
      -- Sin precio de referencia (retro, Fortnite, cotizaciones):
      -- se acepta el del navegador y el pedido queda para revisar.
      begin
        v_precio := coalesce(nullif(v_it ->> 'price','')::numeric, 0);
      exception when others then
        v_precio := 0;
      end;
      if v_precio < 0 then v_precio := 0; end if;
      v_verificado := false;
    end if;

    v_total := v_total + v_precio;
  end loop;

  if v_total < 0 then v_total := 0; end if;

  new.total            := v_total;
  new.total_verificado := v_verificado;

  -- Si el navegador mandó otro total, queda rastro. No se bloquea:
  -- puede ser un precio que cambió con el carrito abierto. Pero se
  -- apunta, y el panel lo puede enseñar.
  if abs(coalesce(new.total_cliente,0) - v_total) > 0.01 then
    begin
      perform public.vg_apuntar(
        'total recalculado',
        coalesce(new.id::text,'nuevo'),
        'navegador: ' || coalesce(new.total_cliente,0)::text || ' · catálogo: ' || v_total::text
      );
    exception when others then null;
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists orders_calcula_total on public.orders;
create trigger orders_calcula_total
  before insert on public.orders
  for each row execute function public.vg_calcula_total_pedido();


-- ── Registrar el pedido ──
--
--    Misma firma de siempre: la página publicada sigue llamándola
--    igual y no se rompe nada mientras se sube la versión nueva.
--    El total lo corrige el disparador de arriba, así que aquí ya no
--    hace falta repetir la cuenta.
create or replace function public.vg_create_order_v17(
  p_items           jsonb,
  p_total           numeric,
  p_product_title   text default null,
  p_product_option  text default null,
  p_delivery_data   text default null,
  p_proof_data_url  text default null,
  p_proof_file_name text default null,
  p_proof_mime      text default null,
  p_source          text default 'web'
)
returns public.orders
language plpgsql security definer
set search_path = public
as $$
declare
  v_user  public.vg_users;
  v_order public.orders;
begin
  if auth.uid() is null then
    raise exception 'Inicia sesión para registrar tu pedido.';
  end if;

  select * into v_user from public.vg_users where id::text = auth.uid()::text;

  -- El total que llega se guarda tal cual; el disparador
  -- orders_calcula_total lo sustituye por el del catálogo antes de
  -- que la fila toque el disco, y de paso valida comprobante y textos.
  insert into public.orders (
    source, status, total, currency, items,
    user_id, customer_name, customer_phone, customer_email,
    client_name, client_phone,
    product_title, product_option, delivery_data,
    proof_data_url, proof_file_name, proof_mime,
    unread_admin, unread_client, chat_unlocked
  ) values (
    coalesce(p_source,'web'), 'pendiente',
    coalesce(p_total,0),
    'MXN',
    coalesce(p_items,'[]'::jsonb),
    auth.uid(),
    coalesce(v_user.name,''), coalesce(v_user.phone,''), coalesce(v_user.email,''),
    coalesce(v_user.name,''), coalesce(v_user.phone,''),
    p_product_title, p_product_option, p_delivery_data,
    p_proof_data_url, p_proof_file_name, p_proof_mime,
    true,   -- al admin le llega como no leído
    false,
    false   -- ← chat BLOQUEADO hasta que el admin escriba
  )
  returning * into v_order;

  -- Mensaje de sistema inicial (no desbloquea el chat)
  insert into public.vg_live_chat_messages (
    thread_type, thread_ref, order_id, sender_role, sender_name, message
  ) values (
    'order', v_order.id::text, v_order.id::text, 'system', 'Sistema',
    'Pedido recibido. Un administrador lo revisará en breve.'
  );

  return v_order;
end;
$$;

grant execute on function public.vg_create_order_v17(jsonb,numeric,text,text,text,text,text,text,text) to authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 3. S3 y S6 · El correo deja de ser editable por su dueño
--
--    La política vg_users_update_own deja al cliente editar su fila
--    entera. La fase 76 puso un guardia para is_admin y rol; faltaba
--    el correo, que es la pieza que hace posible el robo de cuenta:
--
--      1. El cliente se pone email = el del dueño.
--      2. Pide recuperación de contraseña de ese correo.
--      3. Al dueño le llega una solicitud con el WhatsApp del ladrón.
--      4. El dueño genera la contraseña y se la manda.
--      5. El ladrón entra como dueño.
--
--    El TELÉFONO se deja editable a propósito: el cliente lo cambia
--    desde su panel cuando cambia de número, y por sí solo no abre
--    ninguna puerta.
--
--    referred_by (S6) se puede fijar UNA vez —al registrarse, con el
--    enlace de invitación— y después queda congelado. Antes se podía
--    reasignar el padrino cuando conviniera, incluso a uno mismo.
-- ═══════════════════════════════════════════════════════════════════

alter table public.vg_users add column if not exists rol text;

create or replace function public.vg_protege_rol()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() then
    return new;   -- el administrador puede corregir lo que sea
  end if;

  -- Fase 76: nadie se asciende a sí mismo
  if new.is_admin is distinct from old.is_admin
     or new.rol is distinct from old.rol then
    new.is_admin := old.is_admin;
    new.rol      := old.rol;
  end if;

  -- Fase 77: ni se cambia el correo
  if new.email is distinct from old.email then
    new.email := old.email;
  end if;

  -- Fase 77: el padrino se fija una vez y ya
  if new.referred_by is distinct from old.referred_by
     and old.referred_by is not null then
    new.referred_by := old.referred_by;
  end if;

  -- Y nunca se es padrino de uno mismo
  if new.referred_by is not null and new.referred_by = new.id then
    new.referred_by := old.referred_by;
  end if;

  return new;
end;
$$;

drop trigger if exists vg_users_protege_rol on public.vg_users;
create trigger vg_users_protege_rol
  before update on public.vg_users
  for each row execute function public.vg_protege_rol();

-- Cinturón: aunque alguien se saltara el disparador, la base dice no.
alter table public.vg_users drop constraint if exists vg_users_no_autoreferido;
alter table public.vg_users add constraint vg_users_no_autoreferido
  check (referred_by is null or referred_by <> id) not valid;


-- ── La recuperación se resuelve contra auth.users ──
--
--    Antes se buscaba en vg_users por correo. Ahora se busca la
--    cuenta de acceso de verdad, que es la única que importa: si el
--    correo de la ficha no coincide con el de la cuenta, la
--    solicitud ni se crea.
create or replace function public.vg_solicitar_password(p_email text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid   uuid;
  v_u     public.vg_users;
  v_pend  integer;
  v_hora  integer;
begin
  -- S7 · Freno de cortesía. Si en la última hora ya entraron 20
  -- solicitudes, se responde que sí y no se apunta nada: así nadie
  -- llena la bandeja del dueño para esconder una legítima dentro.
  select count(*) into v_hora
    from public.vg_password_requests
   where created_at > now() - interval '1 hour';
  if v_hora >= 20 then
    return json_build_object('ok', true);
  end if;

  -- La cuenta de acceso manda. Se busca ahí, no en la ficha.
  select id into v_uid from auth.users
   where lower(email) = lower(trim(coalesce(p_email,''))) limit 1;

  -- Se responde lo mismo exista o no la cuenta: si dijéramos "ese
  -- correo no está registrado", cualquiera podría averiguar quién
  -- tiene cuenta.
  if v_uid is null then
    return json_build_object('ok', true);
  end if;

  select * into v_u from public.vg_users where id = v_uid;

  select count(*) into v_pend
    from public.vg_password_requests
   where user_id = v_uid and estado = 'pendiente';

  if v_pend = 0 then
    insert into public.vg_password_requests (user_id, email, phone, phone_cc, nombre)
    values (
      v_uid,
      lower(trim(p_email)),                    -- el correo de la CUENTA
      v_u.phone, coalesce(v_u.phone_cc,'+52'), v_u.name
    );
  end if;

  return json_build_object('ok', true);
end;
$$;

grant execute on function public.vg_solicitar_password(text) to anon, authenticated;


-- ── Y al generar la contraseña, se vuelve a comprobar ──
--
--    Aunque la solicitud sea vieja y algo haya cambiado entre medias,
--    aquí se confirma que el correo sigue siendo el de esa cuenta
--    antes de tocar nada. Si no coincide, no se genera.
create or replace function public.vg_admin_generar_password(
  p_request uuid,
  p_password text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_req  public.vg_password_requests;
  v_pass text;
  v_uid  uuid;
  v_mail text;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  select * into v_req from public.vg_password_requests where id = p_request;
  if v_req.id is null then raise exception 'No se encontró la solicitud.'; end if;

  v_pass := coalesce(nullif(trim(p_password), ''),
                     'VG' || upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8)));

  if length(v_pass) < 10 then
    raise exception 'La contraseña debe tener al menos 10 caracteres.';
  end if;

  -- La solicitud guarda a QUIÉN pertenece. Se usa eso, no el correo,
  -- para encontrar la cuenta.
  if v_req.user_id is null then
    raise exception 'La solicitud no dice de qué cuenta es. Recházala y pide una nueva.';
  end if;

  select id, email into v_uid, v_mail from auth.users where id = v_req.user_id;
  if v_uid is null then
    raise exception 'No se encontró la cuenta de acceso de esa solicitud.';
  end if;

  -- Y se confirma que sigue siendo el mismo correo que se pidió.
  if lower(coalesce(v_mail,'')) is distinct from lower(coalesce(v_req.email,'')) then
    raise exception 'El correo de la solicitud ya no coincide con el de la cuenta. Recházala: puede ser un intento de robo.';
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

  begin
    perform public.vg_apuntar('contraseña generada', v_mail, 'solicitud ' || p_request::text);
  exception when others then null;
  end;

  return json_build_object(
    'ok', true,
    'password', v_pass,
    'email', v_mail
  );
end;
$$;

grant execute on function public.vg_admin_generar_password(uuid, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 4. S7 · Deja de poderse averiguar quién tiene cuenta
--
--    vg_telefono_ocupado responde sí o no a cualquiera y sin límite:
--    recorriendo números se saca la lista de clientes. vg_buscar_cuenta
--    va más lejos y confirma correos.
--
--    No se pueden cerrar: el registro necesita la primera y la
--    recuperación la segunda. Lo que se les pone es un contador.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.vg_rate (
  clave    text primary key,
  n        integer default 0,
  ventana  timestamptz default now()
);

alter table public.vg_rate enable row level security;
-- Sin políticas: solo las funciones de abajo, que son security definer,
-- la tocan. Desde el navegador no se ve ni se escribe.

create or replace function public.vg_rate_ok(p_clave text, p_max integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  insert into public.vg_rate (clave, n, ventana)
  values (p_clave, 1, now())
  on conflict (clave) do update
     set n = case when public.vg_rate.ventana < now() - interval '10 minutes'
                  then 1 else public.vg_rate.n + 1 end,
         ventana = case when public.vg_rate.ventana < now() - interval '10 minutes'
                        then now() else public.vg_rate.ventana end
  returning n into v_n;

  return coalesce(v_n,1) <= p_max;
exception when others then
  return true;   -- si el contador falla, no se bloquea a nadie
end;
$$;


create or replace function public.vg_telefono_ocupado(p_phone text)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.vg_rate_ok('tel:' || coalesce(auth.uid()::text, 'anon'), 20) then
    raise exception 'Demasiadas comprobaciones seguidas. Espera unos minutos.';
  end if;

  return exists (
    select 1 from public.vg_users
     where length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) >= 8
       and regexp_replace(coalesce(phone,''),   '\D', '', 'g')
         = regexp_replace(coalesce(p_phone,''), '\D', '', 'g')
  );
end;
$$;

grant execute on function public.vg_telefono_ocupado(text) to anon, authenticated;


-- vg_buscar_cuenta se deja como está por dentro (ya devuelve el
-- teléfono tapado) pero se le pone el mismo freno delante.
create or replace function public.vg_buscar_cuenta(p_email text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_u public.vg_users; v_tel text; v_oculto text;
begin
  if not public.vg_rate_ok('cuenta:' || coalesce(auth.uid()::text, 'anon'), 10) then
    return json_build_object('existe', false);
  end if;

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

grant execute on function public.vg_buscar_cuenta(text) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 5. S9 · El operador atiende pedidos, no los reescribe
--
--    orders_operador_edita (fase 73) permite editar la fila entera.
--    El rol se creó para cambiar el estado y contestar el chat, pero
--    tal como está también puede cambiar el total, los artículos, o
--    pasarle el pedido a otro cliente. Y como los tokens se reparten
--    al marcar "entregado", puede repartir saldo a quien quiera.
--
--    El disparador devuelve en silencio las columnas que no le tocan.
--    Su trabajo sigue funcionando igual.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.vg_protege_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    new.total            := old.total;
    new.total_cliente    := old.total_cliente;
    new.total_verificado := old.total_verificado;
    new.items            := old.items;
    new.user_id          := old.user_id;
    new.created_at       := old.created_at;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_protege on public.orders;
create trigger orders_protege
  before update on public.orders
  for each row execute function public.vg_protege_pedido();


-- ═══════════════════════════════════════════════════════════════════
-- 6. S8 · En el chat, cada quien firma con lo suyo
--
--    chat_operador_escribe no dice nada del sender_role, así que un
--    operador puede insertar mensajes marcados como 'client' y
--    fabricar una conversación que el cliente nunca tuvo.
-- ═══════════════════════════════════════════════════════════════════

drop policy if exists chat_operador_escribe on public.vg_live_chat_messages;
create policy chat_operador_escribe on public.vg_live_chat_messages
  for insert to authenticated
  with check (public.vg_es_operador() and sender_role in ('admin','system'));


-- ═══════════════════════════════════════════════════════════════════
-- 7. S5 · La base empieza a validar
--
--    Hasta ahora la única regla de la base era la del rol. Todo lo
--    demás lo comprobaba JavaScript, que es una ayuda para el que
--    escribe bien, no una barrera para el que no quiere.
--
--    Van todas como NOT VALID a propósito: se aplican a lo que entre
--    a partir de ahora y NO se ponen a revisar las filas viejas, que
--    es lo que haría fallar el archivo a mitad si hay algún dato
--    raro de hace meses. Para revisarlas cuando haya calma, al final
--    del archivo está el VALIDATE de cada una.
-- ═══════════════════════════════════════════════════════════════════

alter table public.vg_users drop constraint if exists vg_users_name_ok;
alter table public.vg_users add constraint vg_users_name_ok
  check (name is null or char_length(name) <= 80) not valid;

alter table public.vg_users drop constraint if exists vg_users_phone_ok;
alter table public.vg_users add constraint vg_users_phone_ok
  check (phone is null or phone = '' or regexp_replace(phone, '\D', '', 'g') ~ '^[0-9]{8,15}$') not valid;

alter table public.vg_users drop constraint if exists vg_users_email_ok;
alter table public.vg_users add constraint vg_users_email_ok
  check (email is null or email = '' or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') not valid;

alter table public.orders drop constraint if exists orders_total_ok;
alter table public.orders add constraint orders_total_ok
  check (total is null or total >= 0) not valid;

alter table public.orders drop constraint if exists orders_status_ok;
alter table public.orders add constraint orders_status_ok
  check (status is null or status in ('pendiente','validado','entregado','cancelado')) not valid;

alter table public.vg_live_chat_messages drop constraint if exists chat_msg_ok;
alter table public.vg_live_chat_messages add constraint chat_msg_ok
  check (message is null or char_length(message) <= 4000) not valid;


-- ═══════════════════════════════════════════════════════════════════
-- 8. S10 · DIAGNÓSTICO — las dos funciones del chat que no están aquí
--
--    index.html llama a vg_live_chat_send_v10fixed y
--    vg_live_chat_fetch_v10fixed, y ninguna de las dos aparece en los
--    35 archivos SQL de este proyecto: se crearon a mano en el panel.
--
--    Si la de enviar es security definer y guarda el sender_role que
--    le manda el navegador, un cliente puede escribirse a sí mismo
--    mensajes firmados por "Vessel Games".
--
--    ESTA CONSULTA NO CAMBIA NADA. Míra el resultado y, si el cuerpo
--    usa p_sender_role tal cual, aplica el bloque de la sección 9.
-- ═══════════════════════════════════════════════════════════════════

select p.proname                          as funcion,
       p.prosecdef                        as es_security_definer,
       pg_get_function_arguments(p.oid)   as parametros,
       case when p.prosrc like '%p_sender_role%' then 'SÍ — REVISAR'
            else 'no usa p_sender_role' end as se_cree_el_rol,
       p.prosrc                           as cuerpo
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname like 'vg_live_chat%'
 order by p.proname;


-- ═══════════════════════════════════════════════════════════════════
-- 9. S10 (arreglo) — SOLO si la consulta de arriba dijo "SÍ — REVISAR"
--
--    Quita las comillas de bloque de abajo y vuelve a correr el
--    archivo. Deja la misma firma para no romper la llamada del
--    index.html, pero el rol lo decide la base mirando quién eres,
--    no lo que diga el parámetro.
-- ═══════════════════════════════════════════════════════════════════
/*
create or replace function public.vg_live_chat_send_v10fixed(
  p_thread_type    text,
  p_thread_ref     text,
  p_sender_role    text,
  p_sender_name    text,
  p_sender_phone   text,
  p_message        text,
  p_attachment_url text default null
)
returns public.vg_live_chat_messages
language plpgsql security definer
set search_path = public
as $$
declare
  v_rol  text;
  v_nom  text;
  v_msg  public.vg_live_chat_messages;
begin
  if auth.uid() is null then
    raise exception 'Inicia sesión para escribir.';
  end if;

  -- Aquí está el arreglo: el rol sale de quién eres, no del parámetro.
  if public.vg_puede_atender() then
    v_rol := 'admin';
    v_nom := 'Vessel Games';
  else
    if not public.vg_owns_order(p_thread_ref) then
      raise exception 'Ese pedido no es tuyo.';
    end if;
    v_rol := 'client';
    select coalesce(nullif(trim(name),''), 'Cliente') into v_nom
      from public.vg_users where id::text = auth.uid()::text;
  end if;

  if coalesce(trim(p_message),'') = '' then
    raise exception 'Escribe un mensaje.';
  end if;

  insert into public.vg_live_chat_messages (
    thread_type, thread_ref, order_id, sender_role, sender_name,
    sender_phone, message, attachment_url, read_by_client, read_by_admin
  ) values (
    coalesce(p_thread_type,'order'), p_thread_ref, p_thread_ref,
    v_rol, v_nom,
    case when v_rol = 'client' then p_sender_phone else null end,
    left(p_message, 4000), p_attachment_url,
    (v_rol = 'client'), (v_rol = 'admin')
  )
  returning * into v_msg;

  return v_msg;
end;
$$;

grant execute on function public.vg_live_chat_send_v10fixed(text,text,text,text,text,text,text) to authenticated;
*/


-- ═══════════════════════════════════════════════════════════════════
-- 10. DIAGNÓSTICO — ¿queda alguna tabla sin candado?
--
--     Esto es lo que destapó S1. Si devuelve alguna fila, esa tabla
--     se está leyendo entera desde internet con la clave pública.
--     Toda tabla nueva tiene que pasar por un archivo como este, no
--     por el botón de "New table" del panel.
-- ═══════════════════════════════════════════════════════════════════

select t.tablename as tabla_sin_reglas_de_fila
  from pg_tables t
 where t.schemaname = 'public'
   and not exists (
     select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = t.tablename and c.relrowsecurity
   )
 order by 1;


-- ═══════════════════════════════════════════════════════════════════
-- 11. SI ALGO SALIÓ MAL — cómo volver atrás
--
--     Quita las comillas del bloque que necesites. No hace falta
--     deshacerlo todo: cada pieza es independiente.
-- ═══════════════════════════════════════════════════════════════════
/*
-- Volver a la función de pedidos de la fase 17 (acepta el total del
-- navegador otra vez — solo como último recurso, y por poco tiempo):
--   vuelve a correr supabase_fase17_entregas_chat_tickets.sql

-- Quitar el candado del correo (deja abierta la vía de robo de cuenta):
--   vuelve a correr supabase_fase76_CIERRA_ESCALADA.sql

-- Quitar las validaciones nuevas:
alter table public.vg_users drop constraint if exists vg_users_name_ok;
alter table public.vg_users drop constraint if exists vg_users_phone_ok;
alter table public.vg_users drop constraint if exists vg_users_email_ok;
alter table public.vg_users drop constraint if exists vg_users_no_autoreferido;
alter table public.orders   drop constraint if exists orders_total_ok;
alter table public.orders   drop constraint if exists orders_status_ok;
alter table public.vg_live_chat_messages drop constraint if exists chat_msg_ok;

-- Quitar el guardia de los pedidos:
drop trigger if exists orders_protege on public.orders;
*/

-- ── Cuando haya calma: revisar también las filas viejas ──
--    Si alguno da error, dice qué fila no cumple y se corrige a mano.
/*
alter table public.vg_users validate constraint vg_users_email_ok;
alter table public.vg_users validate constraint vg_users_phone_ok;
alter table public.vg_users validate constraint vg_users_no_autoreferido;
alter table public.orders   validate constraint orders_total_ok;
alter table public.orders   validate constraint orders_status_ok;
*/


-- ═══════════════════════════════════════════════════════════════════
-- RESULTADO — las nueve filas tienen que decir OK
-- ═══════════════════════════════════════════════════════════════════
select 'S1 analítica cerrada' as que,
  (select count(*)::text from pg_policies
    where schemaname='public' and tablename='vg_analytics_events') || ' políticas' as detalle,
  case when (select relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relname='vg_analytics_events')
       and (select count(*) from pg_policies
             where schemaname='public' and tablename='vg_analytics_events'
               and cmd='SELECT' and qual like '%is_admin%') = 1
       then 'OK' else 'REVISAR' end as resultado
union all
select 'S1 xbox con candado',
  (select count(*)::text from pg_policies
    where schemaname='public' and tablename='vg_xbox_games') || ' políticas',
  case when (select relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relname='vg_xbox_games')
       then 'OK' else 'REVISAR' end
union all
select 'S2 precio del catálogo',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='vg_precio_real') || ' de 1 función',
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='vg_precio_real') = 1
       and (select count(*) from information_schema.columns
             where table_schema='public' and table_name='orders'
               and column_name='total_verificado') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S3 correo congelado',
  'disparador vg_users_protege_rol',
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='vg_protege_rol'
                and p.prosrc like '%new.email := old.email%') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S3 recuperación segura',
  'vg_solicitar_password contra auth.users',
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='vg_solicitar_password'
                and p.prosrc like '%auth.users%') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S6 sin auto-referido',
  'restricción vg_users_no_autoreferido',
  case when (select count(*) from pg_constraint
              where conname='vg_users_no_autoreferido') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S7 freno de consultas',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='vg_rate_ok') || ' de 1 función',
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='vg_rate_ok') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S8 chat con firma real',
  'chat_operador_escribe',
  case when (select count(*) from pg_policies
              where schemaname='public' and tablename='vg_live_chat_messages'
                and policyname='chat_operador_escribe'
                and with_check like '%sender_role%') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S9 pedido protegido',
  'disparador orders_protege',
  case when (select count(*) from pg_trigger where tgname='orders_protege') = 1
       then 'OK' else 'REVISAR' end;
