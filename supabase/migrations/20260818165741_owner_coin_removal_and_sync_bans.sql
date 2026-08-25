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
