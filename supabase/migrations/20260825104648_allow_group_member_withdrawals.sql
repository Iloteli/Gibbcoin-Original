-- Every active group member may move coins from the shared wallet into their
-- own personal wallet. The server locks both balances and records the movement
-- atomically, so the group balance can never become negative.
create or replace function public.withdraw_group_coins(
  p_group_id uuid,
  p_amount bigint,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_member_role text;
  v_group_balance bigint;
  v_personal_wallet public.wallets%rowtype;
  v_member_label text;
  v_entry_id uuid;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if pg_catalog.char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;

  select m.role into v_member_role
  from public.group_wallet_members m
  where m.group_id = p_group_id and m.user_id = v_user_id
  for key share;
  if v_member_role is null then raise exception 'group_membership_required'; end if;

  -- Match the existing group-money functions' lock order: group first, wallet second.
  select g.balance into v_group_balance
  from public.group_wallets g
  where g.id = p_group_id
  for update;
  if v_group_balance is null then raise exception 'group_not_found'; end if;
  if v_group_balance < p_amount then raise exception 'insufficient_group_balance'; end if;

  select w.* into v_personal_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_personal_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_personal_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;

  select p.display_name into v_member_label
  from public.profiles p
  where p.id = v_user_id;

  update public.group_wallets g
  set balance = balance - p_amount, updated_at = pg_catalog.now()
  where g.id = p_group_id;

  update public.wallets w
  set balance = balance + p_amount, updated_at = pg_catalog.now()
  where w.id = v_personal_wallet.id;

  insert into public.group_wallet_entries(
    group_id,
    actor_user_id,
    recipient_user_id,
    actor_label,
    recipient_label,
    kind,
    amount,
    note
  ) values (
    p_group_id,
    v_user_id,
    v_user_id,
    coalesce(v_member_label, 'Mitglied'),
    coalesce(v_member_label, 'Mitglied'),
    'payout',
    p_amount,
    nullif(pg_catalog.btrim(coalesce(p_note, '')), '')
  )
  returning id into v_entry_id;

  return v_entry_id;
end;
$$;

revoke all on function public.withdraw_group_coins(uuid, bigint, text)
from public, anon, authenticated;

grant execute on function public.withdraw_group_coins(uuid, bigint, text)
to authenticated;
