-- Browser clients only need reads. All balance, role and ledger writes go through
-- narrowly scoped SECURITY DEFINER functions that validate auth.uid() server-side.
revoke insert, update, delete, truncate, references, trigger
on table public.profiles, public.wallets, public.transactions
from anon, authenticated;

revoke all
on table public.admin_audit_logs
from anon, authenticated;

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then
    raise exception 'authentication_required';
  end if;

  select p.role, w.status
  into v_role, v_wallet_status
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;

  if v_role not in ('admin', 'super_admin') then
    raise exception 'admin_required';
  end if;
  if v_wallet_status <> 'active' then
    raise exception 'account_locked';
  end if;

  return v_user_id;
end;
$$;

revoke all on function private.require_admin() from public, anon, authenticated;
