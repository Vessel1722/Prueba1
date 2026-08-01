-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 45 — Aviso al teléfono cuando entra un pedido
--
-- La base de datos manda el mensaje ella sola en cuanto se crea el
-- pedido. No depende de que tengas la página abierta, ni la PC
-- encendida, ni el panel de administración cargado.
--
-- Funciona con cualquier servicio que reciba un mensaje por URL.
-- Abajo, en el paso 5, están las instrucciones para WhatsApp y para
-- Telegram. Puedes dejar los dos puestos a la vez.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Permiso para que la base haga llamadas a internet
-- ─────────────────────────────────────────────────────────────
create extension if not exists pg_net with schema extensions;


-- ─────────────────────────────────────────────────────────────
-- 2. Dónde mandar el aviso
--
--    Se guarda aquí y no dentro de la función para que puedas cambiar
--    tu número o tu clave sin tocar código. {msg} es donde se mete el
--    texto del pedido, ya preparado para viajar en una URL.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_avisos (
  clave      text primary key,
  url        text,
  activo     boolean default true,
  nota       text,
  updated_at timestamptz default now()
);

insert into public.vg_avisos (clave, url, activo, nota) values
  ('whatsapp', '', false, 'Pega aquí tu URL de CallMeBot y pon activo = true'),
  ('telegram', '', false, 'Pega aquí tu URL de Telegram y pon activo = true')
on conflict (clave) do nothing;

alter table public.vg_avisos enable row level security;
drop policy if exists avisos_admin on public.vg_avisos;
create policy avisos_admin on public.vg_avisos
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 3. Preparar el texto para que viaje en una URL
--
--    Sin esto, un pedido con acentos, espacios o un "&" en el nombre
--    del producto rompería la dirección y el aviso no llegaría.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_urlencode(p_txt text)
returns text
language plpgsql immutable
as $$
declare
  v_res text := '';
  v_by  bytea;
  i     integer;
  b     integer;
begin
  if p_txt is null then return ''; end if;
  v_by := convert_to(p_txt, 'UTF8');
  for i in 0 .. octet_length(v_by) - 1 loop
    b := get_byte(v_by, i);
    if (b between 48 and 57)     -- 0-9
    or (b between 65 and 90)     -- A-Z
    or (b between 97 and 122)    -- a-z
    or b in (45, 46, 95, 126)    -- - . _ ~
    then
      v_res := v_res || chr(b);
    else
      v_res := v_res || '%' || upper(lpad(to_hex(b), 2, '0'));
    end if;
  end loop;
  return v_res;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 4. El disparador
--
--    Va DESPUÉS de insertar y con todo dentro de un "exception when
--    others": si el servicio de avisos está caído o la clave está mal,
--    el pedido del cliente se guarda igual. Nunca se pierde una venta
--    por culpa de una notificación.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_avisar_pedido()
returns trigger
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_msg      text;
  v_prod     text;
  v_cliente  text;
  v_destino  record;
begin
  begin
    -- Qué compró: primero el nombre suelto, si no el primer artículo
    v_prod := coalesce(
      nullif(trim(new.product_name), ''),
      nullif(trim((new.items -> 0 ->> 'title')), ''),
      'Pedido'
    );
    if coalesce(new.product_option,'') <> '' then
      v_prod := v_prod || ' · ' || new.product_option;
    end if;

    v_cliente := coalesce(
      nullif(trim(new.customer_name), ''),
      nullif(trim(new.client_name), ''),
      'Cliente'
    );

    v_msg :=
      '🛒 PEDIDO NUEVO' || chr(10) ||
      '#' || left(new.id::text, 8) || chr(10) ||
      v_prod || chr(10) ||
      '💰 $' || to_char(coalesce(new.total,0), 'FM999G999D00') || ' MXN' || chr(10) ||
      '👤 ' || v_cliente ||
      case when coalesce(new.customer_phone,'') <> ''
           then chr(10) || '📱 ' || new.customer_phone else '' end ||
      chr(10) || '🕘 ' ||
      to_char(timezone('America/Tijuana', now()), 'HH24:MI');

    -- Se manda a todos los destinos encendidos
    for v_destino in
      select url from public.vg_avisos
       where activo = true and coalesce(url,'') <> ''
    loop
      perform net.http_get(
        url := replace(v_destino.url, '{msg}', public.vg_urlencode(v_msg)),
        timeout_milliseconds := 4000
      );
    end loop;

  exception when others then
    -- El aviso falló, pero el pedido ya está guardado. Se deja constancia
    -- en los registros de Postgres y se sigue adelante.
    raise warning 'vg_avisar_pedido: no se pudo enviar el aviso (%)', sqlerrm;
  end;

  return new;
end;
$$;

drop trigger if exists vg_orders_avisar on public.orders;
create trigger vg_orders_avisar
  after insert on public.orders
  for each row execute function public.vg_avisar_pedido();


-- ─────────────────────────────────────────────────────────────
-- 5. CÓMO ENCENDERLO  ·  elige uno o pon los dos
--
-- ── WhatsApp (CallMeBot, gratis) ──────────────────────────────
--   Entra a callmebot.com/blog/free-api-whatsapp-messages/ y sigue
--   los pasos que aparezcan ahí: te dicen a qué número escribir y qué
--   frase mandar para que te devuelva tu clave (apikey).
--   No pongo el número aquí porque ese servicio lo ha cambiado antes
--   y prefiero que tomes el que esté vigente.
--
--   Cuando tengas tu clave:
--
--     update public.vg_avisos
--        set url = 'https://api.callmebot.com/whatsapp.php'
--                  || '?phone=5216611078412'
--                  || '&apikey=TU_CLAVE'
--                  || '&text={msg}',
--            activo = true
--      where clave = 'whatsapp';
--
-- ── Telegram (oficial, más confiable) ─────────────────────────
--   1. En Telegram busca @BotFather y manda /newbot
--   2. Le pones nombre y te da un token largo
--   3. Escríbele algo a tu bot para abrir la conversación
--   4. Busca @userinfobot y te dice tu Chat ID
--
--     update public.vg_avisos
--        set url = 'https://api.telegram.org/bot TU_TOKEN /sendMessage'
--                  || '?chat_id=TU_CHAT_ID'
--                  || '&text={msg}',
--            activo = true
--      where clave = 'telegram';
--
--   (quita los espacios alrededor de TU_TOKEN)
-- ─────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────
-- 6. PROBARLO sin tener que hacer una compra
--
--   Corre esto y debe llegarte el mensaje en unos segundos:
--
--     select net.http_get(
--       url := replace(
--         (select url from public.vg_avisos where clave='whatsapp'),
--         '{msg}',
--         public.vg_urlencode('Prueba de aviso de Vessel Games ✅')
--       )
--     );
--
--   Si no llega, revisa qué respondió:
--
--     select status_code, left(content, 300) as respuesta
--       from net._http_response
--      order by created desc limit 3;
-- ─────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────
-- 7. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from pg_extension where extname='pg_net')::text || ' de 1 (pg_net)' as extension,
  (select count(*) from pg_trigger where tgname='vg_orders_avisar')::text || ' de 1 (disparador)' as disparador,
  (select count(*) from public.vg_avisos where activo = true and coalesce(url,'') <> '')::text
    || ' destino(s) encendido(s)' as destinos,
  case when (select count(*) from pg_extension where extname='pg_net') = 1
        and (select count(*) from pg_trigger where tgname='vg_orders_avisar') = 1
       then 'OK — ahora llena la URL del paso 5'
       else 'REVISAR' end as resultado;
