-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 37
--   1. Comprobar si un WhatsApp ya está registrado, sin exponer datos
--   2. ⚠️ CERRAR LA LECTURA PÚBLICA DE vg_users  (LEE EL AVISO)
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. ¿Está ocupado este WhatsApp?
--
--    Devuelve solo sí o no. No dice de quién es, ni el nombre, ni el
--    correo. Es lo único que el formulario de registro necesita saber
--    para avisar antes de intentar el alta.
--
--    Sin esto, al repetir un número el disparador que crea la ficha del
--    cliente choca contra la restricción de teléfono único, y lo que
--    llega al navegador es un error 500 con el cuerpo vacío: el cliente
--    veía "No se pudo registrar: {}".
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_telefono_ocupado(p_phone text)
returns boolean
language sql security definer
set search_path = public
as $$
  select exists (
    select 1 from public.vg_users
     where length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) >= 8
       and regexp_replace(coalesce(phone,''),   '\D', '', 'g')
         = regexp_replace(coalesce(p_phone,''), '\D', '', 'g')
  );
$$;

grant execute on function public.vg_telefono_ocupado(text) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 2. ⚠️ AVISO IMPORTANTE — datos de tus clientes a la vista
--
--    Comprobado en tu sitio en vivo, SIN iniciar sesión:
--
--      supabase.from('vg_users').select('id,name,phone,email')
--
--    devuelve las filas de tus clientes. Cualquiera que abra la consola
--    del navegador puede descargarse tu lista de clientes completa con
--    nombre, correo y WhatsApp.
--
--    El bloque de abajo lo cierra: cada quien ve solo su propia ficha, y
--    tú como administrador las ves todas.
--
--    ANTES DE CORRERLO, LEE ESTO:
--    Tu página tiene módulos viejos que entran con teléfono y contraseña
--    guardados en el navegador, sin sesión de Supabase Auth. Esos leen
--    vg_users sin estar autenticados y DEJARÁN DE FUNCIONAR al cerrar la
--    lectura pública. Los clientes que entran con correo y contraseña
--    (el sistema actual) no se ven afectados.
--
--    Recomendación: córrelo, y prueba enseguida iniciar sesión con una
--    cuenta de cliente. Si algo falla, abajo tienes cómo revertirlo.
-- ═══════════════════════════════════════════════════════════════════

-- ── Quita el comentario de este bloque para aplicarlo ──
/*
alter table public.vg_users enable row level security;

drop policy if exists vgusers_lectura_publica on public.vg_users;
drop policy if exists "vg_users lectura"       on public.vg_users;
drop policy if exists vgusers_select_all       on public.vg_users;
drop policy if exists vgusers_propio           on public.vg_users;

-- Cada cliente ve su ficha; el administrador las ve todas.
create policy vgusers_propio on public.vg_users
  for select to authenticated
  using (id = auth.uid() or public.is_admin());
*/


-- ─────────────────────────────────────────────────────────────
-- 3. Revisar qué políticas de lectura tiene hoy la tabla
--    Corre esto ANTES de tocar nada, para saber de dónde partes.
-- ─────────────────────────────────────────────────────────────
select policyname, roles::text, cmd, qual
  from pg_policies
 where schemaname = 'public' and tablename = 'vg_users'
 order by cmd, policyname;


-- ─────────────────────────────────────────────────────────────
-- 4. PARA REVERTIR, si algo dejó de funcionar
-- ─────────────────────────────────────────────────────────────
/*
drop policy if exists vgusers_propio on public.vg_users;
create policy vgusers_lectura_publica on public.vg_users
  for select to anon, authenticated using (true);
*/


-- ─────────────────────────────────────────────────────────────
-- 5. RESULTADO de la parte 1 — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'vg_telefono_ocupado'
  )::text || ' de 1 (comprobar teléfono)' as funcion,
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'vg_telefono_ocupado') = 1
       then 'OK' else 'REVISAR' end as resultado;
