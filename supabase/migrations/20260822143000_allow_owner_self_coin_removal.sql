-- The Owner may remove coins from their own wallet. Normal Admins still cannot
-- remove their own coins, and no Admin can remove coins from the Owner.

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
  v_target_role text;
  v_pin_status text;
  v_transaction_id uuid;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  select p.role
  into v_admin_role
  from public.profiles p
  where p.id = v_admin_user_id;

  if p_amount is null or p_amount = 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_admin_amount');
  end if;

  if p_amount < 0 then
    select p.role
    into v_target_role
    from public.profiles p
    where p.id = p_target_user_id;

    if v_target_role is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found');
    end if;

    if p_target_user_id = v_admin_user_id and v_admin_role <> 'super_admin' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_remove_own_coins');
    end if;

    if v_target_role = 'super_admin'
       and not (p_target_user_id = v_admin_user_id and v_admin_role = 'super_admin') then
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

revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text)
from public, anon, authenticated;

grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text)
to authenticated;
