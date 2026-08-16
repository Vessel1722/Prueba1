-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 76 — Cierra la escalada de privilegios
--
-- Cuatro agujeros encontrados en la auditoría. El primero es grave:
--
--   S1 (CRÍTICO) Cualquier cliente registrado podía escribirse
--       is_admin = true sobre su propia fila y quedar como dueño de
--       la tienda. La política vg_users_update_own deja editar la
--       fila propia y NO limita qué columnas, y ahí viven is_admin
--       y rol.
--
--   S2 (ALTO) Lo mismo con la cartera: el cliente podía ponerse el
--       saldo de tokens que quisiera y canjear premios gratis.
--
--   S4 (MEDIO) Se podían subir comprobantes a la carpeta de un
--       pedido ajeno. La lectura ya estaba bien cerrada (fase 38);
--       faltaba el candado al escribir.
--
--   S7 (BAJO) Una tabla de respaldo quedó sin reglas de fila.
--
-- Corre el archivo entero. Es idempotente: se puede repetir.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- S1. Que nadie se ascienda a sí mismo
--
--    No se toca la política: el cliente tiene que poder seguir
--    editando su nombre y su teléfono desde el panel. Lo que se
--    pone es un guardia en la puerta que vigila SOLO esas dos
--    columnas.
--
--    Si quien edita no es admin, los valores viejos se vuelven a
--    poner en silencio. Se prefiere revertir a lanzar un error:
--    así el cliente que guarda su perfil normal no ve nada raro,
--    y el que lo intenta a propósito se queda sin premio.
-- ─────────────────────────────────────────────────────────────

-- Por si la columna rol nunca se llegó a crear (fase 71)
alter table public.vg_users add column if not exists rol text;

create or replace function public.vg_protege_rol()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.is_admin is distinct from old.is_admin
      or new.rol is distinct from old.rol)
     and not public.is_admin() then
    new.is_admin := old.is_admin;
    new.rol      := old.rol;
  end if;
  return new;
end;
$$;

drop trigger if exists vg_users_protege_rol on public.vg_users;
create trigger vg_users_protege_rol
  before update on public.vg_users
  for each row execute function public.vg_protege_rol();


-- ─────────────────────────────────────────────────────────────
-- S2. La cartera deja de ser editable por su dueño
--
--    IMPORTANTE — esto NO rompe los tokens. Los que reparten y
--    descuentan saldo son funciones SECURITY DEFINER, que corren
--    como dueñas de la tabla y se saltan estas reglas por diseño:
--
--      · vg_canjear_recompensa()  → el canje del panel de cliente
--      · vg_token_mover()         → mueve el saldo
--      · vg_tokens_al_entregar()  → el disparador al entregar
--      · vg_admin_ajustar_tokens()→ el ajuste manual del panel
--
--    Lo que sí deja de funcionar es el código viejo que restaba
--    el saldo desde el navegador. Eso es exactamente el agujero:
--    si el navegador puede restar, también puede sumar.
-- ─────────────────────────────────────────────────────────────
drop policy if exists wallet_update on public.vg_token_wallet;
create policy wallet_update on public.vg_token_wallet
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- La cartera ya la crea sola el disparador de alta de usuario
-- (handle_new_user), así que nadie necesita insertarla a mano.
drop policy if exists wallet_insert on public.vg_token_wallet;
create policy wallet_insert on public.vg_token_wallet
  for insert to authenticated
  with check (public.is_admin());

