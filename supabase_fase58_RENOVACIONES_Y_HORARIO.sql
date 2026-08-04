-- ═══════════════════════════════════════════════════════════════════
-- VESSEL GAMES · FASE 58 — Avisos de renovación y horario de atención
--
--   1. Tres días antes de que se le acabe una suscripción, al cliente
--      le llega un mensaje en el chat de su pedido, y a ti un aviso al
--      teléfono con la lista de quién está por vencer.
--
--   2. Si alguien te escribe a las tres de la mañana, se le contesta
--      solo diciéndole a qué hora vuelves. Nadie se queda sin respuesta.
--
-- Es idempotente.
-- ═══════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════
-- PARTE 1 · AVISOS DE RENOVACIÓN
-- ═════════════════════════════════════════════════════════

-- Marca de "a este ya se le avisó", para no repetirle el mensaje cada
-- vez que corra el proceso.
alter table public.orders add column if not exists aviso_renov_at timestamptz;


-- ─────────────────────────────────────────────────────────────
-- Cuántos días antes se avisa
--
--    Tres es el punto: con uno no le da tiempo de juntar el dinero, y
--    con siete se le olvida. Cámbialo aquí si quieres.
-- ─────────────────────────────────────────────────────────────
insert into public.vg_token_config (clave, valor, nota) values
  ('dias_aviso_renovacion', 3, 'Dias de anticipacion con que se avisa que una suscripcion vence')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────
-- El proceso
--
--    Busca lo que vence pronto y todavía no tiene aviso, le deja el
--    mensaje al cliente y te manda a ti un resumen.
--
--    El permiso está al revés de lo normal a propósito: si NO hay
--    sesión (auth.uid() es nulo) se deja pasar, porque así corre la
--    tarea programada de la base, que no tiene usuario. Si hay sesión,
--    tiene que ser de administrador.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_avisar_renovaciones()
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_dias    integer;
  v_ped     record;
  v_n       integer := 0;
  v_lista   text := '';
  v_msg     text;
  v_destino record;
  v_prod    text;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;

  select coalesce(valor, 3)::integer into v_dias
    from public.vg_token_config where clave = 'dias_aviso_renovacion';
  v_dias := coalesce(v_dias, 3);

  for v_ped in
    select o.id, o.vence_at, o.product_name, o.items, o.user_id,
           coalesce(nullif(trim(u.name),''), o.customer_name, 'Cliente') as cliente
      from public.orders o
      left join public.vg_users u on u.id::text = o.user_id::text
     where o.vence_at is not null
       and o.status = 'entregado'
       and coalesce(o.source,'') <> 'recommendation'
       and o.aviso_renov_at is null
       and o.vence_at > now()
       and o.vence_at <= now() + (v_dias || ' days')::interval
  loop
    v_prod := coalesce(
      nullif(trim(v_ped.product_name), ''),
      nullif(trim((v_ped.items -> 0 ->> 'title')), ''),
      'Tu suscripción'
    );

    -- El mensaje al cliente. Va dentro de su propio begin/exception
    -- para que si un pedido falla, los demás sigan recibiendo el aviso.
    begin
      insert into public.vg_live_chat_messages
        (thread_type, thread_ref, order_id, sender_role, sender_name, message)
      values
        ('order', v_ped.id::text, v_ped.id::text, 'system', 'Vessel Games',
         'Hola. Te escribimos porque ' || v_prod || ' se te vence el ' ||
         to_char(timezone('America/Tijuana', v_ped.vence_at), 'DD/MM') || '.' ||
         chr(10) || chr(10) ||
         'Si lo quieres renovar, contéstanos por aquí o entra a tu panel, a la ' ||
         'pestaña Mis suscripciones, y dale a Renovar. Te lo dejamos listo antes ' ||
         'de que se te corte.' || chr(10) || chr(10) ||
         'Si ya no lo necesitas, no hagas nada: se vence solo y no se te cobra.');

      update public.orders set aviso_renov_at = now() where id = v_ped.id;

      v_n := v_n + 1;
      v_lista := v_lista || chr(10) || '· ' || v_ped.cliente || ' — ' || v_prod ||
                 ' (' || to_char(timezone('America/Tijuana', v_ped.vence_at), 'DD/MM') || ')';
    exception when others then
      raise warning 'vg_avisar_renovaciones: pedido % (%)', v_ped.id, sqlerrm;
    end;
  end loop;

  -- El resumen para ti. Solo si hubo algo que avisar.
  if v_n > 0 then
    begin
      v_msg := '⏳ POR VENCER · ' || v_n || chr(10) ||
               'Ya se les avisó por el chat.' || chr(10) || v_lista;

      for v_destino in
        select url from public.vg_avisos
         where activo = true and coalesce(url,'') <> ''
      loop
        perform net.http_get(
          url := replace(v_destino.url, '{msg}', public.vg_urlencode(v_msg)),
          timeout_milliseconds := 4000
        );
      end loop;
    exception when others then
      raise warning 'vg_avisar_renovaciones: no se pudo avisar al admin (%)', sqlerrm;
    end;
  end if;

  return json_build_object('ok', true, 'avisados', v_n);
end;
$$;

grant execute on function public.vg_avisar_renovaciones() to authenticated;


