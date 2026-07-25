-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN DE LA FASE 17
-- Corre esto y revisa la columna "resultado": todo debe decir OK.
-- ═══════════════════════════════════════════════════════════════════
with chequeos as (

  -- 1. Columnas nuevas en orders (deben ser 6)
  select
    '1. Columnas nuevas en orders' as chequeo,
    count(*)::text || ' de 6' as detalle,
    case when count(*) = 6 then 'OK' else 'FALTAN' end as resultado
  from information_schema.columns
  where table_schema='public' and table_name='orders'
    and column_name in ('chat_unlocked','proof_data_url','delivery_data',
                        'unread_admin','unread_client','delivered_at')

  union all

  -- 2. Tablas nuevas (deben ser 2)
  select
    '2. Tablas de chat y tickets',
    count(*)::text || ' de 2',
    case when count(*) = 2 then 'OK' else 'FALTAN' end
  from information_schema.tables
  where table_schema='public'
    and table_name in ('vg_live_chat_messages','vg_support_tickets')

  union all

  -- 3. Funciones nuevas (deben ser 5)
  select
    '3. Funciones (RPC)',
    count(*)::text || ' de 5',
    case when count(*) = 5 then 'OK' else 'FALTAN' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public'
    and p.proname in ('vg_owns_order','vg_chat_is_unlocked','vg_create_order_v17',
                      'vg_deliver_order_v17','vg_ticket_wipe_credentials')

  union all

  -- 4. Trigger que desbloquea el chat (debe ser 1)
  select
    '4. Trigger de desbloqueo del chat',
    count(*)::text || ' de 1',
    case when count(*) = 1 then 'OK' else 'FALTA' end
  from pg_trigger
  where tgname = 'vg_chat_after_insert_trg' and not tgisinternal

  union all

  -- 5. Políticas RLS (deben ser 10)
  select
    '5. Politicas de seguridad (RLS)',
    count(*)::text || ' de 10',
    case when count(*) = 10 then 'OK' else 'REVISAR' end
  from pg_policies
  where schemaname='public'
    and tablename in ('orders','vg_live_chat_messages','vg_support_tickets')

  union all

  -- 6. Realtime activo (deben ser 3)
  select
    '6. Realtime (alerta con sonido)',
    count(*)::text || ' de 3',
    case when count(*) = 3 then 'OK' else 'ACTIVAR EN Database > Replication' end
  from pg_publication_tables
  where pubname='supabase_realtime'
    and tablename in ('orders','vg_live_chat_messages','vg_support_tickets')

  union all

  -- 7. ¿Ya eres admin?
  select
    '7. Tu cuenta es admin',
    coalesce((select count(*) from public.vg_users where is_admin = true),0)::text || ' admin(s)',
    case when exists (select 1 from public.vg_users where is_admin = true)
         then 'OK' else 'MARCA TU USUARIO COMO ADMIN' end
)
select * from chequeos order by chequeo;
