-- ARREGLO RÁPIDO — corre esto YA para poder seguir usando el Catálogo
-- mientras me confirmas el resto de la estructura de la tabla.
-- Quita la obligatoriedad de la columna vieja "name" (y de cualquier otra
-- columna vieja común que pudiera estar causando el mismo problema).
do $$
declare col text;
begin
  foreach col in array array['name','price','desc','descripcion','nombre','precio']
  loop
    begin
      execute format('alter table public.products alter column %I drop not null', col);
    exception when undefined_column then null;
    end;
  end loop;
end $$;

notify pgrst, 'reload schema';
