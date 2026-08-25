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
