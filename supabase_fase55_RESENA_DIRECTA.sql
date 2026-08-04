-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 55 — Reseña con un botón, desde el pedido
--
-- Antes el mensaje decía "déjala en la página de inicio, en la sección
-- de reseñas". El cliente tenía que salir del panel, buscar la sección,
-- volver a escribir qué compró y cómo se llama. Casi nadie lo hace.
--
-- Ahora deja la reseña desde su propio pedido, en dos toques, y se lleva
-- tokens por hacerlo.
--
-- De paso se arregla algo que estaba mal desde la fase 45: cada reseña
-- que dejaba un cliente te llegaba al teléfono como "PEDIDO NUEVO", con
-- $0. Las reseñas se guardan en la misma tabla que los pedidos y el
-- aviso no las distinguía.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Marca de "este pedido ya tiene reseña"
--
--    Va en el pedido y no en una tabla aparte para que baste con leer
--    el pedido y saber si hay que ofrecer el botón o no.
-- ─────────────────────────────────────────────────────────────
alter table public.orders add column if not exists resena_at timestamptz;


-- ─────────────────────────────────────────────────────────────
-- 2. Cuántos tokens vale una reseña
--
--    Se pone junto a los otros premios para que lo cambies desde ahí y
--    no dentro del código. Media ficha: el doble de lo que da una compra
--    (0.25) y la mitad de un referido (1.00). Suficiente para que valga
--    la pena, no tanto como para que alguien invente compras.
-- ─────────────────────────────────────────────────────────────
insert into public.vg_token_config (clave, valor, nota) values
  ('por_resena', 0.5, 'Tokens que gana el cliente al dejar la reseña de un pedido entregado')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────
-- 3. Dejar la reseña
--
--    Todas las condiciones se comprueban aquí dentro, no en la página:
--    lo que viaja desde el navegador nunca decide si algo se permite.
--
--      · tiene que haber sesión iniciada;
--      · el pedido tiene que ser suyo;
--      · tiene que estar entregado —no se reseña lo que no se recibió—;
--      · una sola reseña por pedido.
--
--    La reseña nace en 'pendiente'. Nada se publica solo: tú decides
--    desde la pestaña Recomendaciones.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_dejar_resena(
  p_order     text,
  p_estrellas integer,
  p_texto     text,
  p_nombre    text default null
)
returns json
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_ped    record;
  v_nombre text;
  v_prod   text;
  v_premio numeric;
  v_texto  text := trim(coalesce(p_texto,''));
