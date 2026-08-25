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

