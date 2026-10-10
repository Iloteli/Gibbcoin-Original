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