begin
  if v_uid is null then
    raise exception 'Inicia sesión para dejar tu reseña.';
  end if;
  if length(v_texto) < 10 then
    raise exception 'Escribe un poco más, con diez letras no se entiende.';
  end if;
  if coalesce(p_estrellas,0) not between 1 and 5 then
    raise exception 'Las estrellas van del 1 al 5.';
  end if;

  select * into v_ped
    from public.orders
   where id::text = trim(coalesce(p_order,''))
     and user_id::text = v_uid::text;

  if not found then
    raise exception 'Ese pedido no es tuyo.';
  end if;
  if coalesce(v_ped.status,'') <> 'entregado' then
    raise exception 'Podrás dejar tu reseña cuando el pedido esté entregado.';
  end if;
  if v_ped.resena_at is not null then
    raise exception 'Ya dejaste la reseña de este pedido. ¡Gracias!';
  end if;

  /* El nombre que puso, si puso alguno; si no, el de su cuenta */
  v_nombre := nullif(trim(coalesce(p_nombre,'')), '');
  if v_nombre is null then
    select nullif(trim(name),'') into v_nombre from public.vg_users where id::text = v_uid::text;
  end if;
  v_nombre := coalesce(v_nombre, 'Cliente VG');

  v_prod := coalesce(
    nullif(trim(v_ped.product_name), ''),
    nullif(trim((v_ped.items -> 0 ->> 'title')), ''),
    'Servicio digital'
  );

  /* La reseña se guarda con la misma forma que las del formulario
     público, para que la pestaña Recomendaciones las muestre igual. */
  insert into public.orders (source, status, total, items, notes, client_name, proof)
  values ('recommendation', 'pendiente', 0,
    jsonb_build_array(jsonb_build_object(
      'title',   'Recomendación cliente',
      'service', v_prod,
      'review',  v_texto,
      'stars',   p_estrellas,
      'customer',v_nombre,
      'price',   0,
      'pedido',  v_ped.id::text
    )),
    v_texto, v_nombre, null);

  update public.orders set resena_at = now() where id = v_ped.id;

  /* Los tokens. Si algo falla aquí la reseña ya quedó guardada: vale
     más perder medio token que perder la opinión del cliente. */
  begin
    select valor into v_premio from public.vg_token_config where clave = 'por_resena';
    v_premio := coalesce(v_premio, 0.5);

    if v_premio > 0 then
      insert into public.vg_token_wallet (user_id, balance, total_earned)
      values (v_uid, v_premio, v_premio)
      on conflict (user_id) do update
        set balance      = coalesce(public.vg_token_wallet.balance, 0)      + v_premio,
            total_earned = coalesce(public.vg_token_wallet.total_earned, 0) + v_premio,
            updated_at   = now();

      insert into public.vg_token_tx (user_id, cantidad, motivo, order_id, detalle)
      values (v_uid, v_premio, 'resena', v_ped.id::text, 'Reseña de ' || v_prod);
    end if;
  exception when others then
    v_premio := 0;
    raise warning 'vg_dejar_resena: no se pudieron dar los tokens (%)', sqlerrm;
  end;

  return json_build_object('ok', true, 'tokens', coalesce(v_premio, 0));
end;
$$;

grant execute on function public.vg_dejar_resena(text,integer,text,text) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 4. Qué pedidos míos ya tienen reseña
--
--    La página lo pregunta una vez al abrir el panel y con eso sabe en
--    cuáles poner el botón y en cuáles poner el "gracias".
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_mis_resenas()
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_res json;
begin
  if v_uid is null then return '[]'::json; end if;
  select coalesce(json_agg(o.id::text), '[]'::json) into v_res
    from public.orders o
   where o.user_id::text = v_uid::text
     and o.resena_at is not null;
  return v_res;
end;
$$;

grant execute on function public.vg_mis_resenas() to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 5. El aviso al teléfono ya no confunde reseñas con ventas
--
--    Las reseñas viven en la tabla orders con source='recommendation'.
--    El disparador de la fase 45 no lo miraba y te mandaba un
--    "🛒 PEDIDO NUEVO ... $0.00 MXN" cada vez que alguien opinaba.
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
  if coalesce(new.source,'') = 'recommendation' then
    return new;
  end if;

  begin
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
    raise warning 'vg_avisar_pedido: no se pudo enviar el aviso (%)', sqlerrm;
  end;

  return new;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 6. El mensaje automático ahora apunta al botón
--
--    Decirle "vete a la página de inicio y búscala" era pedirle trabajo.
--    Ahora se le dice exactamente dónde tocar, y que hay tokens.
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
         'Si todo salió bien, ¿nos dejas tu reseña? Arriba de este chat, en tu ' ||
         'pedido, está el botón ⭐ Dejar mi reseña. Te toma diez segundos y te ' ||
         'ganas tokens para tu próxima compra.' || chr(10) || chr(10) ||
         'Y si algo no salió como esperabas, contéstanos por aquí y lo arreglamos.');

      new.aviso_resena := true;
    exception when others then
      raise warning 'vg_pedir_resena: no se pudo dejar el mensaje (%)', sqlerrm;
    end;
  end if;
  return new;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 7. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='orders' and column_name='resena_at')::text
    || ' de 1 columna' as columna,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('vg_dejar_resena','vg_mis_resenas'))::text
    || ' de 2 funciones' as funciones,
  (select valor from public.vg_token_config where clave='por_resena')::text
    || ' tokens por resena' as premio,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='orders'
                and column_name='resena_at') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_dejar_resena','vg_mis_resenas')) = 2
       then 'OK' else 'REVISAR' end as resultado;
