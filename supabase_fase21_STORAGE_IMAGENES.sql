-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 21 — Almacenamiento propio de imágenes
--
-- Problema que resuelve:
--   Las 68 imágenes del catálogo están alojadas en imgur, un servicio
--   gratuito de terceros. Si imgur las borra, limita el tráfico o
--   cambia sus reglas, te quedas sin catálogo visual de golpe. Además
--   una de ellas tardó 2.1 s en cargar.
--
-- Este script crea el bucket donde se guardarán en tu propio Supabase.
-- La migración de las imágenes se hace después desde el panel admin,
-- pestaña "🖼 Imágenes".
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Bucket público para las imágenes del catálogo
--    Es público a propósito: son fotos de producto que cualquiera
--    debe poder ver desde la tienda sin iniciar sesión.
-- ─────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'catalogo',
  'catalogo',
  true,
  5242880,                                    -- 5 MB por archivo
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do update
  set public             = true,
      file_size_limit    = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];


-- ─────────────────────────────────────────────────────────────
-- 2. Políticas de acceso
-- ─────────────────────────────────────────────────────────────
drop policy if exists "catalogo lectura publica" on storage.objects;
drop policy if exists "catalogo escritura admin" on storage.objects;
drop policy if exists "catalogo update admin"    on storage.objects;
drop policy if exists "catalogo borrado admin"   on storage.objects;

-- Cualquiera puede VER las imágenes (la tienda es pública)
create policy "catalogo lectura publica" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'catalogo');

-- Solo el admin puede SUBIR
create policy "catalogo escritura admin" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'catalogo' and public.is_admin());

-- Solo el admin puede REEMPLAZAR
create policy "catalogo update admin" on storage.objects
  for update to authenticated
  using (bucket_id = 'catalogo' and public.is_admin())
  with check (bucket_id = 'catalogo' and public.is_admin());

-- Solo el admin puede BORRAR
create policy "catalogo borrado admin" on storage.objects
  for delete to authenticated
  using (bucket_id = 'catalogo' and public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- 3. RESULTADO — debe decir OK
-- ─────────────────────────────────────────────────────────────
select
  (select count(*) from storage.buckets where id='catalogo')::text || ' bucket' as bucket,
  (select count(*) from pg_policies
     where schemaname='storage' and tablename='objects'
       and policyname like 'catalogo%')::text || ' de 4 politicas' as politicas,
  case when (select count(*) from storage.buckets where id='catalogo') = 1
        and (select count(*) from pg_policies
               where schemaname='storage' and tablename='objects'
                 and policyname like 'catalogo%') = 4
       then 'OK' else 'REVISAR' end as resultado;


-- ═══════════════════════════════════════════════════════════════════
-- SIGUIENTE PASO
-- Entra al panel admin → pestaña "🖼 Imágenes" y pulsa
-- "Migrar imágenes de imgur". El navegador descargará cada imagen de
-- imgur, la subirá a este bucket y actualizará la URL en la tabla
-- products. Puedes seguir el avance en pantalla.
-- ═══════════════════════════════════════════════════════════════════
