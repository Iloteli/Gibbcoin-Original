-- GIBB Coin: neues Supabase einrichten – Teil 1 von 5
-- Im SQL Editor des NEUEN Projekts der Reihe nach ausführen (Teil 1, dann 2, …). Jeden Teil nur einmal.

-- ===================== 20260818090000_gibb_coin.sql =====================
-- GIBB Coin: sichere Wallets, Transfers und SHA-256-Hash-Kette.
-- Im Supabase SQL Editor ausführen oder mit der Supabase CLI migrieren.

create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 100),
  email text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  balance bigint not null default 200 check (balance >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  chain_index bigint generated always as identity unique,
  sender_user_id uuid references auth.users(id) on delete restrict,
  receiver_user_id uuid not null references auth.users(id) on delete restrict,
  amount bigint not null check (amount > 0),
  previous_hash text not null,
  hash text not null unique,
  created_at timestamptz not null default now(),
  constraint different_participants check (sender_user_id is null or sender_user_id <> receiver_user_id)
);

create index if not exists transactions_sender_idx on public.transactions(sender_user_id, created_at desc);
create index if not exists transactions_receiver_idx on public.transactions(receiver_user_id, created_at desc);
create index if not exists profiles_display_name_idx on public.profiles(lower(display_name));

alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.transactions enable row level security;

drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles for select to authenticated using (id = (select auth.uid()));

drop policy if exists "read own wallet" on public.wallets;
create policy "read own wallet" on public.wallets for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "read own transactions" on public.transactions;
create policy "read own transactions" on public.transactions for select to authenticated
  using (sender_user_id = (select auth.uid()) or receiver_user_id = (select auth.uid()));

-- Keine Client-Schreibrechte: alle Änderungen laufen ausschließlich über SECURITY DEFINER-Funktionen.
revoke insert, update, delete on public.profiles from anon, authenticated;
revoke insert, update, delete on public.wallets from anon, authenticated;
revoke insert, update, delete on public.transactions from anon, authenticated;
grant usage on schema public to authenticated;
grant select on public.profiles, public.wallets, public.transactions to authenticated;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, email, avatar_url)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(coalesce(new.email, 'GIBB Benutzer'), '@', 1)),
    coalesce(new.email, ''),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  ) on conflict (id) do nothing;

  -- UNIQUE(user_id) und ON CONFLICT garantieren: exakt einmal 200 GIBB.
  insert into public.wallets (user_id, balance)
  values (new.id, 200)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure private.handle_new_user();
revoke all on function private.handle_new_user() from public, anon, authenticated;

create or replace function public.search_recipients(search_term text)
returns table (id uuid, display_name text, email_hint text, avatar_url text)
language sql
stable
security definer set search_path = ''
as $$
  select p.id, p.display_name,
    case when position('@' in p.email) > 1
      then left(p.email, 1) || '***@' || split_part(p.email, '@', 2)
      else '' end,
    p.avatar_url
  from public.profiles p
  where (select auth.uid()) is not null
    and p.id <> (select auth.uid())
    and char_length(trim(search_term)) >= 2
    and p.display_name ilike '%' || replace(replace(trim(search_term), '%', '\%'), '_', '\_') || '%' escape '\'
  order by p.display_name
  limit 8;
$$;

create or replace function public.transfer_gibb(receiver_id uuid, transfer_amount bigint)
returns uuid
language plpgsql
security definer set search_path = ''
as $$
declare
  sender_id uuid := auth.uid();
  sender_balance bigint;
  previous text;
  transaction_id uuid := gen_random_uuid();
  created timestamptz := clock_timestamp();
  calculated_hash text;
