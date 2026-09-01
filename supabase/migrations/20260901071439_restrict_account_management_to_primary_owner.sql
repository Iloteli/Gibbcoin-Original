-- Robyn remains the primary owner for destructive account actions. Secondary
-- owners keep their other owner permissions but cannot ban or delete accounts.

create or replace function private.is_primary_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'::uuid
    and exists (
      select 1
      from public.profiles p
      where p.id = p_user_id
        and p.role = 'super_admin'
    );
$$;

revoke all on function private.is_primary_owner(uuid)
from public, anon, authenticated;

create or replace function public.get_my_admin_account_capabilities()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_is_primary_owner boolean := false;
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object(
      'is_primary_owner', false,
      'can_manage_standard_accounts', false,
      'can_manage_owner_accounts', false
    );
  end if;

  select p.role into v_role
  from public.profiles p
  where p.id = v_user_id;

  v_is_primary_owner := v_user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'::uuid
    and v_role = 'super_admin';

  return pg_catalog.jsonb_build_object(
    'is_primary_owner', v_is_primary_owner,
    'can_manage_standard_accounts', v_role = 'admin' or v_is_primary_owner,
    'can_manage_owner_accounts', v_is_primary_owner
  );
end;
$$;

revoke all on function public.get_my_admin_account_capabilities()
from public, anon;
grant execute on function public.get_my_admin_account_capabilities()
to authenticated;

alter table private.account_deletion_authorizations
  drop constraint if exists account_deletion_authorizations_target_role_check;

alter table private.account_deletion_authorizations
  add constraint account_deletion_authorizations_target_role_check
  check (target_role in ('user', 'admin', 'super_admin'));

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
  v_is_primary_owner boolean := false;
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

  v_is_primary_owner := private.is_primary_owner(p_admin_user_id);
  if v_admin_role = 'super_admin' and not v_is_primary_owner then
    raise exception 'primary_owner_required';
  end if;

  select p.role into v_target_role
  from public.profiles p
  where p.id = p_target_user_id;

  if v_target_role is null then raise exception 'user_not_found'; end if;
  if v_target_role = 'super_admin' and not v_is_primary_owner then raise exception 'cannot_modify_super_admin'; end if;
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
      pg_catalog.jsonb_build_object('auth_synced', true, 'primary_owner', v_is_primary_owner)
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

revoke all on function public.admin_apply_wallet_status(uuid, uuid, text, text)
from public, anon, authenticated;
grant execute on function public.admin_apply_wallet_status(uuid, uuid, text, text)
to service_role;

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
  v_is_primary_owner boolean := false;
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

  v_is_primary_owner := private.is_primary_owner(p_admin_user_id);
  if v_admin_role = 'super_admin' and not v_is_primary_owner then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'primary_owner_required');
  end if;

  select p.role, p.display_name
  into v_target_role, v_target_name
  from public.profiles p
  where p.id = p_target_user_id;

  if v_target_role is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if v_target_role = 'super_admin' and not v_is_primary_owner then
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
    target_user_id, actor_user_id, actor_role, target_role,
    expires_at, consumed_at, created_at
  ) values (
    p_target_user_id, p_admin_user_id, v_admin_role, v_target_role,
    now() + interval '2 minutes', null, now()
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
  v_is_primary_owner boolean := false;
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

  v_is_primary_owner := private.is_primary_owner(p_admin_user_id);
  if v_admin_role = 'super_admin' and not v_is_primary_owner then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'primary_owner_required');
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
  if v_target_role = 'super_admin' and not v_is_primary_owner then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'primary_owner_required');
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
    select 1 from public.admin_audit_logs a
    where a.target_user_id = p_target_user_id
      and a.action = 'ACCOUNT_DELETED'
  ) then
    perform private.write_admin_audit(
      p_admin_user_id,
      p_target_user_id,
      'ACCOUNT_DELETED',
      pg_catalog.jsonb_build_object('account_exists', true, 'target_role', v_target_role),
      pg_catalog.jsonb_build_object('account_exists', false),
      case when v_is_primary_owner
        then 'Konto durch Haupt-Owner dauerhaft gelöscht'
        else 'Konto durch Admin dauerhaft gelöscht'
      end,
      pg_catalog.jsonb_build_object(
        'auth_deleted', true,
        'ledger_anonymized', true,
        'actor_role', v_admin_role,
        'target_role', v_target_role,
        'primary_owner', v_is_primary_owner
      )
    );
  end if;

  delete from private.account_deletion_authorizations
  where target_user_id = p_target_user_id;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

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
  v_actor_is_primary_owner boolean := false;
begin
  select p.role into v_target_role
  from public.profiles p
  where p.id = old.id;

  select a.actor_user_id, p.role, w.status
  into v_actor_user_id, v_actor_role, v_actor_status
  from private.account_deletion_authorizations a
  join public.profiles p on p.id = a.actor_user_id
  join public.wallets w on w.user_id = a.actor_user_id
  where a.target_user_id = old.id
    and a.expires_at >= now()
    and a.consumed_at is null;

  v_actor_is_primary_owner := private.is_primary_owner(v_actor_user_id);

  if v_actor_user_id is null
     or v_actor_user_id = old.id
     or coalesce(v_actor_role, '') not in ('admin', 'super_admin')
     or coalesce(v_actor_status, '') <> 'active'
     or (v_actor_role = 'super_admin' and not v_actor_is_primary_owner) then
    raise exception using errcode = '42501', message = 'account_deletion_not_authorized';
  end if;

  if v_target_role = 'super_admin' and not v_actor_is_primary_owner then
    raise exception using errcode = '42501', message = 'owner_account_is_protected';
  end if;

  if v_target_role = 'admin' and v_actor_role <> 'super_admin' then
    raise exception using errcode = '42501', message = 'admin_account_is_protected';
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
revoke all on function private.protect_owner_auth_deletion()
from public, anon, authenticated;
