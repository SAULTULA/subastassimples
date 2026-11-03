-- ════════════════════════════════════════════════════════════════════
--  SCHEMA COMPLETO DE LA SUBASTA  (proyecto nuevo de Supabase)
--  ⚠ BORRA todas las tablas, funciones y políticas de storage del schema "public"
--    del proyecto antes de crear todo de nuevo. No toca los usuarios de Authentication.
--  Uso: SQL Editor > pegar todo > cambiar el email del FINAL > Run.
-- ════════════════════════════════════════════════════════════════════

-- ═══ 1) LIMPIEZA ════════════════════════════════════════════════════
do $$
declare r record;
begin
  for r in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' loop
    execute format('drop policy %I on storage.objects', r.policyname);
  end loop;

  -- triggers viejos sobre auth.users (por ejemplo el que creaba "profiles")
  begin
    for r in select tgname from pg_trigger where tgrelid = 'auth.users'::regclass and not tgisinternal loop
      execute format('drop trigger %I on auth.users', r.tgname);
    end loop;
  exception when others then
    raise notice 'No se pudieron revisar los triggers de auth.users: %', sqlerrm;
  end;

  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('drop table if exists public.%I cascade', r.tablename);
  end loop;

  for r in
    select p.oid::regprocedure as f from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('drop function if exists %s cascade', r.f);
  end loop;
end $$;

-- ═══ 2) TABLAS ══════════════════════════════════════════════════════
create table admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create table participants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null,
  secret_hash text not null,           -- hash de la llave privada que guarda el celular del participante
  created_at timestamptz not null default now()
);

create table lots (
  id uuid primary key default gen_random_uuid(),
  position int not null default 1,
  title text not null,
  description text,
  image_url text,
  start_price numeric not null default 0,
  current_price numeric not null default 0,
  increment numeric not null default 100,
  status text not null default 'pending' check (status in ('pending', 'live', 'closed')),
  leader_id uuid,
  leader_name text,
  winner_id uuid,
  winner_name text,
  duration_minutes int,                -- null = cierre manual
  ends_at timestamptz,
  closed_at timestamptz,
  paid_at timestamptz,
  modality text not null default 'digital' check (modality in ('digital', 'presencial', 'envio')),
  location_province text,
  location_city text,
  shipping_notes text,
  created_at timestamptz not null default now()
);
create index lots_status on lots (status);   -- hasta 10 lotes en vivo a la vez (se valida en launch_lot / relaunch_lot)
create index lots_modality on lots (modality);
create index lots_province on lots (location_province);

create table bids (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references lots (id) on delete cascade,
  participant_id uuid not null references participants (id),
  name text not null,
  amount numeric not null,
  created_at timestamptz not null default now()
);
create index bids_lot_amount on bids (lot_id, amount desc);

create table app_settings (key text primary key, value text not null);
insert into app_settings (key, value) values ('admin_wa', '5491166508379');

create table payments (
  id bigserial primary key,
  lot_id uuid not null,
  mp_payment_id text unique not null,
  amount numeric not null,
  created_at timestamptz not null default now()
);

-- ═══ 3) FUNCIONES AUXILIARES ════════════════════════════════════════
create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admin_users where user_id = auth.uid())
$$;

create function secret_hash_of(p text) returns text
language sql immutable as $$ select encode(sha256(convert_to(p, 'utf8')), 'hex') $$;

create function server_now() returns timestamptz
language sql stable as $$ select now() $$;

-- ═══ 4) PERMISOS (RLS) ══════════════════════════════════════════════
alter table admin_users  enable row level security;   -- sin políticas: nadie la lee desde el navegador
alter table app_settings enable row level security;   -- idem (acá vive tu número de WhatsApp)
alter table payments     enable row level security;   -- idem
alter table participants enable row level security;
alter table lots         enable row level security;
alter table bids         enable row level security;