-- ─────────────────────────────────────────────────────────────
-- Que corra solo, todos los días a las 10 de la mañana
--
--    Si tu proyecto tiene pg_cron, queda programado y te olvidas. Si no
--    lo tiene, no pasa nada: el panel de administración lo dispara una
--    vez al día cuando lo abres, y con eso basta.
-- ─────────────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.unschedule('vg_renovaciones');
    exception when others then null;
    end;
    begin
      -- 18:00 UTC = 10:00 en Tijuana (horario de verano)
      perform cron.schedule('vg_renovaciones', '0 18 * * *',
                            'select public.vg_avisar_renovaciones()');
      raise notice 'Aviso de renovaciones programado todos los dias a las 10am.';
    exception when others then
      raise notice 'No se pudo programar (%). Lo dispara el panel al abrirlo.', sqlerrm;
    end;
  else
    raise notice 'Este proyecto no tiene pg_cron. Lo dispara el panel al abrirlo.';
  end if;
end $$;


-- ═════════════════════════════════════════════════════════
-- PARTE 2 · HORARIO DE ATENCIÓN
-- ═════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- Tu horario
--
--    Una sola fila que puedes editar cuando quieras. Las horas van en
--    número de 0 a 23, en hora de Tijuana.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.vg_horario (
  id         integer primary key default 1,
  abre       integer not null default 9,
  cierra     integer not null default 22,
  zona       text    not null default 'America/Tijuana',
  mensaje    text,
  activo     boolean not null default true,
  updated_at timestamptz default now(),
  constraint vg_horario_una_fila check (id = 1)
);

insert into public.vg_horario (id, abre, cierra, mensaje) values
  (1, 9, 22,
   'Gracias por escribir. En este momento estamos fuera de horario, pero ya ' ||
   'quedó registrado tu mensaje.' || chr(10) || chr(10) ||
   'Te contestamos a partir de las {abre}:00. Si tu pedido ya está pagado, ' ||
   'no te preocupes: sigue en la fila y se entrega en cuanto abramos.')
on conflict (id) do nothing;

alter table public.vg_horario enable row level security;

drop policy if exists horario_lee_todos on public.vg_horario;
create policy horario_lee_todos on public.vg_horario
  for select to anon, authenticated using (true);

drop policy if exists horario_edita_admin on public.vg_horario;
create policy horario_edita_admin on public.vg_horario
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- ─────────────────────────────────────────────────────────────
-- La respuesta automática
--
--    Se dispara cuando escribe un CLIENTE, nunca cuando escribe el
--    sistema: por eso no se puede contestar a sí misma.
--
--    Y no repite: si en las últimas seis horas ya se mandó el aviso en
--    ese mismo chat, se queda callada. Recibir cuatro veces el mismo
--    mensaje automático molesta más que no recibir ninguno.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vg_fuera_de_horario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_h     record;
  v_hora  integer;
  v_texto text;
begin
  if coalesce(new.sender_role,'') <> 'client' then
    return new;
  end if;

  begin
    select * into v_h from public.vg_horario where id = 1;
    if not found or not v_h.activo then return new; end if;

    v_hora := extract(hour from timezone(v_h.zona, now()))::integer;

    -- Dentro del horario no se hace nada. El caso de cruzar la
    -- medianoche (abre 20, cierra 4) también queda contemplado.
    if v_h.abre < v_h.cierra then
      if v_hora >= v_h.abre and v_hora < v_h.cierra then return new; end if;
    else
      if v_hora >= v_h.abre or v_hora < v_h.cierra then return new; end if;
    end if;

    if exists (
      select 1 from public.vg_live_chat_messages
       where thread_ref = new.thread_ref
         and sender_role = 'system'
         and message like '%fuera de horario%'
         and created_at > now() - interval '6 hours'
    ) then
      return new;
    end if;

    v_texto := replace(coalesce(v_h.mensaje,''), '{abre}', v_h.abre::text);
    if trim(v_texto) = '' then return new; end if;

    insert into public.vg_live_chat_messages
      (thread_type, thread_ref, order_id, sender_role, sender_name, message)
    values
      (new.thread_type, new.thread_ref, new.order_id, 'system', 'Vessel Games', v_texto);

  exception when others then
    raise warning 'vg_fuera_de_horario: (%)', sqlerrm;
  end;

  return new;
end;
$$;

drop trigger if exists vg_chat_fuera_horario on public.vg_live_chat_messages;
create trigger vg_chat_fuera_horario
  after insert on public.vg_live_chat_messages
  for each row execute function public.vg_fuera_de_horario();


-- ─────────────────────────────────────────────────────────────
-- CÓMO CAMBIAR TU HORARIO
--
--   update public.vg_horario set abre = 8, cierra = 23 where id = 1;
--
-- Para apagarlo del todo:
--
--   update public.vg_horario set activo = false where id = 1;
-- ─────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════
-- RESULTADO — debe decir OK
-- ═════════════════════════════════════════════════════════
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='orders'
      and column_name='aviso_renov_at')::text || ' de 1 columna' as columna,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('vg_avisar_renovaciones','vg_fuera_de_horario'))::text
    || ' de 2 funciones' as funciones,
  (select count(*) from pg_trigger where tgname='vg_chat_fuera_horario')::text
    || ' de 1 disparador' as disparador,
  (select abre::text || ':00 a ' || cierra::text || ':00'
     from public.vg_horario where id=1) as horario,
  (select count(*) from public.orders
    where vence_at is not null and status='entregado'
      and aviso_renov_at is null and vence_at > now()
      and vence_at <= now() + interval '3 days')::text
    || ' por avisar ahora mismo' as pendientes,
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='orders'
                and column_name='aviso_renov_at') = 1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname in ('vg_avisar_renovaciones','vg_fuera_de_horario')) = 2
        and (select count(*) from pg_trigger where tgname='vg_chat_fuera_horario') = 1
       then 'OK' else 'REVISAR' end as resultado;
