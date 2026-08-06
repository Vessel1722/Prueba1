-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 69 — La cuenta recuerda sus datos de juego
--
-- Hoy cada pedido de Fortnite empieza con el mismo ida y vuelta:
-- "¿cuál es tu usuario de Epic?". Lo mismo con el gamertag de Xbox o
-- el ID de Free Fire. Guardándolos en su cuenta, la segunda compra ya
-- no pregunta nada.
--
-- Va todo en una sola columna jsonb y no en columnas sueltas, para que
-- añadir un juego nuevo mañana no obligue a tocar la base otra vez.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════

alter table public.vg_users add column if not exists datos_juego jsonb default '{}'::jsonb;


-- ─────────────────────────────────────────────────────────────
-- Guardar los suyos
--
--    Se hace por función y no dejando que la página escriba directo en
--    la tabla: así nadie puede tocar la fila de otro aunque se ponga
--    creativo con la consola. La función solo sabe escribir en la fila
--    de quien la llama.
--
--    Se limpian los valores: máximo 60 caracteres y sin etiquetas, que
--    un nombre de usuario no necesita más y así no entra nada raro que
--    después se pinte en tu panel.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_guardar_datos_juego(p_datos jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_limpio jsonb := '{}'::jsonb;
  k text;
  v text;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para guardar tus datos.';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then
    raise exception 'Datos no válidos.';
  end if;

  for k in select jsonb_object_keys(p_datos) loop
    v := trim(coalesce(p_datos ->> k, ''));
    v := regexp_replace(v, '<[^>]*>', '', 'g');
    v := left(v, 60);
    if v <> '' and k ~ '^[a-z_]{2,20}$' then
      v_limpio := v_limpio || jsonb_build_object(k, v);
    end if;
  end loop;

  update public.vg_users
     set datos_juego = v_limpio
   where id::text = v_uid::text;

  return json_build_object('ok', true, 'guardados', v_limpio);
end;
$$;

grant execute on function public.vg_guardar_datos_juego(jsonb) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- Leer los suyos
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_mis_datos_juego()
returns json
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select datos_juego from public.vg_users where id::text = auth.uid()::text),
    '{}'::jsonb
  )::json;
$$;

grant execute on function public.vg_mis_datos_juego() to authenticated;


-- ─────────────────────────────────────────────────────────────
-- RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='vg_users'
      and column_name='datos_juego')::text || ' de 1 columna' as columna,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('vg_guardar_datos_juego','vg_mis_datos_juego'))::text
    || ' de 2 funciones' as funciones,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='vg_users'
                and column_name='datos_juego') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname in ('vg_guardar_datos_juego','vg_mis_datos_juego')) = 2
       then 'OK' else 'REVISAR' end as resultado;
