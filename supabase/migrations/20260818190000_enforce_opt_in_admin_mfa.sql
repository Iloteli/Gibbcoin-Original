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