create policy lots_select on lots for select to anon, authenticated using (true);
create policy lots_admin_insert on lots for insert to authenticated with check (is_admin());
create policy lots_admin_update on lots for update to authenticated using (is_admin()) with check (is_admin());
create policy lots_admin_delete on lots for delete to authenticated using (is_admin());

create policy bids_select on bids for select to anon, authenticated using (true);

create policy participants_admin_select on participants for select to authenticated using (is_admin());

grant select on lots, bids to anon, authenticated;
grant insert, update, delete on lots to authenticated;
grant select on participants to authenticated;

-- ═══ 5) FUNCIONES DE LA SUBASTA ═════════════════════════════════════
-- Anotarse. El celular genera su llave privada y acá se guarda solo el hash.
create function register(p_name text, p_phone text, p_secret text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  p_name := btrim(coalesce(p_name, ''));
  p_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if p_name = '' or length(p_name) > 40 then raise exception 'Nombre inválido'; end if;
  if length(p_phone) < 8 or length(p_phone) > 15 then raise exception 'Celular inválido'; end if;
  if length(coalesce(p_secret, '')) < 20 then raise exception 'Llave inválida'; end if;
  insert into participants (name, phone, secret_hash)
    values (p_name, p_phone, secret_hash_of(p_secret)) returning id into v_id;
  return v_id;
end $$;

-- Pujar. Devuelve: ok | low:<mínimo> | closed | noreg
create function place_bid(p_lot uuid, p_participant uuid, p_secret text, p_amount numeric) returns text
language plpgsql security definer set search_path = public as $$
declare l lots%rowtype; p participants%rowtype; v_min numeric;
begin
  select * into p from participants
   where id = p_participant and secret_hash = secret_hash_of(coalesce(p_secret, ''));
  if not found then return 'noreg'; end if;

  select * into l from lots where id = p_lot for update;
  if not found or l.status <> 'live' then return 'closed'; end if;
  if l.ends_at is not null and now() >= l.ends_at then return 'closed'; end if;

  v_min := case when l.leader_id is null then l.start_price else l.current_price + l.increment end;
  if p_amount is null or p_amount < v_min then return 'low:' || v_min::text; end if;

  insert into bids (lot_id, participant_id, name, amount) values (l.id, p.id, p.name, p_amount);
  update lots set current_price = p_amount, leader_id = p.id, leader_name = p.name where id = l.id;
  return 'ok';
end $$;

-- Lanzar un lote pendiente (solo admin)
create function launch_lot(p_lot uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l lots%rowtype;
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  select * into l from lots where id = p_lot for update;
  if not found then raise exception 'Lote inexistente'; end if;
  if l.status <> 'pending' then raise exception 'Solo se puede lanzar un lote pendiente'; end if;
  if (select count(*) from lots where status = 'live') >= 10 then raise exception 'Máximo 10 subastas simultáneas'; end if;
  update lots set status = 'live', current_price = start_price,
         leader_id = null, leader_name = null, winner_id = null, winner_name = null,
         closed_at = null, paid_at = null,
         ends_at = case when coalesce(duration_minutes, 0) > 0
                        then now() + make_interval(mins => duration_minutes) end
   where id = p_lot;
end $$;

-- Relanzar un lote cerrado y sin pagar: empieza de cero
create function relaunch_lot(p_lot uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l lots%rowtype;
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  select * into l from lots where id = p_lot for update;
  if not found then raise exception 'Lote inexistente'; end if;
  if l.status <> 'closed' then raise exception 'Solo se puede relanzar un lote cerrado'; end if;
  if l.paid_at is not null then raise exception 'Este lote ya está pago'; end if;
  if (select count(*) from lots where status = 'live') >= 10 then raise exception 'Máximo 10 subastas simultáneas'; end if;
  delete from bids where lot_id = p_lot;
  update lots set status = 'live', current_price = start_price,
         leader_id = null, leader_name = null, winner_id = null, winner_name = null,
         closed_at = null, paid_at = null,
         ends_at = case when coalesce(duration_minutes, 0) > 0
                        then now() + make_interval(mins => duration_minutes) end
   where id = p_lot;
end $$;

-- Cerrar el lote en vivo y definir ganador (solo admin)
create function close_lot(p_lot uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  update lots set status = 'closed', closed_at = now(), winner_id = leader_id, winner_name = leader_name
   where id = p_lot and status = 'live';
end $$;

-- Cierre automático de lotes vencidos (lo llaman las pantallas cuando llega a 0)
create function close_expired() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update lots set status = 'closed', closed_at = now(), winner_id = leader_id, winner_name = leader_name
   where status = 'live' and ends_at is not null and ends_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- ═══ 6) PAGO Y CONTACTO ═════════════════════════════════════════════
-- WhatsApp: solo para el ganador verificado, y solo si el lote ya está pago
create function get_contact(p_lot uuid, p_participant uuid, p_secret text) returns text
language sql security definer set search_path = public as $$
  select s.value
    from app_settings s, lots l, participants p
   where s.key = 'admin_wa'
     and l.id = p_lot and l.paid_at is not null and l.winner_id = p_participant
     and p.id = p_participant and p.secret_hash = secret_hash_of(coalesce(p_secret, ''))
$$;

-- Solo para el servidor de Vercel (clave secreta): datos del cobro
create function get_payment_info(p_lot uuid, p_participant uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  select jsonb_build_object('title', l.title, 'amount', l.current_price) into r
    from lots l join participants p on p.id = l.winner_id
   where l.id = p_lot and l.status = 'closed' and l.paid_at is null
     and p.id = p_participant and p.secret_hash = secret_hash_of(coalesce(p_secret, ''));
  return r;
end $$;

-- Solo para el servidor de Vercel: marca el pago confirmado por el webhook
create function mark_lot_paid(p_lot uuid, p_payment text, p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lots%rowtype;
begin
  select * into l from lots where id = p_lot for update;
  if not found then return jsonb_build_object('result', 'no_lot'); end if;
  if l.status <> 'closed' then return jsonb_build_object('result', 'not_closed', 'title', l.title); end if;
  if l.paid_at is not null then return jsonb_build_object('result', 'already'); end if;
  if p_amount < l.current_price then
    return jsonb_build_object('result', 'amount_mismatch', 'title', l.title, 'expected', l.current_price);
  end if;
  insert into payments (lot_id, mp_payment_id, amount) values (p_lot, p_payment, p_amount)
    on conflict do nothing;
  update lots set paid_at = now() where id = p_lot;
  return jsonb_build_object('result', 'paid', 'title', l.title, 'winner', l.winner_name, 'amount', p_amount);
end $$;

revoke execute on function get_payment_info(uuid, text, text) from public, anon, authenticated;
revoke execute on function mark_lot_paid(uuid, text, numeric) from public, anon, authenticated;
grant execute on function get_payment_info(uuid, text, text) to service_role;
grant execute on function mark_lot_paid(uuid, text, numeric) to service_role;

-- ═══ 7) FOTOS DE LOS LOTES (Storage) ════════════════════════════════
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lots', 'lots', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

create policy lots_img_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'lots' and public.is_admin());
create policy lots_img_delete on storage.objects for delete to authenticated
  using (bucket_id = 'lots' and public.is_admin());

-- ═══ 8) TIEMPO REAL ═════════════════════════════════════════════════
do $$ begin alter publication supabase_realtime add table lots; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime add table bids; exception when others then null; end $$;

-- ═══ 9) ÚLTIMO PASO: ADMINISTRADOR ══════════════════════════════════
-- Cambiá el email por el tuyo. Tiene que existir en Authentication > Users.
insert into admin_users (user_id)
select id from auth.users where email = 'CAMBIAR-POR-TU-EMAIL@gmail.com'
on conflict do nothing;

select count(*) as administradores_cargados from admin_users;   -- tiene que dar 1
