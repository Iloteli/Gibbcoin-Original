-- Complete the protected Admin controls and add server-authoritative
-- five-card draw poker. Wallet balances and the immutable ledger remain the
-- source of truth; resetting statistics only moves a per-Admin checkpoint.

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
    p_owner_user_id, p_target_user_id, p_pin
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
    p_owner_user_id, p_target_user_id
  );
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
begin
  select p.role into v_target_role
  from public.profiles p
  where p.id = old.id;

  if v_target_role = 'super_admin' then
    raise exception using errcode = '42501', message = 'owner_account_is_protected';
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
    raise exception using errcode = '42501', message = 'account_deletion_not_authorized';
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

-- Both Admins and the Owner may burn coins from their own wallet. An Admin may
-- never touch the Owner wallet, while the Owner may only touch it as themself.
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
    select p.role into v_target_role
    from public.profiles p
    where p.id = p_target_user_id;

    if v_target_role is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found');
    end if;
    if v_target_role = 'super_admin' and p_target_user_id <> v_admin_user_id then
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

-- Each Admin has an independent display checkpoint. No ledger row or balance
-- is deleted when these counters are reset.
alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;
alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED',
      'STATS_RESET'
    )
  );

create table if not exists private.admin_coin_stats_resets (
  admin_user_id uuid primary key references auth.users(id) on delete cascade,
  reset_at timestamptz not null,
  updated_at timestamptz not null default now()
);

revoke all on table private.admin_coin_stats_resets
from public, anon, authenticated;

create or replace function public.admin_coin_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_since timestamptz;
  v_given bigint := 0;
  v_removed bigint := 0;
begin
  select r.reset_at into v_since
  from private.admin_coin_stats_resets r
  where r.admin_user_id = v_admin_user_id;

  select
    coalesce(sum(case when a.action = 'ADMIN_MINT'
      then greatest(coalesce((a.new_value ->> 'amount')::bigint, 0), 0)
      else 0 end), 0)::bigint,
    coalesce(sum(case when a.action = 'ADMIN_BURN'
      then pg_catalog.abs(least(coalesce((a.new_value ->> 'amount')::bigint, 0), 0))
      else 0 end), 0)::bigint
  into v_given, v_removed
  from public.admin_audit_logs a
  where a.admin_user_id = v_admin_user_id
    and a.action in ('ADMIN_MINT', 'ADMIN_BURN')
    and (v_since is null or a.created_at >= v_since);

  return pg_catalog.jsonb_build_object(
    'given', v_given,
    'removed', v_removed,
    'since', v_since
  );
end;
$$;

create or replace function public.admin_reset_coin_stats(p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb;
  v_reset_at timestamptz;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_before := public.admin_coin_stats();
  v_reset_at := pg_catalog.clock_timestamp();

  insert into private.admin_coin_stats_resets (admin_user_id, reset_at, updated_at)
  values (v_admin_user_id, v_reset_at, v_reset_at)
  on conflict (admin_user_id) do update
  set reset_at = excluded.reset_at,
      updated_at = excluded.updated_at;

  perform private.write_admin_audit(
    v_admin_user_id,
    v_admin_user_id,
    'STATS_RESET',
    v_before,
    pg_catalog.jsonb_build_object('given', 0, 'removed', 0, 'since', v_reset_at),
    'Persönliche Coin-Statistik zurückgesetzt',
    pg_catalog.jsonb_build_object('ledger_preserved', true, 'balances_preserved', true)
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'given', 0,
    'removed', 0,
    'since', v_reset_at
  );
end;
$$;

revoke all on function public.admin_coin_stats()
from public, anon, authenticated;
grant execute on function public.admin_coin_stats()
to authenticated;
revoke all on function public.admin_reset_coin_stats(text)
from public, anon, authenticated;
grant execute on function public.admin_reset_coin_stats(text)
to authenticated;

-- Poker is a server-authoritative five-card draw game. Card codes are 0..51;
-- rank = card % 13 + 2 and suit = card / 13.
alter table public.game_settings
  drop constraint if exists game_settings_game_key_check;
alter table public.game_settings
  add constraint game_settings_game_key_check check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack',
    'dice_duel', 'high_card', 'poker'
  ));