begin
  if sender_id is null then raise exception 'not_authenticated'; end if;
  if receiver_id is null or receiver_id = sender_id then raise exception 'same_user'; end if;
  if transfer_amount is null or transfer_amount <= 0 then raise exception 'invalid_amount'; end if;

  -- Eine globale Transaktionssperre schützt sowohl Guthaben als auch die lineare Hash-Kette.
  perform pg_advisory_xact_lock(hashtext('gibb_coin_transfer_chain'));

  select balance into sender_balance from public.wallets where user_id = sender_id for update;
  if not found then raise exception 'sender_not_found'; end if;
  perform 1 from public.wallets where user_id = receiver_id for update;
  if not found then raise exception 'recipient_not_found'; end if;
  if sender_balance < transfer_amount then raise exception 'insufficient_funds'; end if;

  select coalesce(t.hash, repeat('0', 64)) into previous
  from public.transactions t order by t.chain_index desc limit 1;
  previous := coalesce(previous, repeat('0', 64));

  calculated_hash := encode(digest(
    sender_id::text || receiver_id::text || transfer_amount::text ||
    to_char(created at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || previous,
    'sha256'
  ), 'hex');

  update public.wallets set balance = balance - transfer_amount, updated_at = created where user_id = sender_id;
  update public.wallets set balance = balance + transfer_amount, updated_at = created where user_id = receiver_id;
  insert into public.transactions (id, sender_user_id, receiver_user_id, amount, previous_hash, hash, created_at)
    values (transaction_id, sender_id, receiver_id, transfer_amount, previous, calculated_hash, created);
  return transaction_id;
end;
$$;

create or replace function public.my_transactions()
returns table (
  id uuid, sender_user_id uuid, receiver_user_id uuid, amount bigint,
  previous_hash text, hash text, created_at timestamptz,
  sender_name text, receiver_name text
)
language sql
stable
security definer set search_path = ''
as $$
  select t.id, t.sender_user_id, t.receiver_user_id, t.amount, t.previous_hash, t.hash, t.created_at,
    coalesce(sp.display_name, 'System'), rp.display_name
  from public.transactions t
  left join public.profiles sp on sp.id = t.sender_user_id
  join public.profiles rp on rp.id = t.receiver_user_id
  where auth.uid() is not null and (t.sender_user_id = auth.uid() or t.receiver_user_id = auth.uid())
  order by t.chain_index desc
  limit 100;
$$;

create or replace function public.verify_transaction_chain()
returns boolean
language plpgsql
stable
security definer set search_path = ''
as $$
declare
  item record;
  expected_previous text := repeat('0', 64);
  expected_hash text;
begin
  if auth.uid() is null then return false; end if;
  for item in select * from public.transactions order by chain_index loop
    expected_hash := encode(digest(
      item.sender_user_id::text || item.receiver_user_id::text || item.amount::text ||
      to_char(item.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || expected_previous,
      'sha256'
    ), 'hex');
    if item.previous_hash <> expected_previous or item.hash <> expected_hash then return false; end if;
    expected_previous := item.hash;
  end loop;
  return true;
end;
$$;

revoke all on function public.search_recipients(text) from public, anon;
revoke all on function public.transfer_gibb(uuid, bigint) from public, anon;
revoke all on function public.my_transactions() from public, anon;
revoke all on function public.verify_transaction_chain() from public, anon;
grant execute on function public.search_recipients(text) to authenticated;
grant execute on function public.transfer_gibb(uuid, bigint) to authenticated;
grant execute on function public.my_transactions() to authenticated;
grant execute on function public.verify_transaction_chain() to authenticated;

-- Auch der Tabellenbesitzer soll RLS bei direkten Abfragen beachten; SECURITY DEFINER-RPCs bleiben der Schreibpfad.
alter table public.profiles force row level security;
alter table public.wallets force row level security;
alter table public.transactions force row level security;


-- ===================== selfhost-baseline (Objekte aus der alten Cloud) =====================
-- Basis für die SELBST GEHOSTETE Datenbank (nicht für die Supabase-Cloud).
--
-- Einige frühe Migrationen wurden damals nur direkt in der Cloud eingespielt und
-- liegen nicht im Repository (siehe supabase/legacy-migration-history.json).
-- Diese Datei bildet die Objekte nach, die spätere Migrationen voraussetzen.
-- deploy/install-supabase.sh spielt sie direkt nach 20260818090000_gibb_coin.sql ein.
-- Alles ist idempotent.

-- Transaktionen: Typ und Notiz (Ledger-Einträge wie GAME_REWARD, MINING_REWARD …)
alter table public.transactions add column if not exists type text not null default 'TRANSFER';
alter table public.transactions add column if not exists note text;
alter table public.transactions alter column receiver_user_id drop not null;

-- Rollen und Kontostatus
alter table public.profiles add column if not exists role text not null default 'user';
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('user', 'admin', 'super_admin'));
alter table public.wallets add column if not exists status text not null default 'active';
alter table public.wallets drop constraint if exists wallets_status_check;
alter table public.wallets add constraint wallets_status_check check (status in ('active', 'locked'));

-- Admin-Protokoll
create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null,
  target_user_id uuid,
  action text not null,
  old_value jsonb,
  new_value jsonb,
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_logs_created_idx on public.admin_audit_logs(created_at desc);
alter table public.admin_audit_logs enable row level security;
alter table public.admin_audit_logs force row level security;
revoke all on table public.admin_audit_logs from anon, authenticated;

-- Schreibt einen Eintrag ins Admin-Protokoll.
create or replace function private.write_admin_audit(
  p_admin_user_id uuid,
  p_target_user_id uuid,
  p_action text,
  p_old_value jsonb,
  p_new_value jsonb,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.admin_audit_logs (admin_user_id, target_user_id, action, old_value, new_value, reason)
  values (p_admin_user_id, p_target_user_id, p_action, p_old_value, p_new_value, p_reason)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.write_admin_audit(uuid, uuid, text, jsonb, jsonb, text) from public, anon, authenticated;

-- Hängt eine Buchung an die Hash-Kette an (gleiche Hash-Formel wie public.transfer_gibb).
-- Guthaben werden vom Aufrufer angepasst; diese Funktion schreibt nur den Ledger-Eintrag.
create or replace function private.append_transaction(
  p_sender_user_id uuid,
  p_receiver_user_id uuid,
  p_amount bigint,
  p_type text,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_created timestamptz := clock_timestamp();
  v_previous text;
  v_hash text;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  perform pg_advisory_xact_lock(hashtext('gibb_coin_transfer_chain'));
  select t.hash into v_previous from public.transactions t order by t.chain_index desc limit 1;
  v_previous := coalesce(v_previous, repeat('0', 64));
  v_hash := encode(extensions.digest(
    coalesce(p_sender_user_id::text, '') || coalesce(p_receiver_user_id::text, '') || p_amount::text ||
    to_char(v_created at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || v_previous,
    'sha256'
  ), 'hex');
  insert into public.transactions (id, sender_user_id, receiver_user_id, amount, previous_hash, hash, created_at, type, note)
  values (v_id, p_sender_user_id, p_receiver_user_id, p_amount, v_previous, v_hash, v_created, upper(p_type), p_note);
  return v_id;
end;
$$;
revoke all on function private.append_transaction(uuid, uuid, bigint, text, text) from public, anon, authenticated;

-- Anzeigenamen in Transaktionen (die App liest sie direkt aus der Tabelle).
alter table public.transactions add column if not exists sender_label text;
alter table public.transactions add column if not exists receiver_label text;

create or replace function private.fill_transaction_labels()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.sender_label is null then
    new.sender_label := case when new.sender_user_id is null then 'GIBB System'
      else coalesce((select coalesce(nullif(p.username, ''), p.display_name) from public.profiles p where p.id = new.sender_user_id), 'Gelöschtes Konto') end;
  end if;
  if new.receiver_label is null then
    new.receiver_label := case when new.receiver_user_id is null then 'GIBB System'
      else coalesce((select coalesce(nullif(p.username, ''), p.display_name) from public.profiles p where p.id = new.receiver_user_id), 'Gelöschtes Konto') end;
  end if;
  return new;
end;
$$;
drop trigger if exists transactions_fill_labels on public.transactions;
create trigger transactions_fill_labels before insert on public.transactions
  for each row execute function private.fill_transaction_labels();

-- Alte Admin-Endpunkte: spätere Migrationen entziehen/ersetzen sie nur.
create or replace function public.admin_adjust_balance(p_target_user_id uuid, p_amount bigint, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin raise exception 'deprecated_endpoint'; end; $$;
create or replace function public.admin_set_balance(p_target_user_id uuid, p_amount bigint, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin raise exception 'deprecated_endpoint'; end; $$;
revoke all on function public.admin_adjust_balance(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.admin_set_balance(uuid, bigint, text) from public, anon, authenticated;

-- Einige alte Migrationen erwarten das ursprüngliche Owner-Konto (feste ID).
-- In der eigenen Datenbank ist das ein Platzhalter OHNE Passwort (kein Login möglich);
-- deploy/selfhost-final.sql stuft ihn am Ende herunter und sperrt ihn.
insert into auth.users (id, email, raw_user_meta_data, created_at, updated_at, email_confirmed_at)
values ('d465d88f-0acb-4bff-ad55-945761acaeea', 'platzhalter-owner@gibbcoin.invalid',
        '{"display_name":"Platzhalter"}'::jsonb, now(), now(), now())
on conflict (id) do nothing;
insert into public.profiles (id, display_name, email, role)
values ('d465d88f-0acb-4bff-ad55-945761acaeea', 'Platzhalter', 'platzhalter-owner@gibbcoin.invalid', 'super_admin')
on conflict (id) do update set role = 'super_admin';
insert into public.wallets (user_id, balance) values ('d465d88f-0acb-4bff-ad55-945761acaeea', 0)
on conflict (user_id) do nothing;

-- Allgemeiner Trigger: updated_at aktualisieren.
create or replace function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;


-- ===================== 20260818103642_add_admin_pin_protection.sql =====================
create table private.admin_pins (
  admin_user_id uuid primary key references auth.users(id) on delete cascade,
  pin_hash text not null,
  failed_attempts smallint not null default 0 check (failed_attempts between 0 and 5),
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

revoke all on table private.admin_pins from public, anon, authenticated;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED',
      'ADMIN_PIN_SET',
      'ADMIN_PIN_CHANGED'
    )
  );

create or replace function private.check_admin_pin(
  p_admin_user_id uuid,
  p_pin text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pin private.admin_pins%rowtype;
  v_failed_attempts smallint;
  v_matches boolean := false;
begin
  select ap.* into v_pin
  from private.admin_pins ap
  where ap.admin_user_id = p_admin_user_id
  for update;

  if v_pin.admin_user_id is null then
    return 'not_set';
  end if;
  if v_pin.locked_until is not null and v_pin.locked_until > now() then
    return 'locked';
  end if;

  v_matches := coalesce(p_pin, '') ~ '^[0-9]{4}$'
    and extensions.crypt(coalesce(p_pin, ''), v_pin.pin_hash) = v_pin.pin_hash;

  if v_matches then
    update private.admin_pins
    set failed_attempts = 0, locked_until = null, updated_at = now()
    where admin_user_id = p_admin_user_id;
    return 'ok';
  end if;

  v_failed_attempts := least(v_pin.failed_attempts + 1, 5);
  update private.admin_pins
  set failed_attempts = v_failed_attempts,
      locked_until = case when v_failed_attempts >= 5 then now() + interval '15 minutes' else null end,
      updated_at = now()
  where admin_user_id = p_admin_user_id;

  return case when v_failed_attempts >= 5 then 'locked' else 'invalid' end;
end;
$$;

revoke all on function private.check_admin_pin(uuid, text) from public, anon, authenticated;

create or replace function public.admin_pin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin private.admin_pins%rowtype;
begin
  select ap.* into v_pin
  from private.admin_pins ap
  where ap.admin_user_id = v_admin_user_id;

  return pg_catalog.jsonb_build_object(
    'has_pin', v_pin.admin_user_id is not null,
    'locked_until', case
      when v_pin.locked_until is not null and v_pin.locked_until > now() then v_pin.locked_until
      else null
    end
  );
end;
$$;

create or replace function public.admin_set_pin(
  p_new_pin text,
  p_current_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_has_pin boolean;
  v_pin_status text;
  v_action text;
begin
  if coalesce(p_new_pin, '') !~ '^[0-9]{4}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'pin_must_have_four_digits');
  end if;

  select exists (
    select 1 from private.admin_pins ap where ap.admin_user_id = v_admin_user_id
  ) into v_has_pin;

  if v_has_pin then
    v_pin_status := private.check_admin_pin(v_admin_user_id, p_current_pin);
    if v_pin_status <> 'ok' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
    end if;

    update private.admin_pins
    set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
        failed_attempts = 0,
        locked_until = null,
        updated_at = now()
    where admin_user_id = v_admin_user_id;
    v_action := 'ADMIN_PIN_CHANGED';
  else
    insert into private.admin_pins (admin_user_id, pin_hash)
    values (v_admin_user_id, extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)));
    v_action := 'ADMIN_PIN_SET';
  end if;

  perform private.write_admin_audit(
    v_admin_user_id,
    v_admin_user_id,
    v_action,
    pg_catalog.jsonb_build_object('configured', v_has_pin),
    pg_catalog.jsonb_build_object('configured', true),
    case when v_has_pin then 'Admin-PIN geändert' else 'Admin-PIN eingerichtet' end
  );

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_transaction_id uuid;
begin
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_transaction_id := public.admin_adjust_balance(p_target_user_id, p_amount, p_reason);
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id
  );
end;
$$;

create or replace function public.admin_set_balance_secure(
  p_target_user_id uuid,
  p_new_balance bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_transaction_id uuid;
begin
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_transaction_id := public.admin_set_balance(p_target_user_id, p_new_balance, p_reason);
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id
  );
end;
$$;

-- Die alten Admin-Mutationsendpunkte bleiben intern verfügbar, sind aus dem
-- Browser aber nicht mehr aufrufbar. So gibt es keinen PIN-Bypass.
revoke all on function public.admin_adjust_balance(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.admin_set_balance(uuid, bigint, text) from public, anon, authenticated;
grant execute on function public.admin_adjust_balance(uuid, bigint, text) to service_role;
grant execute on function public.admin_set_balance(uuid, bigint, text) to service_role;

revoke all on function public.admin_pin_status() from public, anon;
grant execute on function public.admin_pin_status() to authenticated;

revoke all on function public.admin_set_pin(text, text) from public, anon;
grant execute on function public.admin_set_pin(text, text) to authenticated;

revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text) from public, anon;
grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text) to authenticated;

revoke all on function public.admin_set_balance_secure(uuid, bigint, text, text) from public, anon;
grant execute on function public.admin_set_balance_secure(uuid, bigint, text, text) to authenticated;


-- ===================== 20260818105553_add_notification_preferences.sql =====================
-- Persönliche In-App- und Browser-Benachrichtigungen.
create table if not exists public.notifications (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  title text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  notifications_enabled boolean not null default true,
  coins_received_enabled boolean not null default true,
  browser_notifications_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;

revoke all on table public.notifications from public, anon, authenticated;
grant select on table public.notifications to authenticated;
grant update (is_read) on table public.notifications to authenticated;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own
  on public.notifications for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists notifications_mark_own_read on public.notifications;
create policy notifications_mark_own_read
  on public.notifications for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on table public.notification_preferences from public, anon, authenticated;
grant select, insert on table public.notification_preferences to authenticated;
grant update (
  notifications_enabled,
  coins_received_enabled,
  browser_notifications_enabled
) on table public.notification_preferences to authenticated;

drop policy if exists notification_preferences_select_own on public.notification_preferences;
create policy notification_preferences_select_own
  on public.notification_preferences for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists notification_preferences_insert_own on public.notification_preferences;
create policy notification_preferences_insert_own
  on public.notification_preferences for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists notification_preferences_update_own on public.notification_preferences;
create policy notification_preferences_update_own
  on public.notification_preferences for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

insert into public.notification_preferences (user_id)
select id from auth.users
on conflict (user_id) do nothing;

create or replace function private.create_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function private.create_notification_preferences() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_notification_preferences on auth.users;
create trigger on_auth_user_created_notification_preferences
  after insert on auth.users
  for each row execute function private.create_notification_preferences();

create or replace function private.apply_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notifications_enabled boolean := true;
  v_coins_received_enabled boolean := true;
begin
  select p.notifications_enabled, p.coins_received_enabled
    into v_notifications_enabled, v_coins_received_enabled
  from public.notification_preferences p
  where p.user_id = new.user_id;

  if not coalesce(v_notifications_enabled, true) then
    return null;
  end if;

  if new.kind = 'transfer_received' and not coalesce(v_coins_received_enabled, true) then
    return null;
  end if;

  return new;
end;
$$;

revoke all on function private.apply_notification_preferences() from public, anon, authenticated;

drop trigger if exists apply_notification_preferences_before_insert on public.notifications;
create trigger apply_notification_preferences_before_insert
  before insert on public.notifications
  for each row execute function private.apply_notification_preferences();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'notifications'
    )
  then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;

alter table public.notifications force row level security;
alter table public.notification_preferences force row level security;


-- ===================== 20260818123000_paid_coin_purchases.sql =====================
-- Echte Einmalzahlungen über Stripe Checkout (Karte + TWINT, ausschließlich CHF).
-- Kompatibel mit der bestehenden produktiven GIBB-Coin-Hash-Kette.

alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions add constraint transactions_type_check check (
  type = any (array[
    'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
    'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN', 'COIN_PURCHASE'
  ]::text[])
);

create table if not exists public.coin_purchases (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  stripe_event_id text not null unique,
  checkout_session_id text not null unique,
  payment_intent_id text,
  coins bigint not null check (coins > 0),
  amount_paid bigint not null check (amount_paid > 0),
  currency text not null check (currency = 'chf'),
  transaction_id uuid not null unique references public.transactions(id) on delete restrict,
  status text not null default 'paid' check (status in ('paid', 'refunded', 'review')),
  created_at timestamptz not null default now()
);

create index if not exists coin_purchases_user_idx on public.coin_purchases(user_id, created_at desc);
alter table public.coin_purchases enable row level security;

drop policy if exists "coin_purchases_select_own" on public.coin_purchases;
create policy "coin_purchases_select_own" on public.coin_purchases for select to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.coin_purchases from anon, authenticated;
grant select on public.coin_purchases to authenticated;

create or replace function public.credit_gibb_purchase(
  stripe_event text,
  checkout_session text,
  payment_intent text,
  purchased_user uuid,
  purchased_coins bigint,
  paid_amount bigint,
  paid_currency text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet public.wallets%rowtype;
  v_transaction_id uuid;
  v_existing_transaction uuid;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'service_role_required';
  end if;
  if purchased_user is null or stripe_event is null or checkout_session is null then
    raise exception 'invalid_purchase';
  end if;
  if lower(paid_currency) <> 'chf' or not (
    (purchased_coins = 100 and paid_amount = 100) or
    (purchased_coins = 300 and paid_amount = 300) or
    (purchased_coins = 750 and paid_amount = 750)
  ) then
    raise exception 'invalid_pack';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(938241);

  select p.transaction_id into v_existing_transaction
  from public.coin_purchases p
  where p.stripe_event_id = stripe_event or p.checkout_session_id = checkout_session
  limit 1;
  if found then return v_existing_transaction; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = purchased_user
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;

  update public.wallets set balance = balance + purchased_coins where id = v_wallet.id;

  v_transaction_id := private.append_transaction(
    null,
    purchased_user,
    purchased_coins,
    'COIN_PURCHASE',
    'Stripe Checkout · ' || purchased_coins || ' GIBB für CHF ' ||
      pg_catalog.to_char(paid_amount::numeric / 100, 'FM999999990.00')
  );

  insert into public.coin_purchases (
    user_id, stripe_event_id, checkout_session_id, payment_intent_id,
    coins, amount_paid, currency, transaction_id
  ) values (
    purchased_user, stripe_event, checkout_session, payment_intent,
    purchased_coins, paid_amount, lower(paid_currency), v_transaction_id
  );

  insert into public.notifications (user_id, kind, title, message)
  values (purchased_user, 'coin_purchase', 'Coins gekauft', purchased_coins || ' GIBB wurden deinem Wallet gutgeschrieben.');

  return v_transaction_id;
end;
$$;

revoke all on function public.credit_gibb_purchase(text, text, text, uuid, bigint, bigint, text)
  from public, anon, authenticated;
grant execute on function public.credit_gibb_purchase(text, text, text, uuid, bigint, bigint, text)
  to service_role;


-- ===================== 20260818130000_fix_admin_account_controls.sql =====================
create extension if not exists pg_net with schema extensions;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED'
    )
  );

create or replace function public.admin_set_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text default 'Administrative Rollenänderung'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_old_role text;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Rollenänderung'
  );
begin
  v_admin_user_id := private.require_admin();
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_admin_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = p_target_user_id
  for update;

  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_old_role = p_role then return p_role; end if;

  update public.profiles set role = p_role where id = p_target_user_id;
  perform private.write_admin_audit(
    v_admin_user_id,
    p_target_user_id,
    'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role),
    pg_catalog.jsonb_build_object('role', p_role),
    v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id,
    'role_changed',
    case when p_role = 'admin' then 'Administratorrechte erhalten' else 'Administratorrechte entfernt' end,
    case when p_role = 'admin' then 'Du besitzt jetzt Administratorrechte.' else 'Deine Administratorrechte wurden entfernt.' end
  );
  return p_role;
end;
$$;

create or replace function public.admin_set_wallet_status(
  p_target_user_id uuid,
  p_status text,
  p_reason text default 'Administrative Sicherheitsmassnahme'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_admin_role text;
  v_target_role text;
  v_wallet public.wallets%rowtype;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Sicherheitsmassnahme'
  );
  v_request_headers jsonb := coalesce(
    nullif(pg_catalog.current_setting('request.headers', true), '')::jsonb,
    '{}'::jsonb
  );
  v_edge_headers jsonb;
  v_authorization text;
  v_api_key text;
  v_request_id bigint;
begin
  v_admin_user_id := private.require_admin();
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_status not in ('active', 'locked') then raise exception 'invalid_wallet_status'; end if;
  if p_target_user_id = v_admin_user_id and p_status = 'locked' then raise exception 'cannot_lock_own_account'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;
  select p.role into v_target_role from public.profiles p where p.id = p_target_user_id;
  if v_target_role is null then raise exception 'user_not_found'; end if;
  if v_target_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_admin_role = 'admin' and v_target_role = 'admin' then raise exception 'cannot_modify_peer_admin'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = p_target_user_id
  for update;

  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  v_authorization := v_request_headers ->> 'authorization';
  v_api_key := v_request_headers ->> 'apikey';
  if v_authorization is null or v_authorization = '' then
    raise exception 'authentication_header_required';
  end if;

  v_edge_headers := pg_catalog.jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', v_authorization
  );
  if v_api_key is not null and v_api_key <> '' then
    v_edge_headers := v_edge_headers || pg_catalog.jsonb_build_object('apikey', v_api_key);
  end if;

  select net.http_post(
    url := 'https://dlcsraxnofbtquhpnleu.supabase.co/functions/v1/admin-account-status',
    headers := v_edge_headers,
    body := pg_catalog.jsonb_build_object(
      'target_user_id', p_target_user_id,
      'status', p_status
    ),
    timeout_milliseconds := 10000
  ) into v_request_id;

  if v_request_id is null then raise exception 'account_status_dispatch_failed'; end if;

  if v_wallet.status <> p_status then
    update public.wallets set status = p_status where id = v_wallet.id;
    perform private.write_admin_audit(
      v_admin_user_id,
      p_target_user_id,
      case when p_status = 'locked' then 'ACCOUNT_LOCKED' else 'ACCOUNT_UNLOCKED' end,
      pg_catalog.jsonb_build_object('status', v_wallet.status),
      pg_catalog.jsonb_build_object('status', p_status),
      v_reason,
      pg_catalog.jsonb_build_object('auth_sync_request_id', v_request_id)
    );
    insert into public.notifications (user_id, kind, title, message)
    values (
      p_target_user_id,
      'account_status',
      case when p_status = 'locked' then 'Konto gesperrt' else 'Konto freigeschaltet' end,
      case when p_status = 'locked' then 'Ein Admin hat dein Konto gesperrt: ' else 'Dein Konto wurde freigeschaltet: ' end || v_reason
    );
  end if;

  return p_status;
end;
$$;

revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;

revoke all on function public.admin_set_wallet_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_wallet_status(uuid, text, text) to authenticated;


-- ===================== 20260818131500_allow_account_audit_actions.sql =====================
alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED'
    )
  );