-- La lectura se queda igual: cada quien ve su saldo, el admin ve todos.
drop policy if exists wallet_select on public.vg_token_wallet;
create policy wallet_select on public.vg_token_wallet
  for select to authenticated
  using (user_id::text = auth.uid()::text or public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- S3 (parte de base de datos). Los datos de pago salen del HTML
--
--    Hasta ahora los números de tarjeta estaban escritos en el
--    index.html y solo se tapaban con CSS: cualquiera los veía
--    con "ver código fuente", sin cuenta.
--
--    Aquí viven ahora. Lectura SOLO con sesión iniciada; escritura
--    solo admin. La página los pide al abrir el modal de pago.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_datos_pago (
  clave      text primary key,
  etiqueta   text,
  banco      text,
  numero     text,
  titular    text,
  nota       text,
  activo     boolean default true,
  orden      integer default 0,
  updated_at timestamptz default now()
);

alter table public.vg_datos_pago enable row level security;

drop policy if exists datos_pago_lee   on public.vg_datos_pago;
drop policy if exists datos_pago_admin on public.vg_datos_pago;

-- Solo con sesión. Sin cuenta no se ve nada.
create policy datos_pago_lee on public.vg_datos_pago
  for select to authenticated using (activo = true);

create policy datos_pago_admin on public.vg_datos_pago
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ⚠️ FASE 77 — LOS NÚMEROS DE VERDAD NO VAN AQUÍ
--
--    Este archivo está en git y sube a GitHub. Al sacar los datos de
--    pago del index.html se escribieron aquí, que es cambiar una
--    vitrina por otra: quien clone el repositorio los ve igual.
--
--    Se dejan los métodos creados con el número en blanco. Los reales
--    se escriben UNA vez, a mano, donde solo tú entras:
--
--      Supabase → Table editor → vg_datos_pago → columna "numero"
--
--    Si estos números llegaron a estar en un repositorio público, hay
--    que darlos por vistos y cambiar la cuenta con el banco: borrarlos
--    del código no los borra del historial de git.
insert into public.vg_datos_pago (clave, etiqueta, banco, numero, titular, nota, orden) values
  ('bbva',    'Transferencia BBVA', 'BBVA',          '', '', 'Tarjeta', 1),
  ('oxxo',    'Depósito OXXO',      'Spin by OXXO',  '', '', 'Tarjeta', 2),
  ('binance', 'Binance USDT',       'Binance',       '', '', 'Pay ID',  3)
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────
-- S4. El comprobante solo entra en la carpeta del pedido propio
--
--    Las carpetas del almacén se llaman como el número de pedido
--    ("10/xxx.png"), así que de ahí sale con quién comprobar.
--    El admin puede subir a cualquiera.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "comprobantes subida" on storage.objects;
create policy "comprobantes subida" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprobantes'
    and (
      public.is_admin()
      or exists (
        select 1 from public.orders o
         where o.id::text = (storage.foldername(name))[1]
           and o.user_id::text = auth.uid()::text
      )
    )
  );


-- ─────────────────────────────────────────────────────────────
-- S7. Fuera la tabla de respaldo sin candado
--
--    Se creó en la fase 38 con "create table as", que no activa
--    las reglas de fila. Hoy no devuelve nada, pero es una tabla
--    abierta ahí puesta y ya no hace falta.
-- ─────────────────────────────────────────────────────────────
drop table if exists public.vg_policies_backup_f38;


-- ═══════════════════════════════════════════════════════════════════
-- RESULTADO — las cinco filas tienen que decir OK
-- ═══════════════════════════════════════════════════════════════════
select 'S1 nadie se asciende' as que,
  (select count(*)::text from pg_trigger where tgname = 'vg_users_protege_rol') || ' disparador' as detalle,
  case when (select count(*) from pg_trigger where tgname = 'vg_users_protege_rol') = 1
       then 'OK' else 'REVISAR' end as resultado
union all
select 'S2 cartera cerrada',
  (select count(*)::text from pg_policies
    where schemaname = 'public' and tablename = 'vg_token_wallet'
      and cmd in ('UPDATE','INSERT') and qual like '%is_admin%') || ' de 2 políticas',
  case when (select count(*) from pg_policies
              where schemaname = 'public' and tablename = 'vg_token_wallet'
                and cmd = 'UPDATE' and qual like '%is_admin%'
                and qual not like '%auth.uid%') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S3 datos de pago',
  (select count(*)::text from public.vg_datos_pago) || ' métodos guardados',
  case when (select count(*) from pg_policies
              where schemaname = 'public' and tablename = 'vg_datos_pago') >= 2
       then 'OK' else 'REVISAR' end
union all
select 'S4 comprobantes',
  'subida por dueño',
  case when (select count(*) from pg_policies
              where schemaname = 'storage' and tablename = 'objects'
                and policyname = 'comprobantes subida'
                and with_check like '%orders%') = 1
       then 'OK' else 'REVISAR' end
union all
select 'S7 respaldo borrado',
  'vg_policies_backup_f38',
  case when not exists (select 1 from information_schema.tables
                         where table_schema = 'public'
                           and table_name = 'vg_policies_backup_f38')
       then 'OK' else 'REVISAR' end;
