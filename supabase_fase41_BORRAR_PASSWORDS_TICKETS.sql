-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 41 — Las contraseñas de los tickets se borran solas
--
-- Cuando un cliente reporta que su Netflix no entra, te manda el correo
-- y la contraseña de esa cuenta. Hoy se quedan guardadas en texto plano
-- para siempre, aunque el ticket lleve meses resuelto.
--
-- Con esto la contraseña se borra sola en cuanto marcas el ticket como
-- resuelto o cerrado. Ya no tienes que acordarte de hacerlo.
--
-- El resto del ticket (producto, fecha, descripción del problema) se
-- conserva intacto: eso es lo que te sirve de historial.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. El disparador
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_borrar_password_ticket()
returns trigger
language plpgsql
as $$
begin
  if new.status in ('resuelto','cerrado')
     and coalesce(new.account_password,'') not in ('', '[borrada]')
  then
    new.account_password := '[borrada]';
  end if;
  return new;
end;
$$;

drop trigger if exists vg_ticket_borra_password on public.vg_support_tickets;
create trigger vg_ticket_borra_password
  before update on public.vg_support_tickets
  for each row execute function public.vg_borrar_password_ticket();


-- ─────────────────────────────────────────────────────────────
-- 2. Limpieza de lo que ya está resuelto
--    Los tickets viejos siguen guardando la contraseña; se vacían ahora.
-- ─────────────────────────────────────────────────────────────
update public.vg_support_tickets
   set account_password = '[borrada]',
       updated_at = now()
 where status in ('resuelto','cerrado')
   and coalesce(account_password,'') not in ('', '[borrada]');


-- ─────────────────────────────────────────────────────────────
-- 3. Red de seguridad por antigüedad
--
--    Por si un ticket se queda abierto y olvidado: esta función borra
--    las contraseñas de todo lo que tenga más de los días que le pases,
--    sin importar su estado. Devuelve cuántas limpió.
--
--    Puedes correrla a mano de vez en cuando:
--        select public.vg_limpiar_passwords_viejas(30);
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_limpiar_passwords_viejas(p_dias integer default 30)
returns integer
language plpgsql security definer
set search_path = public
as $$
declare v_n integer;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  update public.vg_support_tickets
     set account_password = '[borrada]',
         updated_at = now()
   where created_at < now() - (p_dias || ' days')::interval
     and coalesce(account_password,'') not in ('', '[borrada]');

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

grant execute on function public.vg_limpiar_passwords_viejas(integer) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 4. RESULTADO — debe decir OK y 0 contraseñas guardadas en resueltos
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from pg_trigger
    where tgname = 'vg_ticket_borra_password'
  )::text || ' de 1 (disparador)' as disparador,
  (select count(*) from public.vg_support_tickets
    where status in ('resuelto','cerrado')
      and coalesce(account_password,'') not in ('', '[borrada]')
  )::text || ' contraseñas sueltas en tickets resueltos' as pendientes,
  (select count(*) from public.vg_support_tickets
    where coalesce(account_password,'') not in ('', '[borrada]')
  )::text || ' contraseñas vivas (tickets aún abiertos)' as abiertos,
  case when (select count(*) from pg_trigger where tgname='vg_ticket_borra_password') = 1
        and (select count(*) from public.vg_support_tickets
              where status in ('resuelto','cerrado')
                and coalesce(account_password,'') not in ('', '[borrada]')) = 0
       then 'OK' else 'REVISAR' end as resultado;