-- ===================== 20260818133000_harden_browser_mutations.sql =====================
-- Browser clients only need reads. All balance, role and ledger writes go through
-- narrowly scoped SECURITY DEFINER functions that validate auth.uid() server-side.
revoke insert, update, delete, truncate, references, trigger
on table public.profiles, public.wallets, public.transactions
from anon, authenticated;

revoke all
on table public.admin_audit_logs
from anon, authenticated;

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then
    raise exception 'authentication_required';
  end if;

  select p.role, w.status
  into v_role, v_wallet_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;

  if v_role not in ('admin', 'super_admin') then
    raise exception 'admin_required';
  end if;
  if v_wallet_status <> 'active' then
    raise exception 'account_locked';
  end if;

  return v_user_id;
end;
$$;

revoke all on function private.require_admin() from public, anon, authenticated;


-- ===================== 20260818155404_owner_only_role_management.sql =====================
do $$
declare
  v_owner_user_id uuid := 'd465d88f-0acb-4bff-ad55-945761acaeea';
  v_old_role text;
begin
  select p.role
  into v_old_role
  from public.profiles p
  where p.id = v_owner_user_id
  for update;

  if v_old_role is null then
    raise exception 'owner_account_not_found';
  end if;

  if v_old_role <> 'super_admin' then
    update public.profiles
    set role = 'super_admin'
    where id = v_owner_user_id;

    perform private.write_admin_audit(
      v_owner_user_id,
      v_owner_user_id,
      'ROLE_CHANGED',
      pg_catalog.jsonb_build_object('role', v_old_role),
      pg_catalog.jsonb_build_object('role', 'super_admin'),
      'Owner-Konto eingerichtet'
    );

    insert into public.notifications (user_id, kind, title, message)
    values (
      v_owner_user_id,
      'role_changed',
      'Ownerrechte aktiviert',
      'Du bist jetzt Owner. Nur du kannst Adminrechte vergeben oder entfernen.'
    );
  end if;
end;
$$;

create or replace function public.admin_set_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text default 'Administrative Rollenänderung'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_user_id uuid;
  v_actor_role text;
  v_old_role text;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Rollenänderung'
  );
begin
  v_owner_user_id := private.require_admin();

  select p.role into v_actor_role
  from public.profiles p
  where p.id = v_owner_user_id;

  if v_actor_role <> 'super_admin' then raise exception 'owner_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_owner_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = p_target_user_id
  for update;

  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_old_role = p_role then return p_role; end if;

  update public.profiles set role = p_role where id = p_target_user_id;
  perform private.write_admin_audit(
    v_owner_user_id,
    p_target_user_id,
    'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role),
    pg_catalog.jsonb_build_object('role', p_role),
    v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id,
    'role_changed',
    case when p_role = 'admin' then 'Administratorrechte erhalten' else 'Administratorrechte entfernt' end,
    case when p_role = 'admin' then 'Der Owner hat dir Administratorrechte gegeben.' else 'Der Owner hat deine Administratorrechte entfernt.' end
  );
  return p_role;
end;
$$;

revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;


-- ===================== 20260818163406_capture_payment_requests_and_contacts.sql =====================
-- Keep the contacts and payment-request feature reproducible. These objects
-- already exist in production; IF NOT EXISTS and CREATE OR REPLACE make this
-- migration safe there while fully defining them for a fresh database.

create table if not exists public.contacts (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  contact_user_id uuid not null references auth.users(id) on delete cascade,
  nickname text check (
    nickname is null or pg_catalog.char_length(nickname) between 2 and 40
  ),
  is_favorite boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_user_id, contact_user_id),
  check (owner_user_id <> contact_user_id)
);

create index if not exists contacts_owner_favorite_idx
  on public.contacts (owner_user_id, is_favorite desc, created_at desc);
create index if not exists contacts_contact_user_idx
  on public.contacts (contact_user_id);

create table if not exists public.payment_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_user_id uuid not null references auth.users(id) on delete cascade,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  requester_label text not null,
  target_label text not null,
  amount bigint not null check (amount > 0 and amount <= 1000),
  note text check (note is null or pg_catalog.char_length(note) <= 160),
  status text not null default 'pending' check (status in ('pending', 'paid', 'declined')),
  transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester_user_id <> target_user_id)
);

create index if not exists payment_requests_requester_idx
  on public.payment_requests (requester_user_id, created_at desc);
create index if not exists payment_requests_target_status_idx
  on public.payment_requests (target_user_id, status, created_at desc);
create index if not exists payment_requests_transaction_idx
  on public.payment_requests (transaction_id);

alter table public.contacts enable row level security;
alter table public.payment_requests enable row level security;

drop policy if exists contacts_select_own on public.contacts;
create policy contacts_select_own on public.contacts
for select to authenticated
using ((select auth.uid()) = owner_user_id);

drop policy if exists payment_requests_select_party on public.payment_requests;
create policy payment_requests_select_party on public.payment_requests
for select to authenticated
using (
  (select auth.uid()) = requester_user_id
  or (select auth.uid()) = target_user_id
);

drop trigger if exists contacts_set_updated_at on public.contacts;
create trigger contacts_set_updated_at
before update on public.contacts
for each row execute function private.set_updated_at();

drop trigger if exists payment_requests_set_updated_at on public.payment_requests;
create trigger payment_requests_set_updated_at
before update on public.payment_requests
for each row execute function private.set_updated_at();

create or replace function public.list_contacts()
returns table (
  contact_id uuid,
  user_id uuid,
  username text,
  display_name text,
  wallet_code text,
  nickname text,
  is_favorite boolean,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;

  return query
  select
    c.id,
    p.id,
    p.username,
    p.display_name,
    pg_catalog.right(pg_catalog.replace(w.id::text, '-', ''), 6),
    c.nickname,
    c.is_favorite,
    c.created_at
  from public.contacts c
  join public.profiles p on p.id = c.contact_user_id
  join public.wallets w on w.user_id = p.id
  where c.owner_user_id = v_user_id
  order by c.is_favorite desc, coalesce(c.nickname, p.display_name), c.created_at desc;
end;
$$;

create or replace function public.save_contact(
  p_contact_user_id uuid,
  p_nickname text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_nickname text := nullif(pg_catalog.btrim(coalesce(p_nickname, '')), '');
  v_id uuid;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if p_contact_user_id is null or p_contact_user_id = v_user_id then
    raise exception 'invalid_contact';
  end if;
  if v_nickname is not null and pg_catalog.char_length(v_nickname) not between 2 and 40 then
    raise exception 'invalid_nickname';
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_contact_user_id) then
    raise exception 'contact_not_found';
  end if;

  insert into public.contacts (owner_user_id, contact_user_id, nickname)
  values (v_user_id, p_contact_user_id, v_nickname)
  on conflict (owner_user_id, contact_user_id)
  do update set nickname = excluded.nickname
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.remove_contact(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;

  delete from public.contacts
  where id = p_contact_id and owner_user_id = auth.uid();

  if not found then raise exception 'contact_not_found'; end if;
end;
$$;

create or replace function public.set_contact_favorite(
  p_contact_id uuid,
  p_is_favorite boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;

  update public.contacts
  set is_favorite = coalesce(p_is_favorite, false)
  where id = p_contact_id and owner_user_id = auth.uid();

  if not found then raise exception 'contact_not_found'; end if;
end;
$$;

create or replace function public.create_payment_request(
  p_target_user_id uuid,
  p_amount bigint,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_id uuid;
  v_requester_name text;
  v_target_name text;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if p_target_user_id is null or p_target_user_id = v_user_id then raise exception 'invalid_target'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000 then raise exception 'invalid_amount'; end if;
  if pg_catalog.char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;
  if not exists (
    select 1 from public.wallets where user_id = p_target_user_id and status = 'active'
  ) then
    raise exception 'target_not_found';
  end if;

  select display_name into v_requester_name from public.profiles where id = v_user_id;
  select display_name into v_target_name from public.profiles where id = p_target_user_id;

  insert into public.payment_requests (
    requester_user_id,
    target_user_id,
    requester_label,
    target_label,
    amount,
    note
  ) values (
    v_user_id,
    p_target_user_id,
    v_requester_name,
    v_target_name,
    p_amount,
    nullif(pg_catalog.btrim(coalesce(p_note, '')), '')
  )
  returning id into v_id;

  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id,
    'payment_request',
    'Zahlungsanfrage',
    v_requester_name || ' fordert ' || p_amount || ' GIBB von dir an.'
  );

  return v_id;
end;
$$;

create or replace function public.respond_payment_request(
  p_request_id uuid,
  p_accept boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.payment_requests%rowtype;
  v_transaction_id uuid;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;

  select r.* into v_request
  from public.payment_requests r
  where r.id = p_request_id
  for update;

  if v_request.id is null or v_request.target_user_id <> v_user_id then
    raise exception 'request_not_found';
  end if;
  if v_request.status <> 'pending' then raise exception 'request_already_processed'; end if;

  if coalesce(p_accept, false) then
    v_transaction_id := public.transfer_coins(
      v_request.requester_user_id,
      v_request.amount,
      v_request.note
    );
    update public.payment_requests
    set status = 'paid', transaction_id = v_transaction_id
    where id = p_request_id;
  else
    update public.payment_requests
    set status = 'declined'
    where id = p_request_id;

    insert into public.notifications (user_id, kind, title, message)
    values (
      v_request.requester_user_id,
      'request_declined',
      'Anfrage abgelehnt',
      v_request.target_label || ' hat deine Zahlungsanfrage abgelehnt.'
    );
  end if;

  return v_transaction_id;
end;
$$;

revoke all on table public.contacts, public.payment_requests from anon, authenticated;
grant select on table public.contacts, public.payment_requests to authenticated;

revoke all on function public.list_contacts() from public, anon, authenticated;
revoke all on function public.save_contact(uuid, text) from public, anon, authenticated;
revoke all on function public.remove_contact(uuid) from public, anon, authenticated;
revoke all on function public.set_contact_favorite(uuid, boolean) from public, anon, authenticated;
revoke all on function public.create_payment_request(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.respond_payment_request(uuid, boolean) from public, anon, authenticated;

grant execute on function public.list_contacts() to authenticated;
grant execute on function public.save_contact(uuid, text) to authenticated;
grant execute on function public.remove_contact(uuid) to authenticated;
grant execute on function public.set_contact_favorite(uuid, boolean) to authenticated;
grant execute on function public.create_payment_request(uuid, bigint, text) to authenticated;
grant execute on function public.respond_payment_request(uuid, boolean) to authenticated;


-- ===================== 20260818163810_add_owner_pin_recovery.sql =====================
create or replace function public.admin_pin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin private.admin_pins%rowtype;
begin
  select ap.* into v_pin
  from private.admin_pins ap
  where ap.admin_user_id = v_admin_user_id;

  return pg_catalog.jsonb_build_object(
    'has_pin', v_pin.admin_user_id is not null,
    'failed_attempts', coalesce(v_pin.failed_attempts, 0),
    'locked_until', case
      when v_pin.locked_until is not null and v_pin.locked_until > now() then v_pin.locked_until
      else null
    end
  );
end;
$$;

create or replace function public.owner_reset_admin_pin(
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_user_id uuid := private.require_admin();
  v_role text;
  v_had_pin boolean;
begin
  select p.role into v_role
  from public.profiles p
  where p.id = v_owner_user_id;

  if v_role is distinct from 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;

  if coalesce(p_new_pin, '') !~ '^[0-9]{4}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'pin_must_have_four_digits');
  end if;

  select exists (
    select 1
    from private.admin_pins ap
    where ap.admin_user_id = v_owner_user_id
  ) into v_had_pin;

  insert into private.admin_pins (
    admin_user_id,
    pin_hash,
    failed_attempts,
    locked_until,
    updated_at
  ) values (
    v_owner_user_id,
    extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
    0,
    null,
    now()
  )
  on conflict (admin_user_id) do update
  set pin_hash = excluded.pin_hash,
      failed_attempts = 0,
      locked_until = null,
      updated_at = now();

  perform private.write_admin_audit(
    v_owner_user_id,
    v_owner_user_id,
    case when v_had_pin then 'ADMIN_PIN_CHANGED' else 'ADMIN_PIN_SET' end,
    pg_catalog.jsonb_build_object('configured', v_had_pin),
    pg_catalog.jsonb_build_object('configured', true),
    'Owner-PIN sicher zurückgesetzt'
  );

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.admin_pin_status() from public, anon, authenticated;
grant execute on function public.admin_pin_status() to authenticated;

revoke all on function public.owner_reset_admin_pin(text) from public, anon, authenticated;
grant execute on function public.owner_reset_admin_pin(text) to authenticated;


-- ===================== 20260818164842_enable_live_account_bans.sql =====================
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'wallets'
  ) then
    alter publication supabase_realtime add table public.wallets;
  end if;
end;
$$;


-- ===================== 20260818165741_owner_coin_removal_and_sync_bans.sql =====================
-- Owner-only coin removal and synchronous account-ban persistence.

create or replace function public.admin_set_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text default 'Administrative Rollenänderung'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_admin_role text;
  v_old_role text;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Rollenänderung'
  );
begin
  v_admin_user_id := private.require_admin();
  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;
  if v_admin_role <> 'super_admin' then raise exception 'owner_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_admin_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = p_target_user_id
  for update;

  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_old_role = p_role then return p_role; end if;

  update public.profiles set role = p_role where id = p_target_user_id;
  perform private.write_admin_audit(
    v_admin_user_id,
    p_target_user_id,
    'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role),
    pg_catalog.jsonb_build_object('role', p_role),
    v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id,
    'role_changed',
    case when p_role = 'admin' then 'Administratorrechte erhalten' else 'Administratorrechte entfernt' end,
    case when p_role = 'admin' then 'Du besitzt jetzt Administratorrechte.' else 'Deine Administratorrechte wurden entfernt.' end
  );
  return p_role;
end;
$$;

create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_admin_role text;
  v_pin_status text;
  v_transaction_id uuid;
begin
  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;

  if p_amount is null or p_amount = 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_admin_amount');
  end if;
  if p_amount < 0 and v_admin_role <> 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if p_amount < 0 and p_target_user_id = v_admin_user_id then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_own_coins');
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  begin
    v_transaction_id := public.admin_adjust_balance(p_target_user_id, p_amount, p_reason);
  exception
    when others then
      if sqlerrm in ('invalid_admin_amount', 'invalid_admin_reason', 'wallet_not_found', 'insufficient_balance') then
        return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
      end if;
      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id,
    'operation', case when p_amount > 0 then 'credit' else 'remove' end
  );
end;
$$;

-- Called only by the verified Edge Function after Supabase Auth has confirmed
-- the ban/unban. Keeping the write here preserves row locking and audit logs.
create or replace function public.admin_apply_wallet_status(
  p_admin_user_id uuid,
  p_target_user_id uuid,
  p_status text,
  p_reason text default 'Administrative Sicherheitsmassnahme'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_role text;
  v_admin_wallet_status text;
  v_target_role text;
  v_wallet public.wallets%rowtype;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Sicherheitsmassnahme'
  );
begin
  if p_admin_user_id is null then raise exception 'admin_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_status not in ('active', 'locked') then raise exception 'invalid_wallet_status'; end if;
  if p_target_user_id = p_admin_user_id and p_status = 'locked' then raise exception 'cannot_lock_own_account'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role, w.status into v_admin_role, v_admin_wallet_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = p_admin_user_id;

  if coalesce(v_admin_role, '') not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  if coalesce(v_admin_wallet_status, '') <> 'active' then raise exception 'account_locked'; end if;

  select p.role into v_target_role from public.profiles p where p.id = p_target_user_id;
  if v_target_role is null then raise exception 'user_not_found'; end if;
  if v_target_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_admin_role = 'admin' and v_target_role = 'admin' then raise exception 'cannot_modify_peer_admin'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = p_target_user_id
  for update;

  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  if v_wallet.status <> p_status then
    update public.wallets set status = p_status where id = v_wallet.id;
    perform private.write_admin_audit(
      p_admin_user_id,
      p_target_user_id,
      case when p_status = 'locked' then 'ACCOUNT_LOCKED' else 'ACCOUNT_UNLOCKED' end,
      pg_catalog.jsonb_build_object('status', v_wallet.status),
      pg_catalog.jsonb_build_object('status', p_status),
      v_reason,
      pg_catalog.jsonb_build_object('auth_synced', true)
    );
    insert into public.notifications (user_id, kind, title, message)
    values (
      p_target_user_id,
      'account_status',
      case when p_status = 'locked' then 'Konto gesperrt' else 'Konto freigeschaltet' end,
      case when p_status = 'locked' then 'Ein Admin hat dein Konto gesperrt: ' else 'Dein Konto wurde freigeschaltet: ' end || v_reason
    );
  end if;

  return p_status;
end;
$$;

revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;

revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text) from public, anon, authenticated;
grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text) to authenticated;

-- The previous browser RPC used an asynchronous HTTP dispatch. Disable it so
-- neither the UI nor DevTools can report a ban before Auth confirms it.
revoke all on function public.admin_set_wallet_status(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_set_wallet_status(uuid, text, text) to service_role;

revoke all on function public.admin_apply_wallet_status(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_apply_wallet_status(uuid, uuid, text, text) to service_role;


-- ===================== 20260818170400_close_legacy_admin_balance_bypass.sql =====================
-- The current UI uses the PIN-protected adjustment endpoint. The older
-- absolute-balance RPC is no longer needed in browsers and could otherwise
-- bypass the Owner-only rule for coin removal.
revoke all on function public.admin_set_balance_secure(uuid, bigint, text, text)
from public, anon, authenticated;

grant execute on function public.admin_set_balance_secure(uuid, bigint, text, text)
to service_role;


-- ===================== 20260818173520_allow_admin_coin_removal_except_owner.sql =====================
-- Admins may remove coins from other accounts with their personal PIN.
-- Owner accounts and the acting admin's own account remain protected.
create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_target_role text;
  v_pin_status text;
  v_transaction_id uuid;
begin
  if p_amount is null or p_amount = 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_admin_amount');
  end if;

  if p_amount < 0 then
    if p_target_user_id = v_admin_user_id then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_own_coins');
    end if;

    select p.role into v_target_role
    from public.profiles p
    where p.id = p_target_user_id;

    if v_target_role is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found');
    end if;
    if v_target_role = 'super_admin' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_owner_coins');
    end if;
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  begin
    v_transaction_id := public.admin_adjust_balance(p_target_user_id, p_amount, p_reason);
  exception
    when others then
      if sqlerrm in ('invalid_admin_amount', 'invalid_admin_reason', 'wallet_not_found', 'insufficient_balance') then
        return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
      end if;
      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id,
    'operation', case when p_amount > 0 then 'credit' else 'remove' end
  );
end;
$$;

revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text)
from public, anon, authenticated;

grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text)
to authenticated;


