-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 38 — Arreglos de la auditoría de seguridad
--
-- Dos fallas, ambas comprobadas en el sitio en vivo SIN iniciar sesión:
--
--   1. products_admin quedó abierta a cualquiera. Se pudo insertar una
--      fila, modificarla y borrarla desde el navegador, sin cuenta.
--      Son tus 269 productos: precios, títulos, fotos y disponibilidad.
--
--   2. El almacén de comprobantes es público. Se pudo listar las
--      carpetas (una por pedido) y descargar el comprobante de pago de
--      un cliente: HTTP 200, image/png, 160 KB. Son capturas de
--      transferencias bancarias.
--
-- Corre el archivo entero. Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 0. Copia de seguridad de las políticas actuales, por si acaso
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_policies_backup_f38 as
  select * from pg_policies
   where schemaname in ('public','storage')
     and tablename in ('products_admin','objects');


-- ─────────────────────────────────────────────────────────────
-- 1. El catálogo: que lo lea todo el mundo, que lo escriba solo tú
--
--    La lectura tiene que seguir siendo pública: es la tienda, y la ve
--    gente sin cuenta. Lo que se cierra es escribir.
-- ─────────────────────────────────────────────────────────────
alter table public.products_admin enable row level security;

do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname='public' and tablename='products_admin'
  loop
    execute format('drop policy if exists %I on public.products_admin', p.policyname);
  end loop;
end $$;

create policy prodadmin_lectura on public.products_admin
  for select to anon, authenticated using (true);

create policy prodadmin_escritura on public.products_admin
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 2. Los comprobantes de pago dejan de ser públicos
--
--    Puede verlos el administrador, y el cliente dueño del pedido.
--    Nadie más, ni con el enlace directo.
--
--    Los archivos se guardan en una carpeta por pedido: "10/xxx.png".
--    De ahí sale el número de pedido con el que se comprueba el dueño.
-- ─────────────────────────────────────────────────────────────
update storage.buckets set public = false where id = 'comprobantes';

drop policy if exists "comprobantes lectura publica"   on storage.objects;
drop policy if exists "comprobantes lectura"           on storage.objects;
drop policy if exists "comprobantes lectura duenio"    on storage.objects;
drop policy if exists "comprobantes subida"            on storage.objects;
drop policy if exists "comprobantes escritura"         on storage.objects;
drop policy if exists "comprobantes borrado admin"     on storage.objects;

create policy "comprobantes lectura duenio" on storage.objects
  for select to authenticated
  using (
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

-- El cliente sube su comprobante al terminar el pedido.
create policy "comprobantes subida" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'comprobantes');

create policy "comprobantes borrado admin" on storage.objects
  for delete to authenticated
  using (bucket_id = 'comprobantes' and public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 3. RESULTADO — debe decir OK en las dos filas
-- ─────────────────────────────────────────────────────────────
select
  'catálogo' as que,
  (select count(*) from pg_policies
    where schemaname='public' and tablename='products_admin')::text || ' políticas' as detalle,
  case when (select count(*) from pg_policies
              where schemaname='public' and tablename='products_admin'
                and cmd='ALL' and roles::text like '%authenticated%') >= 1
        and (select count(*) from pg_policies
              where schemaname='public' and tablename='products_admin'
                and cmd='SELECT') = 1
       then 'OK' else 'REVISAR' end as resultado
union all
select
  'comprobantes',
  case when (select public from storage.buckets where id='comprobantes') then 'PÚBLICO' else 'privado' end,
  case when (select public from storage.buckets where id='comprobantes') = false
       then 'OK' else 'REVISAR' end;
