create table private.admin_pins (
  admin_user_id uuid primary key references auth.users(id) on delete cascade,
  pin_hash text not null,
  failed_attempts smallint not null default 0 check (failed_attempts between 0 and 5),
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

revoke all on table private.admin_pins from public, anon, authenticated;

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
      'ADMIN_PIN_SET',
      'ADMIN_PIN_CHANGED'
    )
  );

create or replace function private.check_admin_pin(
  p_admin_user_id uuid,
  p_pin text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pin private.admin_pins%rowtype;
  v_failed_attempts smallint;
  v_matches boolean := false;
begin
  select ap.* into v_pin
  from private.admin_pins ap
  where ap.admin_user_id = p_admin_user_id
  for update;

  if v_pin.admin_user_id is null then
    return 'not_set';
  end if;
  if v_pin.locked_until is not null and v_pin.locked_until > now() then
    return 'locked';
  end if;

  v_matches := coalesce(p_pin, '') ~ '^[0-9]{4}$'
    and extensions.crypt(coalesce(p_pin, ''), v_pin.pin_hash) = v_pin.pin_hash;

  if v_matches then
    update private.admin_pins
    set failed_attempts = 0, locked_until = null, updated_at = now()
    where admin_user_id = p_admin_user_id;
    return 'ok';
  end if;

  v_failed_attempts := least(v_pin.failed_attempts + 1, 5);
  update private.admin_pins
  set failed_attempts = v_failed_attempts,
      locked_until = case when v_failed_attempts >= 5 then now() + interval '15 minutes' else null end,
      updated_at = now()
  where admin_user_id = p_admin_user_id;

  return case when v_failed_attempts >= 5 then 'locked' else 'invalid' end;
end;
$$;

revoke all on function private.check_admin_pin(uuid, text) from public, anon, authenticated;

create or replace function public.admin_pin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin private.admin_pins%rowtype;
begin
  select ap.* into v_pin
  from private.admin_pins ap
  where ap.admin_user_id = v_admin_user_id;

  return pg_catalog.jsonb_build_object(
    'has_pin', v_pin.admin_user_id is not null,
    'locked_until', case
      when v_pin.locked_until is not null and v_pin.locked_until > now() then v_pin.locked_until
      else null
    end
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
  v_pin_status text;
  v_transaction_id uuid;
begin
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_transaction_id := public.admin_adjust_balance(p_target_user_id, p_amount, p_reason);
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id
  );
end;
$$;

create or replace function public.admin_set_balance_secure(
  p_target_user_id uuid,
  p_new_balance bigint,
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
  v_pin_status text;
  v_transaction_id uuid;
begin
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_transaction_id := public.admin_set_balance(p_target_user_id, p_new_balance, p_reason);
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id
  );
end;
$$;

-- Die alten Admin-Mutationsendpunkte bleiben intern verfügbar, sind aus dem
-- Browser aber nicht mehr aufrufbar. So gibt es keinen PIN-Bypass.
revoke all on function public.admin_adjust_balance(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.admin_set_balance(uuid, bigint, text) from public, anon, authenticated;
grant execute on function public.admin_adjust_balance(uuid, bigint, text) to service_role;
grant execute on function public.admin_set_balance(uuid, bigint, text) to service_role;

revoke all on function public.admin_pin_status() from public, anon;
grant execute on function public.admin_pin_status() to authenticated;

revoke all on function public.admin_set_pin(text, text) from public, anon;
grant execute on function public.admin_set_pin(text, text) to authenticated;

revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text) from public, anon;
grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text) to authenticated;

revoke all on function public.admin_set_balance_secure(uuid, bigint, text, text) from public, anon;
grant execute on function public.admin_set_balance_secure(uuid, bigint, text, text) to authenticated;