alter table public.game_rounds
  drop constraint if exists game_rounds_game_key_check;
alter table public.game_rounds
  add constraint game_rounds_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker'
  ));
alter table public.game_rounds
  drop constraint if exists game_rounds_payout_check;
alter table public.game_rounds
  add constraint game_rounds_payout_check check (payout between 0 and 1000000);

insert into public.game_settings (game_key, label, sort_order)
values ('poker', '5-Karten-Poker', 60)
on conflict (game_key) do update
set label = excluded.label,
    sort_order = excluded.sort_order;

create table if not exists public.poker_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  wager bigint not null check (wager between 1 and 1000),
  cards smallint[] not null check (
    pg_catalog.cardinality(cards) = 5
    and cards[1] between 0 and 51
    and cards[2] between 0 and 51
    and cards[3] between 0 and 51
    and cards[4] between 0 and 51
    and cards[5] between 0 and 51
    and cards[1] <> all(cards[2:5])
    and cards[2] <> all(cards[3:5])
    and cards[3] <> all(cards[4:5])
    and cards[4] <> cards[5]
  ),
  status text not null default 'active' check (status in ('active', 'finished')),
  hand_name text,
  multiplier integer not null default 0 check (multiplier between 0 and 250),
  payout bigint not null default 0 check (payout between 0 and 250000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists poker_one_active_session_per_user
  on public.poker_sessions (user_id)
  where status = 'active';
create index if not exists poker_sessions_user_created_idx
  on public.poker_sessions (user_id, created_at desc);

alter table public.poker_sessions enable row level security;
revoke all on table public.poker_sessions from public, anon, authenticated;

create or replace function private.poker_draw_card(p_excluded smallint[])
returns smallint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_card smallint;
  v_attempt integer;
begin
  for v_attempt in 1..200 loop
    v_card := private.game_random(52)::smallint;
    if not (v_card = any(coalesce(p_excluded, array[]::smallint[]))) then
      return v_card;
    end if;
  end loop;
  raise exception 'poker_deck_error';
end;
$$;

create or replace function private.poker_hand(p_cards smallint[])
returns jsonb
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_ranks integer[];
  v_suits integer[];
  v_distinct integer;
  v_max_count integer;
  v_pair_count integer;
  v_pair_rank integer;
  v_flush boolean;
  v_straight boolean;
  v_royal boolean;
  v_name text;
  v_multiplier integer;
begin
  if pg_catalog.cardinality(p_cards) <> 5
     or exists (select 1 from pg_catalog.unnest(p_cards) c where c < 0 or c > 51)
     or (select count(distinct c) from pg_catalog.unnest(p_cards) c) <> 5 then
    raise exception 'invalid_poker_hand';
  end if;

  select pg_catalog.array_agg((c % 13) + 2 order by (c % 13) + 2),
         pg_catalog.array_agg(c / 13 order by c / 13)
  into v_ranks, v_suits
  from pg_catalog.unnest(p_cards) c;

  select count(distinct r), max(n), count(*) filter (where n = 2),
         max(r) filter (where n = 2)
  into v_distinct, v_max_count, v_pair_count, v_pair_rank
  from (
    select r, count(*)::integer as n
    from pg_catalog.unnest(v_ranks) r
    group by r
  ) counts;

  v_flush := v_suits[1] = v_suits[5];
  v_straight := (v_distinct = 5 and v_ranks[5] - v_ranks[1] = 4)
    or v_ranks = array[2, 3, 4, 5, 14];
  v_royal := v_ranks = array[10, 11, 12, 13, 14];

  if v_flush and v_straight and v_royal then
    v_name := 'Royal Flush'; v_multiplier := 250;
  elsif v_flush and v_straight then
    v_name := 'Straight Flush'; v_multiplier := 50;
  elsif v_max_count = 4 then
    v_name := 'Vierling'; v_multiplier := 25;
  elsif v_max_count = 3 and v_pair_count = 1 then
    v_name := 'Full House'; v_multiplier := 9;
  elsif v_flush then
    v_name := 'Flush'; v_multiplier := 6;
  elsif v_straight then
    v_name := 'Strasse'; v_multiplier := 4;
  elsif v_max_count = 3 then
    v_name := 'Drilling'; v_multiplier := 3;
  elsif v_pair_count = 2 then
    v_name := 'Zwei Paare'; v_multiplier := 2;
  elsif v_pair_count = 1 and v_pair_rank >= 11 then
    v_name := 'Buben oder besser'; v_multiplier := 1;
  else
    v_name := 'Keine Gewinnhand'; v_multiplier := 0;
  end if;

  return pg_catalog.jsonb_build_object('hand', v_name, 'multiplier', v_multiplier);
end;
$$;

revoke all on function private.poker_draw_card(smallint[]) from public, anon, authenticated;
revoke all on function private.poker_hand(smallint[]) from public, anon, authenticated;

create or replace function public.get_game_center_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_balance bigint;
  v_settings jsonb;
  v_rounds jsonb;
  v_blackjack jsonb;
  v_poker jsonb;
begin
  select w.balance into v_balance from public.wallets w where w.user_id = v_user_id;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'game_key', s.game_key, 'label', s.label, 'enabled', s.enabled,
    'updated_at', s.updated_at
  ) order by s.sort_order), '[]'::jsonb)
  into v_settings from public.game_settings s;

  select coalesce(pg_catalog.jsonb_agg(row_data order by created_at desc), '[]'::jsonb)
  into v_rounds
  from (
    select r.created_at, pg_catalog.jsonb_build_object(
      'id', r.id, 'game_key', r.game_key, 'choice', r.choice,
      'wager', r.wager, 'payout', r.payout, 'result', r.result,
      'created_at', r.created_at
    ) as row_data
    from public.game_rounds r
    where r.user_id = v_user_id
    order by r.created_at desc
    limit 8
  ) recent;

  select pg_catalog.jsonb_build_object(
    'id', b.id, 'wager', b.wager,
    'player_cards', pg_catalog.to_jsonb(b.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(b.dealer_cards[1:1]),
    'dealer_hidden', true, 'status', b.status, 'payout', b.payout,
    'player_score', private.blackjack_score(b.player_cards)
  ) into v_blackjack
  from public.blackjack_sessions b
  where b.user_id = v_user_id and b.status = 'active'
  order by b.created_at desc limit 1;

  select pg_catalog.jsonb_build_object(
    'id', p.id, 'wager', p.wager, 'cards', pg_catalog.to_jsonb(p.cards),
    'status', p.status, 'payout', p.payout
  ) into v_poker
  from public.poker_sessions p
  where p.user_id = v_user_id and p.status = 'active'
  order by p.created_at desc limit 1;

  return pg_catalog.jsonb_build_object(
    'balance', v_balance,
    'settings', v_settings,
    'recent_rounds', v_rounds,
    'blackjack', v_blackjack,
    'poker', v_poker
  );
end;
$$;

create or replace function public.start_poker(p_wager bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_cards smallint[] := array[]::smallint[];
  v_card smallint;
  v_index integer;
  v_session_id uuid;
begin
  if p_wager is null or p_wager < 1 or p_wager > 1000 then
    raise exception 'invalid_game_wager';
  end if;
  if not private.game_is_enabled('poker') then raise exception 'game_disabled'; end if;
  if exists (
    select 1 from public.poker_sessions p
    where p.user_id = v_user_id and p.status = 'active'
  ) then raise exception 'poker_session_active';
  end if;
  if exists (
    select 1 from public.poker_sessions p
    where p.user_id = v_user_id
      and p.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast';
  end if;

  select w.* into v_wallet from public.wallets w
  where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;

  for v_index in 1..5 loop
    v_card := private.poker_draw_card(v_cards);
    v_cards := pg_catalog.array_append(v_cards, v_card);
  end loop;

  update public.wallets
  set balance = balance - p_wager, updated_at = now()
  where id = v_wallet.id;
  perform private.append_transaction(
    v_user_id, null, p_wager, 'GAME_ENTRY', 'Game Center · Poker · Einsatz'
  );

  insert into public.poker_sessions (user_id, wager, cards)
  values (v_user_id, p_wager, v_cards)
  returning id into v_session_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session_id, 'game_key', 'poker',
    'wager', p_wager, 'cards', pg_catalog.to_jsonb(v_cards),
    'status', 'active', 'payout', 0,
    'balance', v_wallet.balance - p_wager
  );
end;
$$;

create or replace function public.poker_draw(
  p_session_id uuid,
  p_hold_positions smallint[]
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_session public.poker_sessions%rowtype;
  v_initial smallint[];
  v_final smallint[] := array[]::smallint[];
  v_excluded smallint[];
  v_card smallint;
  v_position integer;
  v_hand jsonb;
  v_hand_name text;
  v_multiplier integer;
  v_payout bigint;
  v_round_id uuid;
begin
  p_hold_positions := coalesce(p_hold_positions, array[]::smallint[]);
  if exists (
    select 1 from pg_catalog.unnest(p_hold_positions) p
    where p < 1 or p > 5
  ) or (select count(*) from pg_catalog.unnest(p_hold_positions))
       <> (select count(distinct p) from pg_catalog.unnest(p_hold_positions) p) then
    raise exception 'invalid_poker_hold';
  end if;

  select p.* into v_session
  from public.poker_sessions p
  where p.id = p_session_id and p.user_id = v_user_id
  for update;
  if v_session.id is null then raise exception 'poker_session_not_found'; end if;
  if v_session.status <> 'active' then raise exception 'poker_session_finished'; end if;

  v_initial := v_session.cards;
  v_excluded := v_initial;
  for v_position in 1..5 loop
    if v_position = any(p_hold_positions) then
      v_final := pg_catalog.array_append(v_final, v_initial[v_position]);
    else
      v_card := private.poker_draw_card(v_excluded || v_final);
      v_final := pg_catalog.array_append(v_final, v_card);
    end if;
  end loop;

  v_hand := private.poker_hand(v_final);
  v_hand_name := v_hand ->> 'hand';
  v_multiplier := (v_hand ->> 'multiplier')::integer;
  v_payout := v_session.wager * v_multiplier;

  select w.* into v_wallet from public.wallets w
  where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  if v_payout > 0 then
    update public.wallets
    set balance = balance + v_payout, updated_at = now()
    where id = v_wallet.id;
    perform private.append_transaction(
      null, v_user_id, v_payout, 'GAME_REWARD',
      'Game Center · Poker · ' || v_hand_name
    );
  end if;

  update public.poker_sessions
  set cards = v_final, status = 'finished', hand_name = v_hand_name,
      multiplier = v_multiplier, payout = v_payout, updated_at = now()
  where id = v_session.id;

  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (
    v_user_id, 'poker', 'draw', v_session.wager, v_payout,
    pg_catalog.jsonb_build_object(
      'cards', v_final, 'held', p_hold_positions,
      'hand', v_hand_name, 'multiplier', v_multiplier
    )
  ) returning id into v_round_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'round_id', v_round_id,
    'game_key', 'poker', 'wager', v_session.wager,
    'cards', pg_catalog.to_jsonb(v_final), 'status', 'finished',
    'hand', v_hand_name, 'multiplier', v_multiplier,
    'payout', v_payout, 'net', v_payout - v_session.wager,
    'result', pg_catalog.jsonb_build_object(
      'cards', v_final, 'held', p_hold_positions,
      'hand', v_hand_name, 'multiplier', v_multiplier
    ),
    'balance', v_wallet.balance + v_payout
  );
end;
$$;

revoke all on function public.get_game_center_state() from public, anon, authenticated;
revoke all on function public.start_poker(bigint) from public, anon, authenticated;
revoke all on function public.poker_draw(uuid, smallint[]) from public, anon, authenticated;
grant execute on function public.get_game_center_state() to authenticated;
grant execute on function public.start_poker(bigint) to authenticated;
grant execute on function public.poker_draw(uuid, smallint[]) to authenticated;
