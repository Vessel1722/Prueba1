-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 19 — Adjuntar imágenes
--
-- Permite mandar fotos en el chat de entrega y en los reportes de
-- falla (por ejemplo, la captura del error que le sale al cliente).
--
-- La tabla del chat ya tenía attachment_url; aquí solo se asegura que
-- exista y se agrega la columna equivalente a los tickets.
--
-- Pega TODO esto en: Supabase → SQL Editor → New query → Run
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. Adjunto en los mensajes del chat
-- ─────────────────────────────────────────────────────────────
alter table public.vg_live_chat_messages add column if not exists attachment_url  text;
alter table public.vg_live_chat_messages add column if not exists attachment_type text;


-- ─────────────────────────────────────────────────────────────
-- 2. Adjunto en los reportes de falla
--    Sirve para que el cliente mande la captura del error, que suele
--    explicar el problema mejor que la descripción escrita.
-- ─────────────────────────────────────────────────────────────
alter table public.vg_support_tickets add column if not exists attachment_url  text;
alter table public.vg_support_tickets add column if not exists attachment_type text;


-- ─────────────────────────────────────────────────────────────
-- 3. Recargar el caché del esquema
-- ─────────────────────────────────────────────────────────────
notify pgrst, 'reload schema';


-- ─────────────────────────────────────────────────────────────
-- 4. RESULTADO — deben aparecer las 4 columnas
-- ─────────────────────────────────────────────────────────────
select
  count(*)::text || ' de 4 columnas' as adjuntos,
  case when count(*) = 4 then 'OK' else 'REVISAR' end as resultado
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'vg_live_chat_messages' and column_name in ('attachment_url','attachment_type'))
    or (table_name = 'vg_support_tickets'    and column_name in ('attachment_url','attachment_type')));


-- ═══════════════════════════════════════════════════════════════════
-- NOTA sobre el tamaño
-- Las imágenes se guardan como data URL dentro de la fila (igual que
-- los comprobantes de pago, que ya funcionan así). El código las
-- reduce a 1280px y las comprime a JPEG antes de subirlas, así que
-- cada una pesa del orden de 100–300 KB.
-- Si algún día el volumen crece mucho, lo que conviene es moverlas a
-- Supabase Storage y guardar aquí solo la URL — el campo ya es texto,
-- así que ese cambio no rompería nada de lo que hay.
-- ═══════════════════════════════════════════════════════════════════