-- ===================== 20260818180000_owner_account_deletion.sql =====================
-- Owner-only account deletion while preserving the immutable ledger and audit trail.

create table if not exists private.ledger_identities (
  id uuid primary key,
  created_at timestamptz not null default now()
);

revoke all on table private.ledger_identities from public, anon, authenticated;

insert into private.ledger_identities (id)
select id from auth.users
union
select sender_user_id from public.transactions where sender_user_id is not null
union
select receiver_user_id from public.transactions where receiver_user_id is not null
union
select admin_user_id from public.admin_audit_logs
union
select target_user_id from public.admin_audit_logs where target_user_id is not null
union
select user_id from public.coin_purchases
on conflict (id) do nothing;

create or replace function private.capture_ledger_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.ledger_identities (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function private.capture_ledger_identity() from public, anon, authenticated;

drop trigger if exists on_auth_user_ledger_identity on auth.users;
create trigger on_auth_user_ledger_identity
  after insert on auth.users
  for each row execute procedure private.capture_ledger_identity();

-- Ledger and accounting rows keep their pseudonymous ID after Auth deletion.
-- Human-readable transaction labels are anonymised by the finalisation RPC below.
alter table public.transactions
  drop constraint if exists transactions_sender_user_id_fkey,
  drop constraint if exists transactions_receiver_user_id_fkey;

alter table public.transactions
  add constraint transactions_sender_user_id_fkey
    foreign key (sender_user_id) references private.ledger_identities(id) on delete restrict,
  add constraint transactions_receiver_user_id_fkey
    foreign key (receiver_user_id) references private.ledger_identities(id) on delete restrict;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_admin_user_id_fkey,
  drop constraint if exists admin_audit_logs_target_user_id_fkey;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_admin_user_id_fkey
    foreign key (admin_user_id) references private.ledger_identities(id) on delete restrict,
  add constraint admin_audit_logs_target_user_id_fkey
    foreign key (target_user_id) references private.ledger_identities(id) on delete restrict;

alter table public.coin_purchases
  drop constraint if exists coin_purchases_user_id_fkey;

alter table public.coin_purchases
  add constraint coin_purchases_user_id_fkey
    foreign key (user_id) references private.ledger_identities(id) on delete restrict;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED',
      'ACCOUNT_DELETED',
      'ADMIN_PIN_SET',
      'ADMIN_PIN_CHANGED'
    )
  );

create or replace function public.owner_authorize_account_deletion(
  p_owner_user_id uuid,
  p_target_user_id uuid,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_role text;
  v_owner_status text;
  v_target_role text;
  v_target_name text;
  v_pin_status text;
begin
  if p_owner_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'authentication_required');
  end if;
  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_required');
  end if;
  if p_owner_user_id = p_target_user_id then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_delete_own_account');
  end if;

  select p.role, w.status
  into v_owner_role, v_owner_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = p_owner_user_id;

  if coalesce(v_owner_role, '') <> 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if coalesce(v_owner_status, '') <> 'active' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_locked');
  end if;

  select p.role, p.display_name
  into v_target_role, v_target_name
  from public.profiles p
  where p.id = p_target_user_id;

  if v_target_role is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if v_target_role = 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_delete_owner');
  end if;

  v_pin_status := private.check_admin_pin(p_owner_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  insert into private.ledger_identities (id)
  values (p_target_user_id)
  on conflict (id) do nothing;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'target_user_id', p_target_user_id,
    'display_name', v_target_name,
    'role', v_target_role
  );
end;
$$;

create or replace function public.owner_finalize_account_deletion(
  p_owner_user_id uuid,
  p_target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_role text;
  v_owner_status text;
begin
  select p.role, w.status
  into v_owner_role, v_owner_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = p_owner_user_id;

  if coalesce(v_owner_role, '') <> 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if coalesce(v_owner_status, '') <> 'active' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_locked');
  end if;
  if exists (select 1 from auth.users u where u.id = p_target_user_id) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'auth_account_still_exists');
  end if;
  if not exists (select 1 from private.ledger_identities l where l.id = p_target_user_id) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;

  update public.transactions
  set sender_label = 'Gelöschtes Konto'
  where sender_user_id = p_target_user_id
    and sender_label <> 'Gelöschtes Konto';

  update public.transactions
  set receiver_label = 'Gelöschtes Konto'
  where receiver_user_id = p_target_user_id
    and receiver_label <> 'Gelöschtes Konto';

  if not exists (
    select 1
    from public.admin_audit_logs a
    where a.target_user_id = p_target_user_id
      and a.action = 'ACCOUNT_DELETED'
  ) then
    perform private.write_admin_audit(
      p_owner_user_id,
      p_target_user_id,
      'ACCOUNT_DELETED',
      pg_catalog.jsonb_build_object('account_exists', true),
      pg_catalog.jsonb_build_object('account_exists', false),
      'Konto durch Owner dauerhaft gelöscht',
      pg_catalog.jsonb_build_object('auth_deleted', true, 'ledger_anonymized', true)
    );
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.owner_authorize_account_deletion(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function public.owner_authorize_account_deletion(uuid, uuid, text)
to service_role;

revoke all on function public.owner_finalize_account_deletion(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.owner_finalize_account_deletion(uuid, uuid)
to service_role;


-- ===================== 20260818183000_admin_password_reset.sql =====================
-- Secure password-recovery delegation: admins can email normal users;
-- the owner can additionally email admins. Passwords are never exposed.

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED',
      'ACCOUNT_DELETED',
      'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET',
      'ADMIN_PIN_CHANGED'
    )
  );

create or replace function public.admin_authorize_password_reset(
  p_admin_user_id uuid,
  p_target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_role text;
  v_admin_status text;
  v_target_role text;
  v_target_name text;
  v_target_email text;
begin
  if p_admin_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'authentication_required');
  end if;
  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_required');
  end if;
  if p_admin_user_id = p_target_user_id then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_reset_own_password');
  end if;

  select p.role, w.status
  into v_admin_role, v_admin_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = p_admin_user_id;

  if coalesce(v_admin_role, '') not in ('admin', 'super_admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_required');
  end if;
  if coalesce(v_admin_status, '') <> 'active' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_locked');
  end if;

  select p.role, p.display_name, u.email
  into v_target_role, v_target_name, v_target_email
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.wallets w on w.user_id = p.id
  where p.id = p_target_user_id;

  if v_target_role is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if v_target_role = 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_reset_owner');
  end if;
  if v_admin_role = 'admin' and v_target_role = 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_reset_peer_admin');
  end if;
  if nullif(pg_catalog.btrim(v_target_email), '') is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'email_missing');
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'email', v_target_email,
    'display_name', v_target_name,
    'role', v_target_role
  );
end;
$$;

