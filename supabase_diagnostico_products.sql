-- Copia y pega el resultado de esto (una tabla con columnas: column_name,
-- data_type, is_nullable) para poder arreglar el catálogo de una vez bien,
-- sin ir descubriendo columna por columna a base de errores.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'products'
order by ordinal_position;
