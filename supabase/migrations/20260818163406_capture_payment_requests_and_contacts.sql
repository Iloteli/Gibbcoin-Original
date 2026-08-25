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
