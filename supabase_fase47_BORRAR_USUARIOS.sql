-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 47 — Borrar usuarios desde el panel
--
-- Por qué te siguen saliendo cuentas que ya borraste:
--   vg_users.id es un uuid suelto, sin llave hacia auth.users. Al borrar
--   la cuenta en Authentication, su ficha en vg_users se queda huérfana
--   y sigue apareciendo en el panel.
--
-- Esta función borra de verdad: la ficha, su wallet, sus movimientos de
-- tokens, sus canjes, sus tickets, sus solicitudes de contraseña y —si
-- lo confirmas— sus pedidos con su chat. Y al final la cuenta de acceso.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Cuántas cosas cuelgan de un usuario
--    Sirve para avisarte ANTES de borrar, no después.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_usuario_resumen(p_id uuid)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v json;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  select json_build_object(
    'nombre',    (select name  from public.vg_users where id = p_id),
    'email',     (select email from public.vg_users where id = p_id),
    'es_admin',  coalesce((select is_admin from public.vg_users where id = p_id), false),
    'pedidos',   (select count(*) from public.orders where user_id::text = p_id::text),
    'referidos', (select count(*) from public.vg_users where referred_by = p_id),
    'tiene_acceso', exists(select 1 from auth.users where id = p_id)
  ) into v;

  return v;
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 2. Borrar
--
--    p_con_pedidos = false  → si el usuario tiene pedidos, se niega.
--    p_con_pedidos = true   → borra también sus pedidos y su chat.
--
--    No se puede borrar tu propia cuenta ni otra que sea administradora:
--    un clic de más y te quedas fuera de tu propio panel.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_borrar_usuario(
  p_id          uuid,
  p_con_pedidos boolean default false
)
returns json
language plpgsql security definer
set search_path = public
as $$
declare
  v_pedidos integer;
  v_nombre  text;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  if p_id is null then
    raise exception 'Falta indicar el usuario.';
  end if;
  if p_id = auth.uid() then
    raise exception 'No puedes borrar tu propia cuenta.';
  end if;
  if coalesce((select is_admin from public.vg_users where id = p_id), false) then
    raise exception 'Esa cuenta es administradora. Quítale el rol antes de borrarla.';
  end if;

  select name into v_nombre from public.vg_users where id = p_id;

  select count(*) into v_pedidos
    from public.orders where user_id::text = p_id::text;

  if v_pedidos > 0 and not p_con_pedidos then
    raise exception 'Ese usuario tiene % pedido(s). Confirma que quieres borrarlos también.', v_pedidos;
  end if;

  -- Quien fue referido por él deja de apuntarle, si no la llave lo impide
  update public.vg_users set referred_by = null where referred_by = p_id;

  -- Todo lo que cuelga del usuario
  delete from public.vg_token_tx          where user_id = p_id;
  delete from public.vg_token_redemptions where user_id = p_id;
  delete from public.vg_token_wallet      where user_id = p_id;
  delete from public.vg_support_tickets   where user_id = p_id;
  delete from public.vg_password_requests where user_id = p_id;

  if p_con_pedidos and v_pedidos > 0 then
    delete from public.vg_live_chat_messages
     where thread_ref in (
       select id::text from public.orders where user_id::text = p_id::text
     );
    delete from public.orders where user_id::text = p_id::text;
  end if;

  delete from public.vg_users where id = p_id;

  -- La cuenta de acceso. Va al final: si algo falla antes, no se pierde.
  begin
    delete from auth.users where id = p_id;
  exception when others then
    raise warning 'No se pudo borrar la cuenta de acceso de %: %', p_id, sqlerrm;
  end;

  return json_build_object('ok', true, 'nombre', v_nombre, 'pedidos_borrados',
                           case when p_con_pedidos then v_pedidos else 0 end);
end;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3. Limpieza de fichas huérfanas
--    Las de cuentas que ya borraste desde Authentication y se quedaron.
--    Devuelve cuántas quitó. Nunca toca administradores.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_admin_limpiar_huerfanos()
returns integer
language plpgsql security definer
set search_path = public
as $$
declare v_n integer := 0; v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  for v_id in
    select u.id from public.vg_users u
     where not exists (select 1 from auth.users a where a.id = u.id)
       and coalesce(u.is_admin, false) = false
  loop
    update public.vg_users set referred_by = null where referred_by = v_id;
    delete from public.vg_token_tx          where user_id = v_id;
    delete from public.vg_token_redemptions where user_id = v_id;
    delete from public.vg_token_wallet      where user_id = v_id;
    delete from public.vg_support_tickets   where user_id = v_id;
    delete from public.vg_password_requests where user_id = v_id;
    delete from public.vg_users             where id = v_id;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;


grant execute on function public.vg_admin_usuario_resumen(uuid)        to authenticated;
grant execute on function public.vg_admin_borrar_usuario(uuid,boolean) to authenticated;
grant execute on function public.vg_admin_limpiar_huerfanos()          to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 4. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
    ('vg_admin_usuario_resumen','vg_admin_borrar_usuario','vg_admin_limpiar_huerfanos')
  )::text || ' de 3 funciones' as funciones,
  (select count(*) from public.vg_users u
    where not exists (select 1 from auth.users a where a.id = u.id))::text
    || ' fichas huérfanas por limpiar' as huerfanos,
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in
              ('vg_admin_usuario_resumen','vg_admin_borrar_usuario','vg_admin_limpiar_huerfanos')) = 3
       then 'OK' else 'REVISAR' end as resultado;