create or replace function public.admin_record_password_reset(
  p_admin_user_id uuid,
  p_target_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorization jsonb;
begin
  v_authorization := public.admin_authorize_password_reset(p_admin_user_id, p_target_user_id);
  if not coalesce((v_authorization ->> 'ok')::boolean, false) then
    raise exception '%', coalesce(v_authorization ->> 'error', 'password_reset_not_authorized');
  end if;

  perform private.write_admin_audit(
    p_admin_user_id,
    p_target_user_id,
    'PASSWORD_RESET_SENT',
    pg_catalog.jsonb_build_object('password_reset_email', false),
    pg_catalog.jsonb_build_object('password_reset_email', true),
    'Passwort-Reset-Link per E-Mail gesendet',
    pg_catalog.jsonb_build_object('delivery', 'email', 'password_visible_to_admin', false)
  );
end;
$$;

revoke all on function public.admin_authorize_password_reset(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.admin_authorize_password_reset(uuid, uuid)
to service_role;

revoke all on function public.admin_record_password_reset(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.admin_record_password_reset(uuid, uuid)
to service_role;


-- ===================== 20260818190000_enforce_opt_in_admin_mfa.sql =====================
-- Users who opt in to TOTP MFA must hold an aal2 session before privileged
-- browser-callable admin mutations can run. Existing admins are not locked out
-- before they deliberately enroll a factor.

create or replace function private.assert_mfa_if_enrolled(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'authentication_required';
  end if;

  if exists (
    select 1
    from auth.mfa_factors f
    where f.user_id = p_user_id
      and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
end;
$$;

revoke all on function private.assert_mfa_if_enrolled(uuid)
from public, anon, authenticated;

create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_target_role text;
  v_pin_status text;
  v_transaction_id uuid;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  if p_amount is null or p_amount = 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_admin_amount');
  end if;

  if p_amount < 0 then
    if p_target_user_id = v_admin_user_id then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_own_coins');
    end if;

    select p.role into v_target_role
    from public.profiles p
    where p.id = p_target_user_id;

    if v_target_role is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found');
    end if;
    if v_target_role = 'super_admin' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_owner_coins');
    end if;
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  begin
    v_transaction_id := public.admin_adjust_balance(p_target_user_id, p_amount, p_reason);
  exception
    when others then
      if sqlerrm in ('invalid_admin_amount', 'invalid_admin_reason', 'wallet_not_found', 'insufficient_balance') then
        return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
      end if;
      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id,
    'operation', case when p_amount > 0 then 'credit' else 'remove' end
  );
end;
$$;

create or replace function public.admin_set_pin(
  p_new_pin text,
  p_current_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_has_pin boolean;
  v_pin_status text;
  v_action text;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  if coalesce(p_new_pin, '') !~ '^[0-9]{4}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'pin_must_have_four_digits');
  end if;

  select exists (
    select 1 from private.admin_pins ap where ap.admin_user_id = v_admin_user_id
  ) into v_has_pin;

  if v_has_pin then
    v_pin_status := private.check_admin_pin(v_admin_user_id, p_current_pin);
    if v_pin_status <> 'ok' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
    end if;

    update private.admin_pins
    set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
        failed_attempts = 0,
        locked_until = null,
        updated_at = now()
    where admin_user_id = v_admin_user_id;
    v_action := 'ADMIN_PIN_CHANGED';
  else
    insert into private.admin_pins (admin_user_id, pin_hash)
    values (v_admin_user_id, extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)));
    v_action := 'ADMIN_PIN_SET';
  end if;

  perform private.write_admin_audit(
    v_admin_user_id,
    v_admin_user_id,
    v_action,
    pg_catalog.jsonb_build_object('configured', v_has_pin),
    pg_catalog.jsonb_build_object('configured', true),
    case when v_has_pin then 'Admin-PIN geändert' else 'Admin-PIN eingerichtet' end
  );

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_set_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text default 'Administrative Rollenänderung'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_admin_role text;
  v_old_role text;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Rollenänderung'
  );
begin
  v_admin_user_id := private.require_admin();
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;
  if v_admin_role <> 'super_admin' then raise exception 'owner_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_admin_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = p_target_user_id
  for update;

  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_old_role = p_role then return p_role; end if;

  update public.profiles set role = p_role where id = p_target_user_id;
  perform private.write_admin_audit(
    v_admin_user_id,
    p_target_user_id,
    'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role),
    pg_catalog.jsonb_build_object('role', p_role),
    v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id,
    'role_changed',
    case when p_role = 'admin' then 'Administratorrechte erhalten' else 'Administratorrechte entfernt' end,
    case when p_role = 'admin' then 'Du besitzt jetzt Administratorrechte.' else 'Deine Administratorrechte wurden entfernt.' end
  );
  return p_role;
end;
$$;

create or replace function public.owner_reset_admin_pin(p_new_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_user_id uuid := private.require_admin();
  v_role text;
  v_had_pin boolean;
begin
  perform private.assert_mfa_if_enrolled(v_owner_user_id);

  select p.role into v_role
  from public.profiles p
  where p.id = v_owner_user_id;

  if v_role is distinct from 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;

  if coalesce(p_new_pin, '') !~ '^[0-9]{4}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'pin_must_have_four_digits');
  end if;

  select exists (
    select 1
    from private.admin_pins ap
    where ap.admin_user_id = v_owner_user_id
  ) into v_had_pin;

  insert into private.admin_pins (
    admin_user_id,
    pin_hash,
    failed_attempts,
    locked_until,
    updated_at
  ) values (
    v_owner_user_id,
    extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
    0,
    null,
    now()
  )
  on conflict (admin_user_id) do update
  set pin_hash = excluded.pin_hash,
      failed_attempts = 0,
      locked_until = null,
      updated_at = now();

  perform private.write_admin_audit(
    v_owner_user_id,
    v_owner_user_id,
    case when v_had_pin then 'ADMIN_PIN_CHANGED' else 'ADMIN_PIN_SET' end,
    pg_catalog.jsonb_build_object('configured', v_had_pin),
    pg_catalog.jsonb_build_object('configured', true),
    'Owner-PIN sicher zurückgesetzt'
  );

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;


-- ===================== 20260818193000_fix_new_account_registration.sql =====================
-- The immutable transaction ledger references private.ledger_identities.
-- Capture the identity before any AFTER INSERT signup trigger can create the
-- initial-balance transaction. Using a BEFORE trigger avoids depending on the
-- alphabetical order of multiple auth.users triggers.

drop trigger if exists on_auth_user_ledger_identity on auth.users;

create trigger on_auth_user_ledger_identity
  before insert on auth.users
  for each row execute procedure private.capture_ledger_identity();


-- ===================== 20260818200000_protect_owner_account_from_deletion.sql =====================
-- Absolute last line of defence for the Owner account. This trigger runs for
-- every Auth deletion, including service-role and Dashboard initiated deletes.

create or replace function private.protect_owner_auth_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.profiles p
    where p.id = old.id
      and p.role = 'super_admin'
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner_account_is_protected';
  end if;

  return old;
end;
$$;

revoke all on function private.protect_owner_auth_deletion()
from public, anon, authenticated;

drop trigger if exists protect_owner_auth_deletion on auth.users;
create trigger protect_owner_auth_deletion
  before delete on auth.users
  for each row execute procedure private.protect_owner_auth_deletion();


-- ===================== 20260818203000_raise_coin_transfer_limit.sql =====================
-- Raise the per-transfer ceiling while retaining all server-side balance,
-- account-status, note-length and recipient checks.

create or replace function public.transfer_coins(
  p_receiver_user_id uuid,
  p_amount bigint,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sender_id uuid := auth.uid();
  v_sender public.wallets%rowtype;
  v_receiver public.wallets%rowtype;
  v_transaction_id uuid;
  v_sender_name text;
  v_receiver_name text;
begin
  if v_sender_id is null then raise exception 'authentication_required'; end if;
  if p_receiver_user_id is null then raise exception 'recipient_required'; end if;
  if p_receiver_user_id = v_sender_id then raise exception 'self_transfer_not_allowed'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if pg_catalog.char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;

  perform w.id
  from public.wallets w
  where w.user_id = any(array[v_sender_id, p_receiver_user_id])
  order by w.id
  for update;

  select w.* into v_sender from public.wallets w where w.user_id = v_sender_id;
  select w.* into v_receiver from public.wallets w where w.user_id = p_receiver_user_id;

  if v_sender.id is null or v_receiver.id is null then raise exception 'wallet_not_found'; end if;
  if v_sender.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_receiver.status <> 'active' then raise exception 'recipient_wallet_locked'; end if;
  if v_sender.balance < p_amount then raise exception 'insufficient_balance'; end if;

  update public.wallets set balance = balance - p_amount where id = v_sender.id;
  update public.wallets set balance = balance + p_amount where id = v_receiver.id;
  v_transaction_id := private.append_transaction(
    v_sender_id,
    p_receiver_user_id,
    p_amount,
    'TRANSFER',
    p_note
  );

  select display_name into v_sender_name from public.profiles where id = v_sender_id;
  select display_name into v_receiver_name from public.profiles where id = p_receiver_user_id;

  insert into public.notifications (user_id, kind, title, message) values
    (
      p_receiver_user_id,
      'transfer_received',
      'GIBB erhalten',
      v_sender_name || ' hat dir ' || p_amount || ' GIBB gesendet.'
    ),
    (
      v_sender_id,
      'transfer_sent',
      'Zahlung erfolgreich',
      p_amount || ' GIBB wurden an ' || v_receiver_name || ' gesendet.'
    );

  return v_transaction_id;
end;
$$;

revoke all on function public.transfer_coins(uuid, bigint, text)
from public, anon, authenticated;
grant execute on function public.transfer_coins(uuid, bigint, text)
to authenticated;


-- ===================== 20260822124000_allow_admin_account_deletion.sql =====================
-- Admins may delete normal users. Only the Owner may delete Admin accounts,
-- and the Owner account itself remains undeletable on every path.

create table if not exists private.account_deletion_authorizations (
  target_user_id uuid primary key,
  actor_user_id uuid not null,
  actor_role text not null check (actor_role in ('admin', 'super_admin')),
  target_role text not null check (target_role in ('user', 'admin')),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

revoke all on table private.account_deletion_authorizations
from public, anon, authenticated;

create or replace function public.admin_authorize_account_deletion(
  p_admin_user_id uuid,
  p_target_user_id uuid,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_role text;
  v_admin_status text;
  v_target_role text;
  v_target_name text;
  v_pin_status text;
begin
  if p_admin_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'authentication_required');
  end if;
  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_required');
  end if;
  if p_admin_user_id = p_target_user_id then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_delete_own_account');
  end if;

  select p.role, w.status
  into v_admin_role, v_admin_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = p_admin_user_id;

  if coalesce(v_admin_role, '') not in ('admin', 'super_admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_required');
  end if;
  if coalesce(v_admin_status, '') <> 'active' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_locked');
  end if;

  select p.role, p.display_name
  into v_target_role, v_target_name
  from public.profiles p
  where p.id = p_target_user_id;

  if v_target_role is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if v_target_role = 'super_admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_delete_owner');
  end if;
  if v_admin_role = 'admin' and v_target_role = 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_delete_peer_admin');
  end if;

  v_pin_status := private.check_admin_pin(p_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  insert into private.ledger_identities (id)
  values (p_target_user_id)
  on conflict (id) do nothing;

  delete from private.account_deletion_authorizations
  where (consumed_at is null and expires_at < now())
     or consumed_at < now() - interval '1 day';

  insert into private.account_deletion_authorizations (
    target_user_id,
    actor_user_id,
    actor_role,
    target_role,
    expires_at,
    consumed_at,
    created_at
  ) values (
    p_target_user_id,
    p_admin_user_id,
    v_admin_role,
    v_target_role,
    now() + interval '2 minutes',
    null,
    now()
  )
  on conflict (target_user_id) do update
  set actor_user_id = excluded.actor_user_id,
      actor_role = excluded.actor_role,
      target_role = excluded.target_role,
      expires_at = excluded.expires_at,
      consumed_at = null,
      created_at = excluded.created_at;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'target_user_id', p_target_user_id,
    'display_name', v_target_name,
    'role', v_target_role,
    'actor_role', v_admin_role
  );
end;
$$;

create or replace function public.admin_finalize_account_deletion(
  p_admin_user_id uuid,
  p_target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_role text;
  v_admin_status text;
  v_target_role text;
begin
  select p.role, w.status
  into v_admin_role, v_admin_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = p_admin_user_id;

  if coalesce(v_admin_role, '') not in ('admin', 'super_admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_required');
  end if;
  if coalesce(v_admin_status, '') <> 'active' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_locked');
  end if;
  if exists (select 1 from auth.users u where u.id = p_target_user_id) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'auth_account_still_exists');
  end if;

  select a.target_role
  into v_target_role
  from private.account_deletion_authorizations a
  where a.target_user_id = p_target_user_id
    and a.actor_user_id = p_admin_user_id
    and a.consumed_at is not null;

  if v_target_role is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_delete_not_authorized');
  end if;
  if not exists (select 1 from private.ledger_identities l where l.id = p_target_user_id) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;

  update public.transactions
  set sender_label = 'Gelöschtes Konto'
  where sender_user_id = p_target_user_id
    and sender_label <> 'Gelöschtes Konto';

  update public.transactions
  set receiver_label = 'Gelöschtes Konto'
  where receiver_user_id = p_target_user_id
    and receiver_label <> 'Gelöschtes Konto';

  if not exists (
    select 1
    from public.admin_audit_logs a
    where a.target_user_id = p_target_user_id
      and a.action = 'ACCOUNT_DELETED'
  ) then
    perform private.write_admin_audit(
      p_admin_user_id,
      p_target_user_id,
      'ACCOUNT_DELETED',
      pg_catalog.jsonb_build_object('account_exists', true, 'target_role', v_target_role),
      pg_catalog.jsonb_build_object('account_exists', false),
      case when v_admin_role = 'super_admin'
        then 'Konto durch Owner dauerhaft gelöscht'
        else 'Konto durch Admin dauerhaft gelöscht'
      end,
      pg_catalog.jsonb_build_object(
        'auth_deleted', true,
        'ledger_anonymized', true,
        'actor_role', v_admin_role,
        'target_role', v_target_role
      )
    );
  end if;

  delete from private.account_deletion_authorizations
  where target_user_id = p_target_user_id;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

-- Compatibility wrappers keep the already deployed function usable while the
-- Edge Function is updated to the generic Admin names.
create or replace function public.owner_authorize_account_deletion(
  p_owner_user_id uuid,
  p_target_user_id uuid,
  p_pin text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.admin_authorize_account_deletion(
    p_owner_user_id,
    p_target_user_id,
    p_pin
  );
$$;

create or replace function public.owner_finalize_account_deletion(
  p_owner_user_id uuid,
  p_target_user_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.admin_finalize_account_deletion(
    p_owner_user_id,
    p_target_user_id
  );
$$;

-- The trigger is the final race-safe guard. Every Auth deletion needs a fresh
-- server-side authorization. An Admin authorization can never consume an
-- Admin target, and the Owner target is always rejected.
create or replace function private.protect_owner_auth_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target_role text;
  v_actor_user_id uuid;
  v_actor_role text;
  v_actor_status text;
begin
  select p.role
  into v_target_role
  from public.profiles p
  where p.id = old.id;

  if v_target_role = 'super_admin' then
    raise exception using
      errcode = '42501',
      message = 'owner_account_is_protected';
  end if;

  select a.actor_user_id, p.role, w.status
  into v_actor_user_id, v_actor_role, v_actor_status
  from private.account_deletion_authorizations a
  join public.profiles p on p.id = a.actor_user_id
  join public.wallets w on w.user_id = a.actor_user_id
  where a.target_user_id = old.id
    and a.expires_at >= now()
    and a.consumed_at is null;

  if v_actor_user_id is null
     or v_actor_user_id = old.id
     or coalesce(v_actor_role, '') not in ('admin', 'super_admin')
     or coalesce(v_actor_status, '') <> 'active' then
    raise exception using
      errcode = '42501',
      message = 'account_deletion_not_authorized';
  end if;

  if v_target_role = 'admin' and v_actor_role <> 'super_admin' then
    raise exception using
      errcode = '42501',
      message = 'admin_account_is_protected';
  end if;

  update private.account_deletion_authorizations
  set consumed_at = now()
  where target_user_id = old.id;

  return old;
end;
$$;

revoke all on function public.admin_authorize_account_deletion(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function public.admin_authorize_account_deletion(uuid, uuid, text)
to service_role;

revoke all on function public.admin_finalize_account_deletion(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.admin_finalize_account_deletion(uuid, uuid)
to service_role;

revoke all on function public.owner_authorize_account_deletion(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function public.owner_authorize_account_deletion(uuid, uuid, text)
to service_role;

revoke all on function public.owner_finalize_account_deletion(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.owner_finalize_account_deletion(uuid, uuid)
to service_role;

revoke all on function private.protect_owner_auth_deletion()
from public, anon, authenticated;



-- ===================== 20260822143000_allow_owner_self_coin_removal.sql =====================
-- The Owner may remove coins from their own wallet. Normal Admins still cannot
-- remove their own coins, and no Admin can remove coins from the Owner.

create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_admin_role text;
  v_target_role text;
  v_pin_status text;
  v_transaction_id uuid;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  select p.role
  into v_admin_role
  from public.profiles p
  where p.id = v_admin_user_id;

  if p_amount is null or p_amount = 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_admin_amount');
  end if;

  if p_amount < 0 then
    select p.role
    into v_target_role
    from public.profiles p
    where p.id = p_target_user_id;

    if v_target_role is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found');
    end if;

    if p_target_user_id = v_admin_user_id and v_admin_role <> 'super_admin' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_own_coins');
    end if;

    if v_target_role = 'super_admin'
       and not (p_target_user_id = v_admin_user_id and v_admin_role = 'super_admin') then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_owner_coins');
    end if;
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  begin
    v_transaction_id := public.admin_adjust_balance(p_target_user_id, p_amount, p_reason);
  exception
    when others then
      if sqlerrm in ('invalid_admin_amount', 'invalid_admin_reason', 'wallet_not_found', 'insufficient_balance') then
        return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
      end if;
      raise;
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id,
    'operation', case when p_amount > 0 then 'credit' else 'remove' end
  );
end;
$$;

revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text)
from public, anon, authenticated;

grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text)
to authenticated;


-- ===================== 20260822150000_add_group_wallets_and_abuse_reports.sql =====================
-- Shared wallets keep their own conserved ledger. Browser clients can only
-- mutate balances through the narrow SECURITY DEFINER functions below.

create table public.group_wallets (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (pg_catalog.char_length(name) between 3 and 60),
  description text check (description is null or pg_catalog.char_length(description) <= 160),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  join_code text not null unique check (join_code ~ '^[A-F0-9]{8}$'),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create table public.group_wallet_members (
  group_id uuid not null references public.group_wallets(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'manager', 'member')),
  joined_at timestamptz not null default pg_catalog.now(),
  primary key (group_id, user_id)
);

create table public.group_wallet_entries (
  id uuid primary key default extensions.gen_random_uuid(),
  group_id uuid not null references public.group_wallets(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  recipient_user_id uuid references auth.users(id) on delete set null,
  actor_label text not null,
  recipient_label text,
  kind text not null check (kind in ('deposit', 'payout')),
  amount bigint not null check (amount > 0 and amount <= 100000),
  note text check (note is null or pg_catalog.char_length(note) <= 160),
  created_at timestamptz not null default pg_catalog.now()
);

create table public.abuse_reports (
  id uuid primary key default extensions.gen_random_uuid(),
  reporter_user_id uuid not null references auth.users(id) on delete cascade,
  transaction_id uuid references public.transactions(id) on delete set null,
  category text not null check (category in ('suspicious_transfer', 'wrong_recipient', 'harassment', 'other')),
  description text not null check (pg_catalog.char_length(description) between 10 and 500),
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  resolution_note text check (resolution_note is null or pg_catalog.char_length(resolution_note) <= 500),
  reviewed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create index group_wallets_owner_user_id_idx on public.group_wallets(owner_user_id);
create index group_wallet_members_user_id_idx on public.group_wallet_members(user_id, joined_at desc);
create index group_wallet_entries_group_id_created_at_idx on public.group_wallet_entries(group_id, created_at desc);
create index group_wallet_entries_actor_user_id_idx on public.group_wallet_entries(actor_user_id);
create index group_wallet_entries_recipient_user_id_idx on public.group_wallet_entries(recipient_user_id);
create index abuse_reports_reporter_created_at_idx on public.abuse_reports(reporter_user_id, created_at desc);
create index abuse_reports_status_created_at_idx on public.abuse_reports(status, created_at desc);
create index abuse_reports_transaction_id_idx on public.abuse_reports(transaction_id);
create unique index abuse_reports_one_active_per_transaction_idx
  on public.abuse_reports(reporter_user_id, transaction_id)
  where transaction_id is not null and status in ('open', 'reviewing');

alter table public.group_wallets enable row level security;
alter table public.group_wallets force row level security;
alter table public.group_wallet_members enable row level security;
alter table public.group_wallet_members force row level security;
alter table public.group_wallet_entries enable row level security;
alter table public.group_wallet_entries force row level security;
alter table public.abuse_reports enable row level security;
alter table public.abuse_reports force row level security;

revoke all on table public.group_wallets, public.group_wallet_members, public.group_wallet_entries, public.abuse_reports
from public, anon, authenticated;

create or replace function private.require_active_user()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_wallet_status text;
begin
  if v_user_id is null then
    raise exception 'authentication_required';
  end if;

  select w.status into v_wallet_status
  from public.wallets w
  where w.user_id = v_user_id;

  if v_wallet_status is null then raise exception 'wallet_not_found'; end if;
  if v_wallet_status <> 'active' then raise exception 'wallet_locked'; end if;
  return v_user_id;
end;
$$;

revoke all on function private.require_active_user() from public, anon, authenticated;

create or replace function public.create_group_wallet(p_name text, p_description text default null)
returns table(group_id uuid, join_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_group_id uuid;
  v_join_code text;
  v_attempts integer := 0;
begin
  p_name := pg_catalog.btrim(coalesce(p_name, ''));
  p_description := nullif(pg_catalog.btrim(coalesce(p_description, '')), '');
  if pg_catalog.char_length(p_name) not between 3 and 60 then raise exception 'invalid_group_name'; end if;
  if pg_catalog.char_length(coalesce(p_description, '')) > 160 then raise exception 'description_too_long'; end if;
  if (select pg_catalog.count(*) from public.group_wallets g where g.owner_user_id = v_user_id) >= 10 then
    raise exception 'group_limit_reached';
  end if;

  loop
    v_attempts := v_attempts + 1;
    v_join_code := pg_catalog.upper(pg_catalog.encode(extensions.gen_random_bytes(4), 'hex'));
    exit when not exists (select 1 from public.group_wallets g where g.join_code = v_join_code);
    if v_attempts >= 5 then raise exception 'join_code_generation_failed'; end if;
  end loop;

  insert into public.group_wallets(name, description, owner_user_id, join_code)
  values (p_name, p_description, v_user_id, v_join_code)
  returning id into v_group_id;

  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'owner');

  return query select v_group_id, v_join_code;
end;
$$;

create or replace function public.join_group_wallet(p_join_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_group_id uuid;
  v_code text := pg_catalog.upper(pg_catalog.btrim(coalesce(p_join_code, '')));
begin
  if v_code !~ '^[A-F0-9]{8}$' then raise exception 'invalid_join_code'; end if;
  if (select pg_catalog.count(*) from public.group_wallet_members m where m.user_id = v_user_id) >= 30 then
    raise exception 'membership_limit_reached';
  end if;

  select g.id into v_group_id from public.group_wallets g where g.join_code = v_code;
  if v_group_id is null then raise exception 'group_not_found'; end if;

  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'member')
  on conflict (group_id, user_id) do nothing;
  return v_group_id;
end;
$$;

create or replace function public.leave_group_wallet(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_role text;
begin
  select m.role into v_role
  from public.group_wallet_members m
  where m.group_id = p_group_id and m.user_id = v_user_id;
  if v_role is null then raise exception 'group_membership_required'; end if;
  if v_role = 'owner' then raise exception 'owner_cannot_leave_group'; end if;
  delete from public.group_wallet_members m where m.group_id = p_group_id and m.user_id = v_user_id;
end;
$$;

create or replace function public.set_group_member_role(p_group_id uuid, p_user_id uuid, p_role text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_owner_id uuid;
  v_current_role text;
begin
  select g.owner_user_id into v_owner_id from public.group_wallets g where g.id = p_group_id;
  if v_owner_id is null then raise exception 'group_not_found'; end if;
  if v_owner_id <> v_user_id then raise exception 'group_owner_required'; end if;
  if p_user_id = v_owner_id then raise exception 'cannot_change_group_owner'; end if;
  if p_role not in ('manager', 'member') then raise exception 'invalid_group_role'; end if;

  update public.group_wallet_members m
  set role = p_role
  where m.group_id = p_group_id and m.user_id = p_user_id
  returning m.role into v_current_role;
  if v_current_role is null then raise exception 'group_member_not_found'; end if;
  return v_current_role;
end;
$$;

create or replace function public.deposit_group_coins(p_group_id uuid, p_amount bigint, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_entry_id uuid;
  v_actor_label text;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if pg_catalog.char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;
  if not exists (
    select 1 from public.group_wallet_members m where m.group_id = p_group_id and m.user_id = v_user_id
  ) then raise exception 'group_membership_required'; end if;

  perform g.id from public.group_wallets g where g.id = p_group_id for update;
  if not found then raise exception 'group_not_found'; end if;
  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_amount then raise exception 'insufficient_balance'; end if;

  select p.display_name into v_actor_label from public.profiles p where p.id = v_user_id;
  update public.wallets w set balance = balance - p_amount, updated_at = pg_catalog.now() where w.id = v_wallet.id;
  update public.group_wallets g set balance = balance + p_amount, updated_at = pg_catalog.now() where g.id = p_group_id;
  insert into public.group_wallet_entries(group_id, actor_user_id, actor_label, kind, amount, note)
  values (p_group_id, v_user_id, coalesce(v_actor_label, 'Mitglied'), 'deposit', p_amount, nullif(pg_catalog.btrim(coalesce(p_note, '')), ''))
  returning id into v_entry_id;
  return v_entry_id;
end;
$$;

create or replace function public.payout_group_coins(
  p_group_id uuid,
  p_recipient_user_id uuid,
  p_amount bigint,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_actor_role text;
  v_group_balance bigint;
  v_recipient_wallet public.wallets%rowtype;
  v_entry_id uuid;
  v_actor_label text;
  v_recipient_label text;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if pg_catalog.char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;

  select m.role into v_actor_role
  from public.group_wallet_members m
  where m.group_id = p_group_id and m.user_id = v_user_id;
  if v_actor_role not in ('owner', 'manager') then raise exception 'group_manager_required'; end if;
  if not exists (
    select 1 from public.group_wallet_members m where m.group_id = p_group_id and m.user_id = p_recipient_user_id
  ) then raise exception 'recipient_not_group_member'; end if;

  select g.balance into v_group_balance from public.group_wallets g where g.id = p_group_id for update;
  if v_group_balance is null then raise exception 'group_not_found'; end if;
  if v_group_balance < p_amount then raise exception 'insufficient_group_balance'; end if;
  select w.* into v_recipient_wallet from public.wallets w where w.user_id = p_recipient_user_id for update;
  if v_recipient_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_recipient_wallet.status <> 'active' then raise exception 'recipient_wallet_locked'; end if;

  select p.display_name into v_actor_label from public.profiles p where p.id = v_user_id;
  select p.display_name into v_recipient_label from public.profiles p where p.id = p_recipient_user_id;
  update public.group_wallets g set balance = balance - p_amount, updated_at = pg_catalog.now() where g.id = p_group_id;
  update public.wallets w set balance = balance + p_amount, updated_at = pg_catalog.now() where w.id = v_recipient_wallet.id;
  insert into public.group_wallet_entries(
    group_id, actor_user_id, recipient_user_id, actor_label, recipient_label, kind, amount, note
  ) values (
    p_group_id, v_user_id, p_recipient_user_id, coalesce(v_actor_label, 'Verantwortliche Person'),
    coalesce(v_recipient_label, 'Mitglied'), 'payout', p_amount, nullif(pg_catalog.btrim(coalesce(p_note, '')), '')
  ) returning id into v_entry_id;

  insert into public.notifications(user_id, kind, title, message)
  values (
    p_recipient_user_id,
    'group_payout',
    'Coins aus Gruppen-Wallet',
    coalesce(v_actor_label, 'Eine verantwortliche Person') || ' hat dir ' || p_amount || ' GIBB aus einer Gruppen-Wallet ausgezahlt.'
  );
  return v_entry_id;
end;
$$;

create or replace function public.list_my_group_wallets()
returns table(
  group_id uuid,
  group_name text,
  group_description text,
  balance bigint,
  member_role text,
  member_count bigint,
  join_code text,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
begin
  return query
  select g.id, g.name, g.description, g.balance, me.role,
    (select pg_catalog.count(*) from public.group_wallet_members members where members.group_id = g.id),
    g.join_code, g.updated_at
  from public.group_wallet_members me
  join public.group_wallets g on g.id = me.group_id
  where me.user_id = v_user_id
  order by g.updated_at desc, g.created_at desc;
end;
$$;

create or replace function public.list_group_members(p_group_id uuid)
returns table(user_id uuid, display_name text, username text, member_role text, joined_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
begin
  if not exists (
    select 1 from public.group_wallet_members own where own.group_id = p_group_id and own.user_id = v_user_id
  ) then raise exception 'group_membership_required'; end if;
  return query
  select m.user_id, p.display_name, p.username, m.role, m.joined_at
  from public.group_wallet_members m
  join public.profiles p on p.id = m.user_id
  where m.group_id = p_group_id
  order by case m.role when 'owner' then 0 when 'manager' then 1 else 2 end, p.display_name;
end;
$$;

create or replace function public.list_group_history(p_group_id uuid)
returns table(
  entry_id uuid,
  kind text,
  amount bigint,
  actor_label text,
  recipient_label text,
  note text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
begin
  if not exists (
    select 1 from public.group_wallet_members own where own.group_id = p_group_id and own.user_id = v_user_id
  ) then raise exception 'group_membership_required'; end if;
  return query
  select e.id, e.kind, e.amount, e.actor_label, e.recipient_label, e.note, e.created_at
  from public.group_wallet_entries e
  where e.group_id = p_group_id
  order by e.created_at desc
  limit 50;
end;
$$;

create or replace function public.submit_abuse_report(
  p_transaction_id uuid,
  p_category text,
  p_description text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_report_id uuid;
begin
  p_description := pg_catalog.btrim(coalesce(p_description, ''));
  if p_category not in ('suspicious_transfer', 'wrong_recipient', 'harassment', 'other') then
    raise exception 'invalid_report_category';
  end if;
  if pg_catalog.char_length(p_description) not between 10 and 500 then raise exception 'invalid_report_description'; end if;
  if not exists (
    select 1 from public.transactions t
    where t.id = p_transaction_id
      and (t.sender_user_id = v_user_id or t.receiver_user_id = v_user_id)
  ) then raise exception 'transaction_not_reportable'; end if;

  insert into public.abuse_reports(reporter_user_id, transaction_id, category, description)
  values (v_user_id, p_transaction_id, p_category, p_description)
  returning id into v_report_id;
  return v_report_id;
exception
  when unique_violation then raise exception 'report_already_exists';
end;
$$;

create or replace function public.list_my_abuse_reports()
returns table(
  report_id uuid,
  transaction_id uuid,
  category text,
  description text,
  status text,
  resolution_note text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
begin
  return query
  select r.id, r.transaction_id, r.category, r.description, r.status, r.resolution_note, r.created_at, r.updated_at
  from public.abuse_reports r
  where r.reporter_user_id = v_user_id
  order by r.created_at desc
  limit 50;
end;
$$;

create or replace function public.admin_list_abuse_reports(p_status text default null)
returns table(
  report_id uuid,
  reporter_user_id uuid,
  reporter_name text,
  transaction_id uuid,
  transaction_summary text,
  category text,
  description text,
  status text,
  resolution_note text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_id uuid := private.require_admin();
begin
  perform private.assert_mfa_if_enrolled(v_admin_id);
  if p_status is not null and p_status not in ('open', 'reviewing', 'resolved', 'dismissed') then
    raise exception 'invalid_report_status';
  end if;
  return query
  select r.id, r.reporter_user_id, p.display_name, r.transaction_id,
    case when t.id is null then 'Transaktion nicht mehr verfügbar'
      else t.sender_label || ' → ' || t.receiver_label || ' · ' || t.amount || ' GIBB' end,
    r.category, r.description, r.status, r.resolution_note, r.created_at, r.updated_at
  from public.abuse_reports r
  join public.profiles p on p.id = r.reporter_user_id
  left join public.transactions t on t.id = r.transaction_id
  where p_status is null or r.status = p_status
  order by case r.status when 'open' then 0 when 'reviewing' then 1 else 2 end, r.created_at desc
  limit 100;
end;
$$;

create or replace function public.admin_review_abuse_report(
  p_report_id uuid,
  p_status text,
  p_resolution_note text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_id uuid := private.require_admin();
  v_reporter_id uuid;
begin
  perform private.assert_mfa_if_enrolled(v_admin_id);
  p_resolution_note := nullif(pg_catalog.btrim(coalesce(p_resolution_note, '')), '');
  if p_status not in ('reviewing', 'resolved', 'dismissed') then raise exception 'invalid_report_status'; end if;
  if pg_catalog.char_length(coalesce(p_resolution_note, '')) > 500 then raise exception 'resolution_note_too_long'; end if;

  update public.abuse_reports r
  set status = p_status, resolution_note = p_resolution_note, reviewed_by = v_admin_id, updated_at = pg_catalog.now()
  where r.id = p_report_id
  returning r.reporter_user_id into v_reporter_id;
  if v_reporter_id is null then raise exception 'report_not_found'; end if;

  insert into public.notifications(user_id, kind, title, message)
  values (
    v_reporter_id,
    'report_status',
    'Meldung aktualisiert',
    case p_status
      when 'reviewing' then 'Deine Meldung wird jetzt geprüft.'
      when 'resolved' then 'Deine Meldung wurde geprüft und abgeschlossen.'
      else 'Deine Meldung wurde geprüft und geschlossen.'
    end
  );
  return p_status;
end;
$$;

revoke all on function public.create_group_wallet(text, text) from public, anon, authenticated;
revoke all on function public.join_group_wallet(text) from public, anon, authenticated;
revoke all on function public.leave_group_wallet(uuid) from public, anon, authenticated;
revoke all on function public.set_group_member_role(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.deposit_group_coins(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.payout_group_coins(uuid, uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.list_my_group_wallets() from public, anon, authenticated;
revoke all on function public.list_group_members(uuid) from public, anon, authenticated;
revoke all on function public.list_group_history(uuid) from public, anon, authenticated;
revoke all on function public.submit_abuse_report(uuid, text, text) from public, anon, authenticated;
revoke all on function public.list_my_abuse_reports() from public, anon, authenticated;
revoke all on function public.admin_list_abuse_reports(text) from public, anon, authenticated;
revoke all on function public.admin_review_abuse_report(uuid, text, text) from public, anon, authenticated;

grant execute on function public.create_group_wallet(text, text) to authenticated;
grant execute on function public.join_group_wallet(text) to authenticated;
grant execute on function public.leave_group_wallet(uuid) to authenticated;
grant execute on function public.set_group_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.deposit_group_coins(uuid, bigint, text) to authenticated;
grant execute on function public.payout_group_coins(uuid, uuid, bigint, text) to authenticated;
grant execute on function public.list_my_group_wallets() to authenticated;
grant execute on function public.list_group_members(uuid) to authenticated;
grant execute on function public.list_group_history(uuid) to authenticated;
grant execute on function public.submit_abuse_report(uuid, text, text) to authenticated;
grant execute on function public.list_my_abuse_reports() to authenticated;
grant execute on function public.admin_list_abuse_reports(text) to authenticated;
grant execute on function public.admin_review_abuse_report(uuid, text, text) to authenticated;


-- ===================== 20260822151000_harden_group_wallet_policies.sql =====================
-- Keep direct Data API access explicitly closed. The authenticated RPCs are
-- the only supported entry points and validate auth.uid() on every call.
create policy "group_wallets_rpc_only"
on public.group_wallets for all to authenticated
using (false) with check (false);

create policy "group_wallet_members_rpc_only"
on public.group_wallet_members for all to authenticated
using (false) with check (false);

create policy "group_wallet_entries_rpc_only"
on public.group_wallet_entries for all to authenticated
using (false) with check (false);

create policy "abuse_reports_rpc_only"
on public.abuse_reports for all to authenticated
using (false) with check (false);

create index abuse_reports_reviewed_by_idx on public.abuse_reports(reviewed_by);


-- ===================== 20260822162000_add_session_diagnostics.sql =====================
create table if not exists public.session_diagnostics (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  app_version text,
  reported_status integer,
  reported_code text,
  reported_message text,
  jwt_alg text,
  jwt_kid text,
  jwt_iss text,
  jwt_aud text,
  jwt_role text,
  jwt_aal text,
  auth_status integer not null,
  data_status integer not null,
  data_error text
);

alter table public.session_diagnostics enable row level security;
revoke all on table public.session_diagnostics from anon, authenticated;
revoke all on sequence public.session_diagnostics_id_seq from anon, authenticated;

comment on table public.session_diagnostics is
  'Security-safe session diagnostics. Never stores access tokens, passwords, MFA codes, email addresses, user IDs or IP addresses.';


-- ===================== 20260822163000_add_session_diagnostic_rpc.sql =====================
create or replace function public.submit_session_diagnostic(
  p_app_version text,
  p_reported_status integer,
  p_reported_code text,
  p_reported_message text,
  p_jwt_alg text,
  p_jwt_kid text,
  p_jwt_iss text,
  p_jwt_aud text,
  p_jwt_role text,
  p_jwt_aal text,
  p_auth_status integer,
  p_data_status integer,
  p_data_error text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.session_diagnostics (
    app_version, reported_status, reported_code, reported_message,
    jwt_alg, jwt_kid, jwt_iss, jwt_aud, jwt_role, jwt_aal,
    auth_status, data_status, data_error
  ) values (
    left(p_app_version, 20), p_reported_status, left(p_reported_code, 100), left(p_reported_message, 300),
    left(p_jwt_alg, 30), left(p_jwt_kid, 100), left(p_jwt_iss, 200), left(p_jwt_aud, 100),
    left(p_jwt_role, 100), left(p_jwt_aal, 30), p_auth_status, p_data_status, left(p_data_error, 500)
  );
end;
$$;

revoke all on function public.submit_session_diagnostic(text, integer, text, text, text, text, text, text, text, text, integer, integer, text) from public;
grant execute on function public.submit_session_diagnostic(text, integer, text, text, text, text, text, text, text, text, integer, integer, text) to anon, authenticated;

comment on function public.submit_session_diagnostic(text, integer, text, text, text, text, text, text, text, text, integer, integer, text) is
  'Accepts only bounded, non-secret JWT metadata and API error details for session troubleshooting.';


-- ===================== 20260822164000_add_session_timing_diagnostics.sql =====================
alter table public.session_diagnostics
  add column if not exists jwt_iat bigint,
  add column if not exists jwt_exp bigint,
  add column if not exists edge_epoch bigint,
  add column if not exists auth_date timestamptz,
  add column if not exists data_date timestamptz;

create or replace function public.submit_session_timing_diagnostic(
  p_app_version text,
  p_reported_status integer,
  p_reported_code text,
  p_reported_message text,
  p_jwt_alg text,
  p_jwt_kid text,
  p_jwt_iss text,
  p_jwt_aud text,
  p_jwt_role text,
  p_jwt_aal text,
  p_jwt_iat bigint,
  p_jwt_exp bigint,
  p_edge_epoch bigint,
  p_auth_date timestamptz,
  p_data_date timestamptz,
  p_auth_status integer,
  p_data_status integer,
  p_data_error text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.session_diagnostics (
    app_version, reported_status, reported_code, reported_message,
    jwt_alg, jwt_kid, jwt_iss, jwt_aud, jwt_role, jwt_aal,
    jwt_iat, jwt_exp, edge_epoch, auth_date, data_date,
    auth_status, data_status, data_error
  ) values (
    left(p_app_version, 20), p_reported_status, left(p_reported_code, 100), left(p_reported_message, 300),
    left(p_jwt_alg, 30), left(p_jwt_kid, 100), left(p_jwt_iss, 200), left(p_jwt_aud, 100),
    left(p_jwt_role, 100), left(p_jwt_aal, 30), p_jwt_iat, p_jwt_exp, p_edge_epoch,
    p_auth_date, p_data_date, p_auth_status, p_data_status, left(p_data_error, 500)
  );
end;
$$;

revoke all on function public.submit_session_timing_diagnostic(text, integer, text, text, text, text, text, text, text, text, bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text) from public;
grant execute on function public.submit_session_timing_diagnostic(text, integer, text, text, text, text, text, text, text, text, bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text) to anon;

comment on function public.submit_session_timing_diagnostic(text, integer, text, text, text, text, text, text, text, text, bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text) is
  'Accepts bounded, non-secret JWT timing metadata and API response dates for session troubleshooting.';


-- ===================== 20260822165000_remove_session_diagnostics.sql =====================
drop function if exists public.submit_session_timing_diagnostic(
  text, integer, text, text, text, text, text, text, text, text,
  bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text
);

drop function if exists public.submit_session_diagnostic(
  text, integer, text, text, text, text, text, text, text, text,
  integer, integer, text
);

drop table if exists public.session_diagnostics;


-- ===================== 20260822170000_add_wallet_game_center.sql =====================
-- Server-authoritative Game Center. Every round uses the normal GIBB wallet;
-- browser clients can neither choose results nor write balances directly.

alter table public.transactions
  drop constraint if exists transactions_type_check;

alter table public.transactions
  add constraint transactions_type_check check (
    type in (
      'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
      'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN',
      'COIN_PURCHASE', 'GAME_ENTRY', 'GAME_REWARD'
    )
  );

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED'
    )
  );

create table public.game_settings (
  game_key text primary key check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card'
  )),
  label text not null check (char_length(label) between 3 and 40),
  enabled boolean not null default true,
  sort_order smallint not null default 0,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.game_settings (game_key, label, sort_order) values
  ('game_center', 'Gesamtes Game Center', 0),
  ('roulette', 'Roulette', 10),
  ('coin_flip', 'Münzwurf', 20),
  ('blackjack', 'Blackjack', 30),
  ('dice_duel', 'Würfelduell', 40),
  ('high_card', 'High Card', 50)
on conflict (game_key) do nothing;

create table public.game_rounds (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  game_key text not null check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card'
  )),
  choice text,
  wager bigint not null check (wager between 5 and 1000),
  payout bigint not null check (payout between 0 and 36000),
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index game_rounds_user_created_idx
  on public.game_rounds (user_id, created_at desc);

create table public.blackjack_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  wager bigint not null check (wager between 5 and 1000),
  player_cards smallint[] not null,
  dealer_cards smallint[] not null,
  status text not null default 'active' check (status in ('active', 'won', 'lost', 'push')),
  payout bigint not null default 0 check (payout between 0 and 2500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index blackjack_one_active_session_per_user
  on public.blackjack_sessions (user_id)
  where status = 'active';

alter table public.game_settings enable row level security;
alter table public.game_rounds enable row level security;
alter table public.blackjack_sessions enable row level security;

create policy game_settings_authenticated_read
  on public.game_settings for select to authenticated using (true);

create policy game_rounds_own_read
  on public.game_rounds for select to authenticated using ((select auth.uid()) = user_id);

revoke all on table public.game_settings from public, anon, authenticated;
revoke all on table public.game_rounds from public, anon, authenticated;
revoke all on table public.blackjack_sessions from public, anon, authenticated;
grant select on table public.game_settings, public.game_rounds to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_settings'
  ) then
    alter publication supabase_realtime add table public.game_settings;
  end if;
end;
$$;

create or replace function private.game_random(p_max integer)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_bytes bytea;
  v_number bigint;
begin
  if p_max is null or p_max < 1 or p_max > 1000000 then
    raise exception 'invalid_random_range';
  end if;
  v_bytes := extensions.gen_random_bytes(4);
  v_number := pg_catalog.get_byte(v_bytes, 0)::bigint * 16777216
    + pg_catalog.get_byte(v_bytes, 1)::bigint * 65536
    + pg_catalog.get_byte(v_bytes, 2)::bigint * 256
    + pg_catalog.get_byte(v_bytes, 3)::bigint;
  return (v_number % p_max)::integer;
end;
$$;

create or replace function private.blackjack_score(p_cards smallint[])
returns integer
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_card smallint;
  v_total integer := 0;
  v_aces integer := 0;
begin
  foreach v_card in array coalesce(p_cards, array[]::smallint[]) loop
    if v_card = 1 then
      v_total := v_total + 11;
      v_aces := v_aces + 1;
    else
      v_total := v_total + least(v_card, 10);
    end if;
  end loop;
  while v_total > 21 and v_aces > 0 loop
    v_total := v_total - 10;
    v_aces := v_aces - 1;
  end loop;
  return v_total;
end;
$$;

create or replace function private.game_is_enabled(p_game_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.enabled from public.game_settings s where s.game_key = 'game_center'), false)
    and coalesce((select s.enabled from public.game_settings s where s.game_key = p_game_key), false);
$$;

revoke all on function private.game_random(integer) from public, anon, authenticated;
revoke all on function private.blackjack_score(smallint[]) from public, anon, authenticated;
revoke all on function private.game_is_enabled(text) from public, anon, authenticated;

create or replace function public.get_game_center_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_balance bigint;
  v_settings jsonb;
  v_rounds jsonb;
  v_blackjack jsonb;
begin
  select w.balance into v_balance from public.wallets w where w.user_id = v_user_id;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'game_key', s.game_key, 'label', s.label, 'enabled', s.enabled,
    'updated_at', s.updated_at
  ) order by s.sort_order), '[]'::jsonb)
  into v_settings from public.game_settings s;

  select coalesce(pg_catalog.jsonb_agg(row_data order by created_at desc), '[]'::jsonb)
  into v_rounds
  from (
    select r.created_at, pg_catalog.jsonb_build_object(
      'id', r.id, 'game_key', r.game_key, 'choice', r.choice,
      'wager', r.wager, 'payout', r.payout, 'result', r.result,
      'created_at', r.created_at
    ) as row_data
    from public.game_rounds r
    where r.user_id = v_user_id
    order by r.created_at desc
    limit 8
  ) recent;

  select pg_catalog.jsonb_build_object(
    'id', b.id, 'wager', b.wager, 'player_cards', pg_catalog.to_jsonb(b.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(b.dealer_cards[1:1]), 'dealer_hidden', true,
    'status', b.status, 'payout', b.payout,
    'player_score', private.blackjack_score(b.player_cards)
  ) into v_blackjack
  from public.blackjack_sessions b
  where b.user_id = v_user_id and b.status = 'active'
  order by b.created_at desc limit 1;

  return pg_catalog.jsonb_build_object(
    'balance', v_balance,
    'settings', v_settings,
    'recent_rounds', v_rounds,
    'blackjack', v_blackjack
  );
end;
$$;

create or replace function public.play_instant_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_payout bigint := 0;
  v_result jsonb := '{}'::jsonb;
  v_result_text text;
  v_round_id uuid;
  v_entry_id uuid;
  v_reward_id uuid;
  v_number integer;
  v_user_roll integer;
  v_house_roll integer;
  v_color text;
  v_label text;
begin
  p_game_key := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  p_choice := pg_catalog.lower(pg_catalog.btrim(coalesce(p_choice, '')));
  if p_game_key not in ('roulette', 'coin_flip', 'dice_duel', 'high_card') then
    raise exception 'invalid_game';
  end if;
  if p_wager is null or p_wager < 5 or p_wager > 1000 then
    raise exception 'invalid_game_wager';
  end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  if p_game_key = 'roulette' and p_choice not in ('rot', 'schwarz', '0','1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','18','19','20','21','22','23','24','25','26','27','28','29','30','31','32','33','34','35','36') then
    raise exception 'invalid_game_choice';
  elsif p_game_key = 'coin_flip' and p_choice not in ('kopf', 'zahl') then
    raise exception 'invalid_game_choice';
  elsif p_game_key in ('dice_duel', 'high_card') and p_choice <> 'spielen' then
    raise exception 'invalid_game_choice';
  end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;
  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  if p_game_key = 'roulette' then
    v_label := 'Roulette';
    v_number := private.game_random(37);
    v_color := case
      when v_number = 0 then 'grün'
      when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot'
      else 'schwarz'
    end;
    if p_choice = v_number::text then v_payout := p_wager * 36;
    elsif p_choice = v_color then v_payout := p_wager * 2;
    end if;
    v_result_text := v_number || ' · ' || v_color;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
  elsif p_game_key = 'coin_flip' then
    v_label := 'Münzwurf';
    v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);
  elsif p_game_key = 'dice_duel' then
    v_label := 'Würfelduell';
    v_user_roll := private.game_random(6) + 1;
    v_house_roll := private.game_random(6) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  else
    v_label := 'High Card';
    v_user_roll := private.game_random(13) + 1;
    v_house_roll := private.game_random(13) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  end if;

  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;
  v_entry_id := private.append_transaction(v_user_id, null, p_wager, 'GAME_ENTRY', 'Game Center · ' || v_label || ' · Einsatz');
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = now() where id = v_wallet.id;
    v_reward_id := private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · ' || v_label || ' · Ergebnis ' || v_result_text);
  end if;

  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (v_user_id, p_game_key, p_choice, p_wager, v_payout, v_result)
  returning id into v_round_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'round_id', v_round_id, 'game_key', p_game_key,
    'choice', p_choice, 'wager', p_wager, 'payout', v_payout,
    'net', v_payout - p_wager, 'result', v_result,
    'balance', v_wallet.balance - p_wager + v_payout,
    'entry_transaction_id', v_entry_id, 'reward_transaction_id', v_reward_id
  );
end;
$$;

create or replace function public.start_blackjack(p_wager bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_session public.blackjack_sessions%rowtype;
  v_player_score integer;
  v_dealer_score integer;
  v_payout bigint := 0;
  v_status text := 'active';
  v_round_id uuid;
begin
  if p_wager is null or p_wager < 5 or p_wager > 1000 then raise exception 'invalid_game_wager'; end if;
  if not private.game_is_enabled('blackjack') then raise exception 'game_disabled'; end if;
  if exists (select 1 from public.blackjack_sessions b where b.user_id = v_user_id and b.status = 'active') then
    raise exception 'blackjack_session_active';
  end if;
  if exists (
    select 1 from public.blackjack_sessions b
    where b.user_id = v_user_id and b.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;

  v_session.player_cards := array[(private.game_random(13) + 1)::smallint, (private.game_random(13) + 1)::smallint];
  v_session.dealer_cards := array[(private.game_random(13) + 1)::smallint, (private.game_random(13) + 1)::smallint];
  v_player_score := private.blackjack_score(v_session.player_cards);
  v_dealer_score := private.blackjack_score(v_session.dealer_cards);
  if v_player_score = 21 and v_dealer_score = 21 then v_status := 'push'; v_payout := p_wager;
  elsif v_player_score = 21 then v_status := 'won'; v_payout := p_wager * 5 / 2;
  elsif v_dealer_score = 21 then v_status := 'lost'; end if;

  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;
  perform private.append_transaction(v_user_id, null, p_wager, 'GAME_ENTRY', 'Game Center · Blackjack · Einsatz');
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = now() where id = v_wallet.id;
    perform private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · Blackjack · Auszahlung');
  end if;

  insert into public.blackjack_sessions (user_id, wager, player_cards, dealer_cards, status, payout)
  values (v_user_id, p_wager, v_session.player_cards, v_session.dealer_cards, v_status, v_payout)
  returning * into v_session;

  if v_status <> 'active' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (v_user_id, 'blackjack', 'deal', p_wager, v_payout, pg_catalog.jsonb_build_object(
      'player_cards', v_session.player_cards, 'dealer_cards', v_session.dealer_cards,
      'player_score', v_player_score, 'dealer_score', v_dealer_score, 'status', v_status
    )) returning id into v_round_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'wager', p_wager,
    'player_cards', pg_catalog.to_jsonb(v_session.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(case when v_status = 'active' then v_session.dealer_cards[1:1] else v_session.dealer_cards end),
    'dealer_hidden', v_status = 'active', 'status', v_status, 'payout', v_payout,
    'player_score', v_player_score,
    'dealer_score', case when v_status = 'active' then null else v_dealer_score end,
    'balance', v_wallet.balance - p_wager + v_payout, 'round_id', v_round_id
  );
end;
$$;

create or replace function public.blackjack_action(p_session_id uuid, p_action text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_session public.blackjack_sessions%rowtype;
  v_player_score integer;
  v_dealer_score integer;
  v_status text := 'active';
  v_payout bigint := 0;
  v_round_id uuid;
begin
  p_action := pg_catalog.lower(pg_catalog.btrim(coalesce(p_action, '')));
  if p_action not in ('hit', 'stand') then raise exception 'invalid_blackjack_action'; end if;
  select b.* into v_session
  from public.blackjack_sessions b
  where b.id = p_session_id and b.user_id = v_user_id
  for update;
  if v_session.id is null then raise exception 'blackjack_session_not_found'; end if;
  if v_session.status <> 'active' then raise exception 'blackjack_session_finished'; end if;

  if p_action = 'hit' then
    v_session.player_cards := pg_catalog.array_append(v_session.player_cards, (private.game_random(13) + 1)::smallint);
    v_player_score := private.blackjack_score(v_session.player_cards);
    if v_player_score > 21 then v_status := 'lost'; end if;
  else
    v_player_score := private.blackjack_score(v_session.player_cards);
    v_dealer_score := private.blackjack_score(v_session.dealer_cards);
    while v_dealer_score < 17 loop
      v_session.dealer_cards := pg_catalog.array_append(v_session.dealer_cards, (private.game_random(13) + 1)::smallint);
      v_dealer_score := private.blackjack_score(v_session.dealer_cards);
    end loop;
    if v_dealer_score > 21 or v_player_score > v_dealer_score then v_status := 'won'; v_payout := v_session.wager * 2;
    elsif v_player_score = v_dealer_score then v_status := 'push'; v_payout := v_session.wager;
    else v_status := 'lost'; end if;
  end if;

  if v_status = 'active' then
    update public.blackjack_sessions
    set player_cards = v_session.player_cards, updated_at = now()
    where id = v_session.id;
    return pg_catalog.jsonb_build_object(
      'ok', true, 'id', v_session.id, 'wager', v_session.wager,
      'player_cards', pg_catalog.to_jsonb(v_session.player_cards),
      'dealer_cards', pg_catalog.to_jsonb(v_session.dealer_cards[1:1]),
      'dealer_hidden', true, 'status', 'active', 'payout', 0,
      'player_score', v_player_score
    );
  end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = now() where id = v_wallet.id;
    perform private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · Blackjack · Auszahlung');
  end if;
  v_dealer_score := private.blackjack_score(v_session.dealer_cards);
  update public.blackjack_sessions set
    player_cards = v_session.player_cards, dealer_cards = v_session.dealer_cards,
    status = v_status, payout = v_payout, updated_at = now()
  where id = v_session.id;
  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (v_user_id, 'blackjack', p_action, v_session.wager, v_payout, pg_catalog.jsonb_build_object(
    'player_cards', v_session.player_cards, 'dealer_cards', v_session.dealer_cards,
    'player_score', v_player_score, 'dealer_score', v_dealer_score, 'status', v_status
  )) returning id into v_round_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'wager', v_session.wager,
    'player_cards', pg_catalog.to_jsonb(v_session.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(v_session.dealer_cards),
    'dealer_hidden', false, 'status', v_status, 'payout', v_payout,
    'player_score', v_player_score, 'dealer_score', v_dealer_score,
    'balance', v_wallet.balance + v_payout, 'round_id', v_round_id
  );
end;
$$;

create or replace function public.admin_set_game_enabled(
  p_game_key text,
  p_enabled boolean,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_old_enabled boolean;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  p_game_key := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  select s.enabled into v_old_enabled from public.game_settings s where s.game_key = p_game_key for update;
  if v_old_enabled is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game'); end if;
  if p_enabled is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting'); end if;
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;
  update public.game_settings set enabled = p_enabled, updated_by = v_admin_user_id, updated_at = now()
  where game_key = p_game_key;
  if v_old_enabled is distinct from p_enabled then
    perform private.write_admin_audit(
      v_admin_user_id, null, 'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object('game_key', p_game_key, 'enabled', v_old_enabled),
      pg_catalog.jsonb_build_object('game_key', p_game_key, 'enabled', p_enabled),
      'Game-Center-Schalter geändert'
    );
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'game_key', p_game_key, 'enabled', p_enabled);
end;
$$;

revoke all on function public.get_game_center_state() from public, anon, authenticated;
revoke all on function public.play_instant_game(text, text, bigint) from public, anon, authenticated;
revoke all on function public.start_blackjack(bigint) from public, anon, authenticated;
revoke all on function public.blackjack_action(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_set_game_enabled(text, boolean, text) from public, anon, authenticated;

grant execute on function public.get_game_center_state() to authenticated;
grant execute on function public.play_instant_game(text, text, bigint) to authenticated;
grant execute on function public.start_blackjack(bigint) to authenticated;
grant execute on function public.blackjack_action(uuid, text) to authenticated;
grant execute on function public.admin_set_game_enabled(text, boolean, text) to authenticated;


-- ===================== 20260822171000_harden_game_center_advisors.sql =====================
-- Make the intentional hidden-card policy explicit and cover the settings FK.
create policy blackjack_sessions_no_direct_read
  on public.blackjack_sessions for select to authenticated using (false);

create index game_settings_updated_by_idx
  on public.game_settings (updated_by)
  where updated_by is not null;


-- ===================== 20260822180000_allow_one_gibb_game_entry.sql =====================
-- Let members play a round from the same normal wallet with as little as 1 GIBB.
alter table public.game_rounds
  drop constraint game_rounds_wager_check,
  add constraint game_rounds_wager_check check (wager between 1 and 1000);

alter table public.blackjack_sessions
  drop constraint blackjack_sessions_wager_check,
  add constraint blackjack_sessions_wager_check check (wager between 1 and 1000);

do $migration$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.play_instant_game(text,text,bigint)'::regprocedure::oid)
    into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager < 5') = 0 then
    raise exception 'play_instant_game wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager < 5', 'p_wager < 1');

  select pg_catalog.pg_get_functiondef('public.start_blackjack(bigint)'::regprocedure::oid)
    into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager < 5') = 0 then
    raise exception 'start_blackjack wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager < 5', 'p_wager < 1');
end;
$migration$;

