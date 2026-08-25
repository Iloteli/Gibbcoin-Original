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
