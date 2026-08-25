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
