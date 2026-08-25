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
    'failed_attempts', coalesce(v_pin.failed_attempts, 0),
    'locked_until', case
      when v_pin.locked_until is not null and v_pin.locked_until > now() then v_pin.locked_until
      else null
    end
  );
end;
$$;

create or replace function public.owner_reset_admin_pin(
  p_new_pin text
)
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

revoke all on function public.admin_pin_status() from public, anon, authenticated;
grant execute on function public.admin_pin_status() to authenticated;

revoke all on function public.owner_reset_admin_pin(text) from public, anon, authenticated;
grant execute on function public.owner_reset_admin_pin(text) to authenticated;
