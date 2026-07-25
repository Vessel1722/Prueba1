-- ═══════════════════════════════════════════════════════════════════
-- DIAGNÓSTICO — corre SOLO esto y mándame el resultado.
-- Sirve para saber de qué tipo son realmente tus columnas.
-- ═══════════════════════════════════════════════════════════════════
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and (
        (table_name = 'orders'                and column_name in ('id','user_id'))
     or (table_name = 'vg_users'              and column_name = 'id')
     or (table_name = 'vg_live_chat_messages' and column_name in ('thread_ref','order_id'))
   )
 order by table_name, column_name;
