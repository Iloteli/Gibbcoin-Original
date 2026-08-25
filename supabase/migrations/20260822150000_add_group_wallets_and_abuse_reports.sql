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
