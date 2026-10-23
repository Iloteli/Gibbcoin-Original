-- GIBB Coin: neues Supabase einrichten – Teil 2 von 5
-- Im SQL Editor des NEUEN Projekts der Reihe nach ausführen (Teil 1, dann 2, …). Jeden Teil nur einmal.

-- ===================== 20260824122242_complete_admin_controls_and_poker.sql =====================
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


-- ===================== 20260824125717_add_dino_run_rewards.sql =====================
-- Dino Run has no entry fee. Every new, server-accepted 1,000-point
-- milestone credits exactly 100 GIBB to the member's normal wallet.
alter table public.game_settings
  drop constraint if exists game_settings_game_key_check;
alter table public.game_settings
  add constraint game_settings_game_key_check check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack',
    'dice_duel', 'high_card', 'poker', 'dino_run'
  ));

alter table public.game_rounds
  drop constraint if exists game_rounds_game_key_check;
alter table public.game_rounds
  add constraint game_rounds_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card',
    'poker', 'dino_run'
  ));
alter table public.game_rounds
  drop constraint if exists game_rounds_wager_check;
alter table public.game_rounds
  add constraint game_rounds_wager_check check (wager between 0 and 1000);

insert into public.game_settings (game_key, label, sort_order)
values ('dino_run', 'Dino Run', 70)
on conflict (game_key) do update
set label = excluded.label,
    sort_order = excluded.sort_order;

create table public.dino_run_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  seed integer not null check (seed between 0 and 999999),
  score integer not null default 0 check (score between 0 and 1000000),
  rewarded_milestones integer not null default 0 check (rewarded_milestones between 0 and 1000),
  reward_total bigint not null default 0 check (reward_total between 0 and 100000),
  status text not null default 'active' check (status in ('active', 'finished', 'abandoned')),
  started_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  finished_at timestamptz,
  constraint dino_run_reward_matches_milestones
    check (reward_total = rewarded_milestones::bigint * 100)
);

create unique index dino_run_one_active_session_per_user
  on public.dino_run_sessions (user_id)
  where status = 'active';
create index dino_run_sessions_user_started_idx
  on public.dino_run_sessions (user_id, started_at desc);

alter table public.dino_run_sessions enable row level security;
create policy dino_run_sessions_no_direct_read
  on public.dino_run_sessions for select to authenticated using (false);
revoke all on table public.dino_run_sessions from public, anon, authenticated;

create or replace function public.start_dino_run()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_previous public.dino_run_sessions%rowtype;
  v_session public.dino_run_sessions%rowtype;
begin
  if not private.game_is_enabled('dino_run') then
    raise exception 'game_disabled';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 188447)::bigint
  );

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;

  select d.* into v_previous
  from public.dino_run_sessions d
  where d.user_id = v_user_id and d.status = 'active'
  order by d.started_at desc
  limit 1
  for update;

  if v_previous.id is not null then
    update public.dino_run_sessions
    set status = 'abandoned', updated_at = pg_catalog.clock_timestamp(),
        finished_at = pg_catalog.clock_timestamp()
    where id = v_previous.id;

    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (
      v_user_id, 'dino_run', 'abandoned', 0, v_previous.reward_total,
      pg_catalog.jsonb_build_object(
        'score', v_previous.score,
        'milestones', v_previous.rewarded_milestones,
        'status', 'abandoned'
      )
    );
  end if;

  insert into public.dino_run_sessions (user_id, seed)
  values (v_user_id, private.game_random(1000000))
  returning * into v_session;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'id', v_session.id,
    'seed', v_session.seed,
    'score', 0,
    'reward', 0,
    'total_reward', 0,
    'next_reward_at', 1000,
    'balance', v_wallet.balance,
    'status', 'active',
    'game_key', 'dino_run'
  );
end;
$$;

create or replace function public.sync_dino_run(
  p_session_id uuid,
  p_score integer,
  p_finished boolean default false
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
  v_session public.dino_run_sessions%rowtype;
  v_elapsed_seconds numeric;
  v_max_score integer;
  v_milestones integer;
  v_new_milestones integer;
  v_reward bigint := 0;
  v_status text;
begin
  if p_session_id is null or p_score is null or p_score < 0 or p_score > 1000000 then
    raise exception 'invalid_dino_score';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 188447)::bigint
  );

  select d.* into v_session
  from public.dino_run_sessions d
  where d.id = p_session_id and d.user_id = v_user_id
  for update;
  if v_session.id is null then raise exception 'dino_session_not_found'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  if v_session.status <> 'active' then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'id', v_session.id,
      'score', v_session.score,
      'reward', 0,
      'total_reward', v_session.reward_total,
      'next_reward_at', (v_session.rewarded_milestones + 1) * 1000,
      'balance', v_wallet.balance,
      'status', v_session.status,
      'game_key', 'dino_run'
    );
  end if;

  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if p_score < v_session.score then raise exception 'dino_score_reversed'; end if;

  v_elapsed_seconds := pg_catalog.date_part(
    'epoch', pg_catalog.clock_timestamp() - v_session.started_at
  );
  if v_elapsed_seconds < 0 then v_elapsed_seconds := 0; end if;
  v_max_score := pg_catalog.floor(v_elapsed_seconds * 55)::integer + 125;
  if p_score > v_max_score then raise exception 'dino_score_too_fast'; end if;

  v_milestones := p_score / 1000;
  v_new_milestones := v_milestones - v_session.rewarded_milestones;
  if v_new_milestones > 0 then
    v_reward := v_new_milestones::bigint * 100;
    update public.wallets
    set balance = balance + v_reward, updated_at = pg_catalog.clock_timestamp()
    where id = v_wallet.id;
    perform private.append_transaction(
      null,
      v_user_id,
      v_reward,
      'GAME_REWARD',
      'Game Center · Dino Run · ' || v_milestones || ' × 1’000 Punkte'
    );
  end if;

  v_status := case
    when coalesce(p_finished, false) or v_elapsed_seconds > 1800 then 'finished'
    else 'active'
  end;

  update public.dino_run_sessions
  set score = p_score,
      rewarded_milestones = v_milestones,
      reward_total = reward_total + v_reward,
      status = v_status,
      updated_at = pg_catalog.clock_timestamp(),
      finished_at = case when v_status = 'finished' then pg_catalog.clock_timestamp() else null end
  where id = v_session.id
  returning * into v_session;

  if v_status = 'finished' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (
      v_user_id, 'dino_run', 'run', 0, v_session.reward_total,
      pg_catalog.jsonb_build_object(
        'score', v_session.score,
        'milestones', v_session.rewarded_milestones,
        'status', 'finished'
      )
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'id', v_session.id,
    'score', v_session.score,
    'reward', v_reward,
    'total_reward', v_session.reward_total,
    'next_reward_at', (v_session.rewarded_milestones + 1) * 1000,
    'balance', v_wallet.balance + v_reward,
    'status', v_session.status,
    'game_key', 'dino_run'
  );
end;
$$;

revoke all on function public.start_dino_run() from public, anon, authenticated;
revoke all on function public.sync_dino_run(uuid, integer, boolean) from public, anon, authenticated;
grant execute on function public.start_dino_run() to authenticated;
grant execute on function public.sync_dino_run(uuid, integer, boolean) to authenticated;


-- ===================== 20260824125832_set_starting_balance_to_ten.sql =====================
-- New accounts start with 10 GIBB. Existing wallets are deliberately unchanged.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, email, avatar_url)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      pg_catalog.split_part(coalesce(new.email, 'GIBB Benutzer'), '@', 1)
    ),
    coalesce(new.email, ''),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  )
  on conflict (id) do nothing;

  insert into public.wallets (user_id, balance)
  values (new.id, 10)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;


-- ===================== 20260825063808_charge_dino_run_entry.sql =====================
-- Existing runs were free and keep wager = 0. Every newly started Dino Run
-- costs exactly 150 GIBB and records that entry in the immutable ledger.
alter table public.dino_run_sessions
  add column wager bigint not null default 0;
alter table public.dino_run_sessions
  add constraint dino_run_sessions_wager_check check (wager in (0, 150));
alter table public.dino_run_sessions
  alter column wager set default 150;

create or replace function public.start_dino_run()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_entry_cost constant bigint := 150;
  v_wallet public.wallets%rowtype;
  v_previous public.dino_run_sessions%rowtype;
  v_session public.dino_run_sessions%rowtype;
begin
  if not private.game_is_enabled('dino_run') then
    raise exception 'game_disabled';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 188447)::bigint
  );

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < v_entry_cost then raise exception 'insufficient_balance'; end if;

  select d.* into v_previous
  from public.dino_run_sessions d
  where d.user_id = v_user_id and d.status = 'active'
  order by d.started_at desc
  limit 1
  for update;

  if v_previous.id is not null then
    update public.dino_run_sessions
    set status = 'abandoned', updated_at = pg_catalog.clock_timestamp(),
        finished_at = pg_catalog.clock_timestamp()
    where id = v_previous.id;

    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (
      v_user_id, 'dino_run', 'abandoned', v_previous.wager, v_previous.reward_total,
      pg_catalog.jsonb_build_object(
        'score', v_previous.score,
        'milestones', v_previous.rewarded_milestones,
        'status', 'abandoned'
      )
    );
  end if;

  update public.wallets
  set balance = balance - v_entry_cost,
      updated_at = pg_catalog.clock_timestamp()
  where id = v_wallet.id;
  perform private.append_transaction(
    v_user_id,
    null,
    v_entry_cost,
    'GAME_ENTRY',
    'Game Center · Dino Run · Eintritt'
  );

  insert into public.dino_run_sessions (user_id, seed, wager)
  values (v_user_id, private.game_random(1000000), v_entry_cost)
  returning * into v_session;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'id', v_session.id,
    'seed', v_session.seed,
    'score', 0,
    'wager', v_session.wager,
    'reward', 0,
    'total_reward', 0,
    'next_reward_at', 1000,
    'balance', v_wallet.balance - v_entry_cost,
    'status', 'active',
    'game_key', 'dino_run'
  );
end;
$$;

create or replace function public.sync_dino_run(
  p_session_id uuid,
  p_score integer,
  p_finished boolean default false
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
  v_session public.dino_run_sessions%rowtype;
  v_elapsed_seconds numeric;
  v_max_score integer;
  v_milestones integer;
  v_new_milestones integer;
  v_reward bigint := 0;
  v_status text;
begin
  if p_session_id is null or p_score is null or p_score < 0 or p_score > 1000000 then
    raise exception 'invalid_dino_score';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 188447)::bigint
  );

  select d.* into v_session
  from public.dino_run_sessions d
  where d.id = p_session_id and d.user_id = v_user_id
  for update;
  if v_session.id is null then raise exception 'dino_session_not_found'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  if v_session.status <> 'active' then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'id', v_session.id,
      'score', v_session.score,
      'wager', v_session.wager,
      'reward', 0,
      'total_reward', v_session.reward_total,
      'next_reward_at', (v_session.rewarded_milestones + 1) * 1000,
      'balance', v_wallet.balance,
      'status', v_session.status,
      'game_key', 'dino_run'
    );
  end if;

  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if p_score < v_session.score then raise exception 'dino_score_reversed'; end if;

  v_elapsed_seconds := pg_catalog.date_part(
    'epoch', pg_catalog.clock_timestamp() - v_session.started_at
  );
  if v_elapsed_seconds < 0 then v_elapsed_seconds := 0; end if;
  v_max_score := pg_catalog.floor(v_elapsed_seconds * 55)::integer + 125;
  if p_score > v_max_score then raise exception 'dino_score_too_fast'; end if;

  v_milestones := p_score / 1000;
  v_new_milestones := v_milestones - v_session.rewarded_milestones;
  if v_new_milestones > 0 then
    v_reward := v_new_milestones::bigint * 100;
    update public.wallets
    set balance = balance + v_reward, updated_at = pg_catalog.clock_timestamp()
    where id = v_wallet.id;
    perform private.append_transaction(
      null,
      v_user_id,
      v_reward,
      'GAME_REWARD',
      'Game Center · Dino Run · ' || v_milestones || ' × 1’000 Punkte'
    );
  end if;

  v_status := case
    when coalesce(p_finished, false) or v_elapsed_seconds > 1800 then 'finished'
    else 'active'
  end;

  update public.dino_run_sessions
  set score = p_score,
      rewarded_milestones = v_milestones,
      reward_total = reward_total + v_reward,
      status = v_status,
      updated_at = pg_catalog.clock_timestamp(),
      finished_at = case when v_status = 'finished' then pg_catalog.clock_timestamp() else null end
  where id = v_session.id
  returning * into v_session;

  if v_status = 'finished' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (
      v_user_id, 'dino_run', 'run', v_session.wager, v_session.reward_total,
      pg_catalog.jsonb_build_object(
        'score', v_session.score,
        'milestones', v_session.rewarded_milestones,
        'status', 'finished'
      )
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'id', v_session.id,
    'score', v_session.score,
    'wager', v_session.wager,
    'reward', v_reward,
    'total_reward', v_session.reward_total,
    'next_reward_at', (v_session.rewarded_milestones + 1) * 1000,
    'balance', v_wallet.balance + v_reward,
    'status', v_session.status,
    'game_key', 'dino_run'
  );
end;
$$;

revoke all on function public.start_dino_run() from public, anon, authenticated;
revoke all on function public.sync_dino_run(uuid, integer, boolean) from public, anon, authenticated;
grant execute on function public.start_dino_run() to authenticated;
grant execute on function public.sync_dino_run(uuid, integer, boolean) to authenticated;


-- ===================== 20260825065459_fix_new_account_username.sql =====================
-- Registration failed because profiles.username is required in production,
-- while the signup trigger only inserted display_name, email and avatar_url.
-- Keep the column reproducible and always generate a valid, unique username.
alter table public.profiles
  add column if not exists username text;

update public.profiles p
set username = 'u' || pg_catalog.left(
  pg_catalog.replace(p.id::text, '-', ''),
  23
)
where p.username is null;

alter table public.profiles
  alter column username set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.profiles'::pg_catalog.regclass
      and c.conname = 'profiles_username_format_check'
  ) then
    alter table public.profiles
      add constraint profiles_username_format_check
      check (username ~ '^[a-z0-9][a-z0-9._-]{2,23}$');
  end if;
end;
$$;

create unique index if not exists profiles_username_lower_unique
  on public.profiles (pg_catalog.lower(username));

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email_name text := pg_catalog.lower(
    pg_catalog.split_part(coalesce(new.email, ''), '@', 1)
  );
  v_username text;
  v_display_name text;
begin
  v_username := pg_catalog.lower(pg_catalog.btrim(coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    v_email_name,
    ''
  )));
  v_username := pg_catalog.regexp_replace(v_username, '[^a-z0-9._-]+', '-', 'g');
  v_username := pg_catalog.regexp_replace(v_username, '^[^a-z0-9]+', '', 'g');
  v_username := pg_catalog.left(v_username, 24);

  if pg_catalog.char_length(v_username) < 3 then
    v_username := 'gibb_user';
  end if;

  if exists (
    select 1
    from public.profiles p
    where pg_catalog.lower(p.username) = v_username
  ) then
    v_username := pg_catalog.left(v_username, 15)
      || '_'
      || pg_catalog.left(pg_catalog.replace(new.id::text, '-', ''), 8);
  end if;

  v_display_name := pg_catalog.btrim(coalesce(
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(v_email_name, ''),
    v_username
  ));
  if pg_catalog.char_length(v_display_name) < 2 then
    v_display_name := 'GIBB Benutzer';
  end if;
  v_display_name := pg_catalog.left(v_display_name, 60);

  begin
    insert into public.profiles (id, username, display_name, email, avatar_url)
    values (
      new.id,
      v_username,
      v_display_name,
      coalesce(new.email, ''),
      nullif(new.raw_user_meta_data ->> 'avatar_url', '')
    )
    on conflict (id) do nothing;
  exception
    when unique_violation then
      -- A concurrent signup may claim the email-derived name. The UUID-based
      -- fallback remains valid and unique to this account.
      v_username := 'u' || pg_catalog.left(
        pg_catalog.replace(new.id::text, '-', ''),
        23
      );
      insert into public.profiles (id, username, display_name, email, avatar_url)
      values (
        new.id,
        v_username,
        v_display_name,
        coalesce(new.email, ''),
        nullif(new.raw_user_meta_data ->> 'avatar_url', '')
      )
      on conflict (id) do nothing;
  end;

  insert into public.wallets (user_id, balance)
  values (new.id, 10)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;


-- ===================== 20260825075432_prevent_admin_self_credit.sql =====================
-- Normal Admins may credit other wallets, but never their own wallet.
-- The Owner keeps the ability to credit their own wallet. Self-removal rules
-- remain unchanged.
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

  if p_amount is null or p_amount = 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_admin_amount');
  end if;

  select p.role into v_admin_role
  from public.profiles p
  where p.id = v_admin_user_id;

  if p_amount > 0
    and p_target_user_id = v_admin_user_id
    and v_admin_role = 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_credit_own_coins');
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


-- ===================== 20260825104648_allow_group_member_withdrawals.sql =====================
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


-- ===================== 20260825125502_allow_ten_thousand_gibb_game_wagers.sql =====================
-- Wager-based games accept 1..10,000 GIBB. Dino Run keeps its fixed 150 GIBB
-- entry, so game_rounds still permits zero for historic free Dino runs.
alter table public.game_rounds
  drop constraint if exists game_rounds_wager_check;
alter table public.game_rounds
  add constraint game_rounds_wager_check check (wager between 0 and 10000);

alter table public.game_rounds
  drop constraint if exists game_rounds_payout_check;
alter table public.game_rounds
  add constraint game_rounds_payout_check check (payout between 0 and 2500000);

alter table public.blackjack_sessions
  drop constraint if exists blackjack_sessions_wager_check;
alter table public.blackjack_sessions
  add constraint blackjack_sessions_wager_check check (wager between 1 and 10000);

alter table public.blackjack_sessions
  drop constraint if exists blackjack_sessions_payout_check;
alter table public.blackjack_sessions
  add constraint blackjack_sessions_payout_check check (payout between 0 and 25000);

alter table public.poker_sessions
  drop constraint if exists poker_sessions_wager_check;
alter table public.poker_sessions
  add constraint poker_sessions_wager_check check (wager between 1 and 10000);

alter table public.poker_sessions
  drop constraint if exists poker_sessions_payout_check;
alter table public.poker_sessions
  add constraint poker_sessions_payout_check check (payout between 0 and 2500000);

do $$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.play_instant_game(text,text,bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager > 1000') = 0 then
    raise exception 'play_instant_game wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager > 1000', 'p_wager > 10000');

  select pg_catalog.pg_get_functiondef('public.start_blackjack(bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager > 1000') = 0 then
    raise exception 'start_blackjack wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager > 1000', 'p_wager > 10000');

  select pg_catalog.pg_get_functiondef('public.start_poker(bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager > 1000') = 0 then
    raise exception 'start_poker wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager > 1000', 'p_wager > 10000');
end;
$$;

revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.start_blackjack(bigint)
from public, anon, authenticated;
revoke all on function public.start_poker(bigint)
from public, anon, authenticated;

grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.start_blackjack(bigint)
to authenticated;
grant execute on function public.start_poker(bigint)
to authenticated;


-- ===================== 20260825130944_remove_game_wager_limit.sql =====================
-- Wager-based games have no artificial upper limit. The wallet balance remains
-- the natural ceiling, while positivity checks keep ledger values valid.
alter table public.game_rounds
  drop constraint if exists game_rounds_wager_check;
alter table public.game_rounds
  add constraint game_rounds_wager_check check (wager >= 0);

alter table public.game_rounds
  drop constraint if exists game_rounds_payout_check;
alter table public.game_rounds
  add constraint game_rounds_payout_check check (payout >= 0);

alter table public.blackjack_sessions
  drop constraint if exists blackjack_sessions_wager_check;
alter table public.blackjack_sessions
  add constraint blackjack_sessions_wager_check check (wager > 0);

alter table public.blackjack_sessions
  drop constraint if exists blackjack_sessions_payout_check;
alter table public.blackjack_sessions
  add constraint blackjack_sessions_payout_check check (payout >= 0);

alter table public.poker_sessions
  drop constraint if exists poker_sessions_wager_check;
alter table public.poker_sessions
  add constraint poker_sessions_wager_check check (wager > 0);

alter table public.poker_sessions
  drop constraint if exists poker_sessions_payout_check;
alter table public.poker_sessions
  add constraint poker_sessions_payout_check check (payout >= 0);

do $$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.play_instant_game(text,text,bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, ' or p_wager > 10000') > 0 then
    execute pg_catalog.replace(v_definition, ' or p_wager > 10000', '');
  elsif pg_catalog.strpos(v_definition, 'p_wager is null or p_wager < 1 then') = 0 then
    raise exception 'play_instant_game wager guard changed unexpectedly';
  end if;

  select pg_catalog.pg_get_functiondef('public.start_blackjack(bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, ' or p_wager > 10000') > 0 then
    execute pg_catalog.replace(v_definition, ' or p_wager > 10000', '');
  elsif pg_catalog.strpos(v_definition, 'p_wager is null or p_wager < 1 then') = 0 then
    raise exception 'start_blackjack wager guard changed unexpectedly';
  end if;

  select pg_catalog.pg_get_functiondef('public.start_poker(bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, ' or p_wager > 10000') > 0 then
    execute pg_catalog.replace(v_definition, ' or p_wager > 10000', '');
  elsif pg_catalog.strpos(v_definition, 'p_wager is null or p_wager < 1 then') = 0 then
    raise exception 'start_poker wager guard changed unexpectedly';
  end if;
end;
$$;

revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.start_blackjack(bigint)
from public, anon, authenticated;
revoke all on function public.start_poker(bigint)
from public, anon, authenticated;

grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.start_blackjack(bigint)
to authenticated;
grant execute on function public.start_poker(bigint)
to authenticated;


-- ===================== 20260825135211_add_visible_coin_flip_loss_mode.sql =====================
-- Harmless colleague prank: Admins and the Owner can adjust the visual coin-flip
-- odds. Prank rounds never change a wallet or create ledger transactions.
create table if not exists private.coin_flip_prank_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  win_chance smallint not null default 1 check (win_chance between 0 and 100),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into private.coin_flip_prank_settings (singleton, enabled, win_chance)
values (true, false, 1)
on conflict (singleton) do nothing;

revoke all on table private.coin_flip_prank_settings
from public, anon, authenticated;

do $migration$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.play_instant_game(text,text,bigint)'::pg_catalog.regprocedure
  ) into v_definition;

  if pg_catalog.strpos(v_definition, 'private.coin_flip_prank_settings') = 0 then
    v_old := $old$  v_label text;$old$;
    v_new := $new$  v_label text;
  v_prank_enabled boolean := false;
  v_prank_win_chance smallint := 1;$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game declarations changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    v_old := $old$  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;$old$;
    v_new := $new$  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  if p_game_key = 'coin_flip' then
    select s.enabled, s.win_chance
    into v_prank_enabled, v_prank_win_chance
    from private.coin_flip_prank_settings s
    where s.singleton;
  end if;$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game throttle block changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    v_old := $old$    v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);$old$;
    v_new := $new$    if v_prank_enabled then
      if private.game_random(100) < v_prank_win_chance then
        v_result_text := p_choice;
      else
        v_result_text := case p_choice when 'kopf' then 'zahl' else 'kopf' end;
      end if;
    else
      v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    end if;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game coin-flip block changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    v_old := $old$  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;$old$;
    v_new := $new$  if v_prank_enabled and p_game_key = 'coin_flip' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (v_user_id, p_game_key, p_choice, p_wager, v_payout, v_result)
    returning id into v_round_id;

    return pg_catalog.jsonb_build_object(
      'ok', true, 'round_id', v_round_id, 'game_key', p_game_key,
      'choice', p_choice, 'wager', p_wager, 'payout', v_payout,
      'net', v_payout - p_wager, 'result', v_result,
      'balance', v_wallet.balance,
      'entry_transaction_id', null, 'reward_transaction_id', null
    );
  end if;

  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game wallet block changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    execute v_definition;
  end if;
end;
$migration$;

create or replace function public.get_coin_flip_prank_admin_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_enabled boolean;
  v_win_chance smallint;
begin
  select s.enabled, s.win_chance
  into v_enabled, v_win_chance
  from private.coin_flip_prank_settings s
  where s.singleton;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'enabled', v_enabled,
    'win_chance', v_win_chance,
    'loss_chance', 100 - v_win_chance
  );
end;
$$;

create or replace function public.admin_set_coin_flip_prank(
  p_enabled boolean,
  p_win_chance integer,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_old_enabled boolean;
  v_old_win_chance smallint;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  if p_enabled is null or p_win_chance is null or p_win_chance < 0 or p_win_chance > 100 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting');
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select s.enabled, s.win_chance
  into v_old_enabled, v_old_win_chance
  from private.coin_flip_prank_settings s
  where s.singleton
  for update;

  update private.coin_flip_prank_settings
  set enabled = p_enabled,
      win_chance = p_win_chance::smallint,
      updated_by = v_admin_user_id,
      updated_at = now()
  where singleton;

  if v_old_enabled is distinct from p_enabled
     or v_old_win_chance is distinct from p_win_chance::smallint then
    perform private.write_admin_audit(
      v_admin_user_id,
      null,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', 'coin_flip_prank',
        'enabled', v_old_enabled,
        'win_chance', v_old_win_chance
      ),
      pg_catalog.jsonb_build_object(
        'game_key', 'coin_flip_prank',
        'enabled', p_enabled,
        'win_chance', p_win_chance
      ),
      'Münzwurf-Spaßmodus geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'enabled', p_enabled,
    'win_chance', p_win_chance,
    'loss_chance', 100 - p_win_chance
  );
end;
$$;

revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.get_coin_flip_prank_admin_state()
from public, anon, authenticated;
revoke all on function public.admin_set_coin_flip_prank(boolean, integer, text)
from public, anon, authenticated;

grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.get_coin_flip_prank_admin_state()
to authenticated;
grant execute on function public.admin_set_coin_flip_prank(boolean, integer, text)
to authenticated;


-- ===================== 20260825145050_expand_visual_pranks_and_dino_controls.sql =====================
-- Expand the harmless visual-only fun mode to every casino game except Dino Run.
-- These RPCs deliberately never update wallets, write ledger transactions or
-- insert game rounds. Dino Run receives separate, persisted speed/difficulty
-- controls that are frozen per run when the session starts.

create table private.game_prank_settings (
  game_key text primary key check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker'
  )),
  enabled boolean not null default false,
  win_chance smallint not null default 1 check (win_chance between 0 and 100),
  target_user_id uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into private.game_prank_settings (game_key, enabled, win_chance)
values
  ('roulette', false, 1),
  ('blackjack', false, 1),
  ('dice_duel', false, 1),
  ('high_card', false, 1),
  ('poker', false, 1);

insert into private.game_prank_settings (game_key, enabled, win_chance)
select 'coin_flip', s.enabled, s.win_chance
from private.coin_flip_prank_settings s
where s.singleton;

-- Retire the legacy coin-only code path so one visual round can never be
-- processed twice. The old table/functions stay present for migration history.
update private.coin_flip_prank_settings set enabled = false where singleton;

revoke all on table private.game_prank_settings from public, anon, authenticated;
create index game_prank_settings_target_user_id_idx
  on private.game_prank_settings (target_user_id) where target_user_id is not null;
create index game_prank_settings_updated_by_idx
  on private.game_prank_settings (updated_by) where updated_by is not null;
create index coin_flip_prank_settings_updated_by_idx
  on private.coin_flip_prank_settings (updated_by) where updated_by is not null;
revoke all on function public.get_coin_flip_prank_admin_state() from authenticated;
revoke all on function public.admin_set_coin_flip_prank(boolean, integer, text) from authenticated;

create table private.dino_game_settings (
  singleton boolean primary key default true check (singleton),
  speed_level smallint not null default 1 check (speed_level between 1 and 5),
  difficulty_level smallint not null default 1 check (difficulty_level between 1 and 5),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into private.dino_game_settings (singleton, speed_level, difficulty_level)
values (true, 1, 1);

revoke all on table private.dino_game_settings from public, anon, authenticated;
create index dino_game_settings_updated_by_idx
  on private.dino_game_settings (updated_by) where updated_by is not null;

alter table public.dino_run_sessions
  add column speed_level smallint not null default 1
  check (speed_level between 1 and 5);
alter table public.dino_run_sessions
  add column difficulty_level smallint not null default 1
  check (difficulty_level between 1 and 5);

create or replace function public.get_game_extras_admin_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_games jsonb;
  v_dino jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'game_key', s.game_key,
    'label', case s.game_key
      when 'roulette' then 'Roulette'
      when 'coin_flip' then 'Münzwurf'
      when 'blackjack' then 'Blackjack'
      when 'dice_duel' then 'Würfelduell'
      when 'high_card' then 'High Card'
      when 'poker' then '5-Karten-Poker'
    end,
    'enabled', s.enabled,
    'win_chance', s.win_chance,
    'scope', case when s.target_user_id is null then 'all' else 'user' end,
    'target_username', p.username,
    'target_display_name', p.display_name
  ) order by case s.game_key
    when 'roulette' then 1 when 'coin_flip' then 2 when 'blackjack' then 3
    when 'dice_duel' then 4 when 'high_card' then 5 when 'poker' then 6
  end), '[]'::jsonb)
  into v_games
  from private.game_prank_settings s
  left join public.profiles p on p.id = s.target_user_id;

  select pg_catalog.jsonb_build_object(
    'speed_level', d.speed_level,
    'difficulty_level', d.difficulty_level
  ) into v_dino
  from private.dino_game_settings d
  where d.singleton;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'games', v_games,
    'dino', v_dino
  );
end;
$$;

create or replace function public.get_effective_visual_pranks()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_games jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(s.game_key order by s.game_key), '[]'::jsonb)
  into v_games
  from private.game_prank_settings s
  where s.enabled
    and (s.target_user_id is null or s.target_user_id = v_user_id);

  return pg_catalog.jsonb_build_object('ok', true, 'games', v_games);
end;
$$;

create or replace function public.admin_set_game_visual_prank(
  p_game_key text,
  p_enabled boolean,
  p_win_chance integer,
  p_scope text,
  p_target_username text,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_target_user_id uuid;
  v_old private.game_prank_settings%rowtype;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  if p_game_key is null or p_game_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker'
  ) or p_enabled is null or p_win_chance is null
    or p_win_chance < 0 or p_win_chance > 100
    or p_scope is null or p_scope not in ('all', 'user') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting');
  end if;

  if p_scope = 'user' then
    if pg_catalog.btrim(coalesce(p_target_username, '')) = '' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_username_required');
    end if;
    select p.id into v_target_user_id
    from public.profiles p
    where pg_catalog.lower(p.username) = pg_catalog.lower(pg_catalog.btrim(p_target_username))
    limit 1;
    if v_target_user_id is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_user_not_found');
    end if;
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select s.* into v_old
  from private.game_prank_settings s
  where s.game_key = p_game_key
  for update;

  update private.game_prank_settings
  set enabled = p_enabled,
      win_chance = p_win_chance::smallint,
      target_user_id = case when p_scope = 'user' then v_target_user_id else null end,
      updated_by = v_admin_user_id,
      updated_at = pg_catalog.clock_timestamp()
  where game_key = p_game_key;

  if v_old.enabled is distinct from p_enabled
     or v_old.win_chance is distinct from p_win_chance::smallint
     or v_old.target_user_id is distinct from v_target_user_id then
    perform private.write_admin_audit(
      v_admin_user_id,
      case when p_scope = 'user' then v_target_user_id else null end,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', p_game_key || '_visual',
        'enabled', v_old.enabled,
        'win_chance', v_old.win_chance,
        'target_user_id', v_old.target_user_id
      ),
      pg_catalog.jsonb_build_object(
        'game_key', p_game_key || '_visual',
        'enabled', p_enabled,
        'win_chance', p_win_chance,
        'scope', p_scope,
        'target_user_id', v_target_user_id
      ),
      'Rein visuellen Spielmodus geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_set_dino_game_settings(
  p_speed_level integer,
  p_difficulty_level integer,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_old private.dino_game_settings%rowtype;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  if p_speed_level is null or p_speed_level < 1 or p_speed_level > 5
     or p_difficulty_level is null or p_difficulty_level < 1 or p_difficulty_level > 5 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_dino_setting');
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select d.* into v_old
  from private.dino_game_settings d
  where d.singleton
  for update;

  update private.dino_game_settings
  set speed_level = p_speed_level::smallint,
      difficulty_level = p_difficulty_level::smallint,
      updated_by = v_admin_user_id,
      updated_at = pg_catalog.clock_timestamp()
  where singleton;

  if v_old.speed_level is distinct from p_speed_level::smallint
     or v_old.difficulty_level is distinct from p_difficulty_level::smallint then
    perform private.write_admin_audit(
      v_admin_user_id,
      null,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', 'dino_run_tuning',
        'speed_level', v_old.speed_level,
        'difficulty_level', v_old.difficulty_level
      ),
      pg_catalog.jsonb_build_object(
        'game_key', 'dino_run_tuning',
        'speed_level', p_speed_level,
        'difficulty_level', p_difficulty_level
      ),
      'Dino-Run-Geschwindigkeit und Schwierigkeit geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.play_visual_prank_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
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
  v_setting private.game_prank_settings%rowtype;
  v_win boolean;
  v_payout numeric := 0;
  v_result jsonb := '{}'::jsonb;
  v_number integer;
  v_color text;
begin
  if p_game_key is null or p_game_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker'
  ) then raise exception 'invalid_game'; end if;
  if p_wager is null or p_wager < 1 then raise exception 'invalid_game_wager'; end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;

  select s.* into v_setting
  from private.game_prank_settings s
  where s.game_key = p_game_key
    and s.enabled
    and (s.target_user_id is null or s.target_user_id = v_user_id);
  if v_setting.game_key is null then raise exception 'visual_prank_inactive'; end if;

  v_win := private.game_random(100) < v_setting.win_chance;

  if p_game_key = 'roulette' then
    if coalesce(p_choice, '') ~ '^(0|[1-9]|[12][0-9]|3[0-6])$' then
      if v_win then v_number := p_choice::integer;
      else v_number := (p_choice::integer + 1 + private.game_random(36)) % 37; end if;
      v_payout := case when v_win then p_wager::numeric * 36 else 0 end;
    elsif p_choice in ('rot', 'schwarz') then
      if v_win then v_number := case p_choice when 'rot' then 1 else 2 end;
      else v_number := case p_choice when 'rot' then 2 else 1 end; end if;
      v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
    else raise exception 'invalid_roulette_choice'; end if;
    v_color := case when v_number = 0 then 'grün'
      when v_number in (1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36) then 'rot'
      else 'schwarz' end;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
  elsif p_game_key = 'coin_flip' then
    if p_choice not in ('kopf', 'zahl') then raise exception 'invalid_coin_choice'; end if;
    v_result := pg_catalog.jsonb_build_object(
      'side', case when v_win then p_choice
        when p_choice = 'kopf' then 'zahl' else 'kopf' end
    );
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'dice_duel' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object('player', 6, 'house', 1)
      else pg_catalog.jsonb_build_object('player', 1, 'house', 6) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'high_card' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object('player', 13, 'house', 1)
      else pg_catalog.jsonb_build_object('player', 1, 'house', 13) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'blackjack' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object(
        'status', 'won', 'player_cards', pg_catalog.jsonb_build_array(10, 10),
        'dealer_cards', pg_catalog.jsonb_build_array(10, 8),
        'player_score', 20, 'dealer_score', 18
      )
      else pg_catalog.jsonb_build_object(
        'status', 'lost', 'player_cards', pg_catalog.jsonb_build_array(10, 7),
        'dealer_cards', pg_catalog.jsonb_build_array(10, 10),
        'player_score', 17, 'dealer_score', 20
      ) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  else
    v_result := case when v_win
      then pg_catalog.jsonb_build_object(
        'status', 'finished', 'cards', pg_catalog.jsonb_build_array(0, 13, 28, 42, 5),
        'hand', 'Ein Paar', 'multiplier', 2
      )
      else pg_catalog.jsonb_build_object(
        'status', 'finished', 'cards', pg_catalog.jsonb_build_array(0, 14, 28, 42, 5),
        'hand', 'Hohe Karte', 'multiplier', 0
      ) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'game_key', p_game_key,
    'choice', p_choice,
    'wager', p_wager,
    'payout', v_payout,
    'net', v_payout - p_wager,
    'result', v_result,
    'balance', v_wallet.balance,
    'visual_only', true,
    'entry_transaction_id', null,
    'reward_transaction_id', null
  );
end;
$$;

create or replace function public.start_dino_run()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_entry_cost constant bigint := 150;
  v_wallet public.wallets%rowtype;
  v_previous public.dino_run_sessions%rowtype;
  v_session public.dino_run_sessions%rowtype;
  v_speed_level smallint;
  v_difficulty_level smallint;
begin
  if not private.game_is_enabled('dino_run') then raise exception 'game_disabled'; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 188447)::bigint
  );

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < v_entry_cost then raise exception 'insufficient_balance'; end if;

  select d.* into v_previous
  from public.dino_run_sessions d
  where d.user_id = v_user_id and d.status = 'active'
  order by d.started_at desc limit 1 for update;

  if v_previous.id is not null then
    update public.dino_run_sessions
    set status = 'abandoned', updated_at = pg_catalog.clock_timestamp(),
        finished_at = pg_catalog.clock_timestamp()
    where id = v_previous.id;
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (
      v_user_id, 'dino_run', 'abandoned', v_previous.wager, v_previous.reward_total,
      pg_catalog.jsonb_build_object(
        'score', v_previous.score, 'milestones', v_previous.rewarded_milestones,
        'status', 'abandoned', 'speed_level', v_previous.speed_level,
        'difficulty_level', v_previous.difficulty_level
      )
    );
  end if;

  select d.speed_level, d.difficulty_level into v_speed_level, v_difficulty_level
  from private.dino_game_settings d where d.singleton;

  update public.wallets
  set balance = balance - v_entry_cost, updated_at = pg_catalog.clock_timestamp()
  where id = v_wallet.id;
  perform private.append_transaction(
    v_user_id, null, v_entry_cost, 'GAME_ENTRY', 'Game Center · Dino Run · Eintritt'
  );

  insert into public.dino_run_sessions (user_id, seed, wager, speed_level, difficulty_level)
  values (v_user_id, private.game_random(1000000), v_entry_cost, v_speed_level, v_difficulty_level)
  returning * into v_session;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'seed', v_session.seed, 'score', 0,
    'wager', v_session.wager, 'reward', 0, 'total_reward', 0,
    'next_reward_at', 1000, 'balance', v_wallet.balance - v_entry_cost,
    'status', 'active', 'game_key', 'dino_run',
    'speed_level', v_session.speed_level,
    'difficulty_level', v_session.difficulty_level
  );
end;
$$;

create or replace function public.sync_dino_run(
  p_session_id uuid,
  p_score integer,
  p_finished boolean default false
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
  v_session public.dino_run_sessions%rowtype;
  v_elapsed_seconds numeric;
  v_max_score integer;
  v_milestones integer;
  v_new_milestones integer;
  v_reward bigint := 0;
  v_status text;
begin
  if p_session_id is null or p_score is null or p_score < 0 or p_score > 1000000 then
    raise exception 'invalid_dino_score';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 188447)::bigint
  );

  select d.* into v_session
  from public.dino_run_sessions d
  where d.id = p_session_id and d.user_id = v_user_id
  for update;
  if v_session.id is null then raise exception 'dino_session_not_found'; end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  if v_session.status <> 'active' then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'id', v_session.id, 'score', v_session.score,
      'wager', v_session.wager, 'reward', 0, 'total_reward', v_session.reward_total,
      'next_reward_at', (v_session.rewarded_milestones + 1) * 1000,
      'balance', v_wallet.balance, 'status', v_session.status, 'game_key', 'dino_run',
      'speed_level', v_session.speed_level, 'difficulty_level', v_session.difficulty_level
    );
  end if;

  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if p_score < v_session.score then raise exception 'dino_score_reversed'; end if;

  v_elapsed_seconds := pg_catalog.date_part(
    'epoch', pg_catalog.clock_timestamp() - v_session.started_at
  );
  if v_elapsed_seconds < 0 then v_elapsed_seconds := 0; end if;
  -- Score stays time-based even when the course itself runs faster.
  v_max_score := pg_catalog.floor(v_elapsed_seconds * 55)::integer + 125;
  if p_score > v_max_score then raise exception 'dino_score_too_fast'; end if;

  v_milestones := p_score / 1000;
  v_new_milestones := v_milestones - v_session.rewarded_milestones;
  if v_new_milestones > 0 then
    v_reward := v_new_milestones::bigint * 100;
    update public.wallets
    set balance = balance + v_reward, updated_at = pg_catalog.clock_timestamp()
    where id = v_wallet.id;
    perform private.append_transaction(
      null, v_user_id, v_reward, 'GAME_REWARD',
      'Game Center · Dino Run · ' || v_milestones || ' × 1’000 Punkte'
    );
  end if;

  v_status := case
    when coalesce(p_finished, false) or v_elapsed_seconds > 1800 then 'finished'
    else 'active' end;

  update public.dino_run_sessions
  set score = p_score, rewarded_milestones = v_milestones,
      reward_total = reward_total + v_reward, status = v_status,
      updated_at = pg_catalog.clock_timestamp(),
      finished_at = case when v_status = 'finished' then pg_catalog.clock_timestamp() else null end
  where id = v_session.id returning * into v_session;

  if v_status = 'finished' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (
      v_user_id, 'dino_run', 'run', v_session.wager, v_session.reward_total,
      pg_catalog.jsonb_build_object(
        'score', v_session.score, 'milestones', v_session.rewarded_milestones,
        'status', 'finished', 'speed_level', v_session.speed_level,
        'difficulty_level', v_session.difficulty_level
      )
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'score', v_session.score,
    'wager', v_session.wager, 'reward', v_reward, 'total_reward', v_session.reward_total,
    'next_reward_at', (v_session.rewarded_milestones + 1) * 1000,
    'balance', v_wallet.balance + v_reward, 'status', v_session.status,
    'game_key', 'dino_run', 'speed_level', v_session.speed_level,
    'difficulty_level', v_session.difficulty_level
  );
end;
$$;

revoke all on function public.get_game_extras_admin_state() from public, anon, authenticated;
revoke all on function public.get_effective_visual_pranks() from public, anon, authenticated;
revoke all on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_set_dino_game_settings(integer, integer, text) from public, anon, authenticated;
revoke all on function public.play_visual_prank_game(text, text, bigint) from public, anon, authenticated;
revoke all on function public.start_dino_run() from public, anon, authenticated;
revoke all on function public.sync_dino_run(uuid, integer, boolean) from public, anon, authenticated;

grant execute on function public.get_game_extras_admin_state() to authenticated;
grant execute on function public.get_effective_visual_pranks() to authenticated;
grant execute on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text) to authenticated;
grant execute on function public.admin_set_dino_game_settings(integer, integer, text) to authenticated;
grant execute on function public.play_visual_prank_game(text, text, bigint) to authenticated;
grant execute on function public.start_dino_run() to authenticated;
grant execute on function public.sync_dino_run(uuid, integer, boolean) to authenticated;


-- ===================== 20260826121128_add_plinko_game.sql =====================
-- Add Plinko as a server-authoritative wallet game and extend the existing
-- visual-only Admin/Owner game controls. The visual mode never changes wallet
-- balances, ledger entries, statistics or game history.

alter table public.game_settings
  drop constraint if exists game_settings_game_key_check;
alter table public.game_settings
  add constraint game_settings_game_key_check check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack',
    'dice_duel', 'high_card', 'poker', 'plinko', 'dino_run'
  ));

alter table public.game_rounds
  drop constraint if exists game_rounds_game_key_check;
alter table public.game_rounds
  add constraint game_rounds_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko', 'dino_run'
  ));

alter table private.game_prank_settings
  drop constraint if exists game_prank_settings_game_key_check;
alter table private.game_prank_settings
  add constraint game_prank_settings_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko'
  ));

insert into public.game_settings (game_key, label, enabled, sort_order)
values ('plinko', 'Plinko', true, 70)
on conflict (game_key) do update
set label = excluded.label,
    sort_order = excluded.sort_order;

update public.game_settings
set sort_order = 80
where game_key = 'dino_run' and sort_order <= 70;

insert into private.game_prank_settings (game_key, enabled, win_chance)
values ('plinko', false, 50)
on conflict (game_key) do nothing;

create or replace function public.get_game_extras_admin_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_games jsonb;
  v_dino jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'game_key', s.game_key,
    'label', case s.game_key
      when 'roulette' then 'Roulette'
      when 'coin_flip' then 'Münzwurf'
      when 'blackjack' then 'Blackjack'
      when 'dice_duel' then 'Würfelduell'
      when 'high_card' then 'High Card'
      when 'poker' then '5-Karten-Poker'
      when 'plinko' then 'Plinko'
    end,
    'enabled', s.enabled,
    'win_chance', s.win_chance,
    'scope', case when s.target_user_id is null then 'all' else 'user' end,
    'target_username', p.username,
    'target_display_name', p.display_name
  ) order by case s.game_key
    when 'roulette' then 1 when 'coin_flip' then 2 when 'blackjack' then 3
    when 'dice_duel' then 4 when 'high_card' then 5 when 'poker' then 6
    when 'plinko' then 7
  end), '[]'::jsonb)
  into v_games
  from private.game_prank_settings s
  left join public.profiles p on p.id = s.target_user_id;

  select pg_catalog.jsonb_build_object(
    'speed_level', d.speed_level,
    'difficulty_level', d.difficulty_level
  ) into v_dino
  from private.dino_game_settings d
  where d.singleton;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'games', v_games,
    'dino', v_dino
  );
end;
$$;

create or replace function public.admin_set_game_visual_prank(
  p_game_key text,
  p_enabled boolean,
  p_win_chance integer,
  p_scope text,
  p_target_username text,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_target_user_id uuid;
  v_old private.game_prank_settings%rowtype;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  if p_game_key is null or p_game_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko'
  ) or p_enabled is null or p_win_chance is null
    or p_win_chance < 0 or p_win_chance > 100
    or p_scope is null or p_scope not in ('all', 'user') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting');
  end if;

  if p_scope = 'user' then
    if pg_catalog.btrim(coalesce(p_target_username, '')) = '' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_username_required');
    end if;
    select p.id into v_target_user_id
    from public.profiles p
    where pg_catalog.lower(p.username) = pg_catalog.lower(pg_catalog.btrim(p_target_username))
    limit 1;
    if v_target_user_id is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_user_not_found');
    end if;
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select s.* into v_old
  from private.game_prank_settings s
  where s.game_key = p_game_key
  for update;

  update private.game_prank_settings
  set enabled = p_enabled,
      win_chance = p_win_chance::smallint,
      target_user_id = case when p_scope = 'user' then v_target_user_id else null end,
      updated_by = v_admin_user_id,
      updated_at = pg_catalog.clock_timestamp()
  where game_key = p_game_key;

  if v_old.enabled is distinct from p_enabled
     or v_old.win_chance is distinct from p_win_chance::smallint
     or v_old.target_user_id is distinct from v_target_user_id then
    perform private.write_admin_audit(
      v_admin_user_id,
      case when p_scope = 'user' then v_target_user_id else null end,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', p_game_key || '_visual',
        'enabled', v_old.enabled,
        'win_chance', v_old.win_chance,
        'target_user_id', v_old.target_user_id
      ),
      pg_catalog.jsonb_build_object(
        'game_key', p_game_key || '_visual',
        'enabled', p_enabled,
        'win_chance', p_win_chance,
        'scope', p_scope,
        'target_user_id', v_target_user_id
      ),
      'Rein visuellen Spielmodus geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.play_instant_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
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
  v_payout bigint := 0;
  v_result jsonb := '{}'::jsonb;
  v_result_text text;
  v_round_id uuid;
  v_entry_id uuid;
  v_reward_id uuid;
  v_number integer;
  v_user_roll integer;
  v_house_roll integer;
  v_color text;
  v_label text;
  v_plinko_slot integer;
  v_plinko_multiplier integer;
begin
  p_game_key := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  p_choice := pg_catalog.lower(pg_catalog.btrim(coalesce(p_choice, '')));
  if p_game_key not in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko') then
    raise exception 'invalid_game';
  end if;
  if p_wager is null or p_wager < 1 then
    raise exception 'invalid_game_wager';
  end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  if p_game_key = 'roulette' and p_choice not in (
    'rot', 'schwarz', '0','1','2','3','4','5','6','7','8','9','10','11','12',
    '13','14','15','16','17','18','19','20','21','22','23','24','25','26',
    '27','28','29','30','31','32','33','34','35','36'
  ) then
    raise exception 'invalid_game_choice';
  elsif p_game_key = 'coin_flip' and p_choice not in ('kopf', 'zahl') then
    raise exception 'invalid_game_choice';
  elsif p_game_key in ('dice_duel', 'high_card', 'plinko') and p_choice <> 'spielen' then
    raise exception 'invalid_game_choice';
  end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;
  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id
      and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  if p_game_key = 'roulette' then
    v_label := 'Roulette';
    v_number := private.game_random(37);
    v_color := case
      when v_number = 0 then 'grün'
      when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot'
      else 'schwarz'
    end;
    if p_choice = v_number::text then v_payout := p_wager * 36;
    elsif p_choice = v_color then v_payout := p_wager * 2;
    end if;
    v_result_text := v_number || ' · ' || v_color;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
  elsif p_game_key = 'coin_flip' then
    v_label := 'Münzwurf';
    v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);
  elsif p_game_key = 'dice_duel' then
    v_label := 'Würfelduell';
    v_user_roll := private.game_random(6) + 1;
    v_house_roll := private.game_random(6) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  elsif p_game_key = 'high_card' then
    v_label := 'High Card';
    v_user_roll := private.game_random(13) + 1;
    v_house_roll := private.game_random(13) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  else
    v_label := 'Plinko';
    v_plinko_slot := private.game_random(9);
    v_plinko_multiplier := case v_plinko_slot
      when 0 then 3 when 1 then 1 when 7 then 1 when 8 then 3 else 0
    end;
    v_payout := p_wager * v_plinko_multiplier;
    v_result_text := 'Fach ' || (v_plinko_slot + 1) || ' · ' || v_plinko_multiplier || 'x';
    v_result := pg_catalog.jsonb_build_object(
      'slot', v_plinko_slot,
      'multiplier', v_plinko_multiplier,
      'status', case when v_payout > p_wager then 'won'
        when v_payout = p_wager then 'push' else 'lost' end
    );
  end if;

  update public.wallets
  set balance = balance - p_wager, updated_at = now()
  where id = v_wallet.id;
  v_entry_id := private.append_transaction(
    v_user_id, null, p_wager, 'GAME_ENTRY',
    'Game Center · ' || v_label || ' · Einsatz'
  );
  if v_payout > 0 then
    update public.wallets
    set balance = balance + v_payout, updated_at = now()
    where id = v_wallet.id;
    v_reward_id := private.append_transaction(
      null, v_user_id, v_payout, 'GAME_REWARD',
      'Game Center · ' || v_label || ' · Ergebnis ' || v_result_text
    );
  end if;

  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (v_user_id, p_game_key, p_choice, p_wager, v_payout, v_result)
  returning id into v_round_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'round_id', v_round_id, 'game_key', p_game_key,
    'choice', p_choice, 'wager', p_wager, 'payout', v_payout,
    'net', v_payout - p_wager, 'result', v_result,
    'balance', v_wallet.balance - p_wager + v_payout,
    'entry_transaction_id', v_entry_id, 'reward_transaction_id', v_reward_id
  );
end;
$$;

create or replace function public.play_visual_prank_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
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
  v_setting private.game_prank_settings%rowtype;
  v_win boolean;
  v_payout numeric := 0;
  v_result jsonb := '{}'::jsonb;
  v_number integer;
  v_color text;
  v_plinko_slot integer;
begin
  if p_game_key is null or p_game_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko'
  ) then raise exception 'invalid_game'; end if;
  if p_wager is null or p_wager < 1 then raise exception 'invalid_game_wager'; end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;

  select s.* into v_setting
  from private.game_prank_settings s
  where s.game_key = p_game_key
    and s.enabled
    and (s.target_user_id is null or s.target_user_id = v_user_id);
  if v_setting.game_key is null then raise exception 'visual_prank_inactive'; end if;

  v_win := private.game_random(100) < v_setting.win_chance;

  if p_game_key = 'roulette' then
    if coalesce(p_choice, '') ~ '^(0|[1-9]|[12][0-9]|3[0-6])$' then
      if v_win then v_number := p_choice::integer;
      else v_number := (p_choice::integer + 1 + private.game_random(36)) % 37; end if;
      v_payout := case when v_win then p_wager::numeric * 36 else 0 end;
    elsif p_choice in ('rot', 'schwarz') then
      if v_win then v_number := case p_choice when 'rot' then 1 else 2 end;
      else v_number := case p_choice when 'rot' then 2 else 1 end; end if;
      v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
    else raise exception 'invalid_roulette_choice'; end if;
    v_color := case when v_number = 0 then 'grün'
      when v_number in (1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36) then 'rot'
      else 'schwarz' end;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
  elsif p_game_key = 'coin_flip' then
    if p_choice not in ('kopf', 'zahl') then raise exception 'invalid_coin_choice'; end if;
    v_result := pg_catalog.jsonb_build_object(
      'side', case when v_win then p_choice
        when p_choice = 'kopf' then 'zahl' else 'kopf' end
    );
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'dice_duel' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object('player', 6, 'house', 1)
      else pg_catalog.jsonb_build_object('player', 1, 'house', 6) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'high_card' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object('player', 13, 'house', 1)
      else pg_catalog.jsonb_build_object('player', 1, 'house', 13) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'blackjack' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object(
        'status', 'won', 'player_cards', pg_catalog.jsonb_build_array(10, 10),
        'dealer_cards', pg_catalog.jsonb_build_array(10, 8),
        'player_score', 20, 'dealer_score', 18
      )
      else pg_catalog.jsonb_build_object(
        'status', 'lost', 'player_cards', pg_catalog.jsonb_build_array(10, 7),
        'dealer_cards', pg_catalog.jsonb_build_array(10, 10),
        'player_score', 17, 'dealer_score', 20
      ) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'poker' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object(
        'status', 'finished', 'cards', pg_catalog.jsonb_build_array(0, 13, 28, 42, 5),
        'hand', 'Ein Paar', 'multiplier', 2
      )
      else pg_catalog.jsonb_build_object(
        'status', 'finished', 'cards', pg_catalog.jsonb_build_array(0, 14, 28, 42, 5),
        'hand', 'Hohe Karte', 'multiplier', 0
      ) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  else
    if p_choice <> 'spielen' then raise exception 'invalid_game_choice'; end if;
    v_plinko_slot := case when v_win
      then case private.game_random(2) when 0 then 0 else 8 end
      else 4
    end;
    v_payout := case when v_win then p_wager::numeric * 3 else 0 end;
    v_result := pg_catalog.jsonb_build_object(
      'slot', v_plinko_slot,
      'multiplier', case when v_win then 3 else 0 end,
      'status', case when v_win then 'won' else 'lost' end
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'game_key', p_game_key,
    'choice', p_choice,
    'wager', p_wager,
    'payout', v_payout,
    'net', v_payout - p_wager,
    'result', v_result,
    'balance', v_wallet.balance,
    'visual_only', true,
    'entry_transaction_id', null,
    'reward_transaction_id', null
  );
end;
$$;

revoke all on function public.get_game_extras_admin_state()
from public, anon, authenticated;
revoke all on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text)
from public, anon, authenticated;
revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.play_visual_prank_game(text, text, bigint)
from public, anon, authenticated;

grant execute on function public.get_game_extras_admin_state()
to authenticated;
grant execute on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text)
to authenticated;
grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.play_visual_prank_game(text, text, bigint)
to authenticated;


-- ===================== 20260826164000_add_admin_panel_pin_session_check.sql =====================
-- Verify the personal Admin PIN once when the Admin panel is opened.
-- The browser keeps the entered PIN only in component memory and still sends it
-- to every protected mutation, so all existing server-side checks remain active.

create or replace function public.admin_verify_pin(p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.admin_verify_pin(text) from public, anon;
grant execute on function public.admin_verify_pin(text) to authenticated;

comment on function public.admin_verify_pin(text) is
  'Verifies the current Admin PIN when entering the Admin panel; no session or plaintext PIN is persisted server-side.';


-- ===================== 20260827132028_add_dino_run_leaderboard.sql =====================
-- Server-backed Dino Run leaderboard.
-- Only completed, server-validated runs are eligible. The public RPC exposes
-- usernames and scores, never email addresses or wallet balances.
create index if not exists dino_run_finished_score_idx
  on public.dino_run_sessions (score desc, finished_at asc, user_id)
  where status = 'finished';

create or replace function public.get_dino_leaderboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_entries jsonb;
  v_my_entry jsonb;
begin
  with best_runs as (
    select distinct on (d.user_id)
      d.user_id,
      d.score,
      d.reward_total,
      d.finished_at
    from public.dino_run_sessions d
    where d.status = 'finished'
    order by d.user_id, d.score desc, d.finished_at asc, d.id asc
  ),
  ranked as (
    select
      row_number() over (order by b.score desc, b.finished_at asc, b.user_id)::integer as position,
      b.user_id,
      coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      b.score,
      b.reward_total,
      b.finished_at,
      b.user_id = v_user_id as is_me
    from best_runs b
    left join public.profiles p on p.id = b.user_id
  )
  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'rank', r.position,
      'user_id', r.user_id,
      'username', r.username,
      'score', r.score,
      'reward_total', r.reward_total,
      'finished_at', r.finished_at,
      'is_me', r.is_me
    ) order by r.position
  ) filter (where r.position <= 10), '[]'::jsonb)
  into v_entries
  from ranked r;

  with best_runs as (
    select distinct on (d.user_id)
      d.user_id,
      d.score,
      d.reward_total,
      d.finished_at
    from public.dino_run_sessions d
    where d.status = 'finished'
    order by d.user_id, d.score desc, d.finished_at asc, d.id asc
  ),
  ranked as (
    select
      row_number() over (order by b.score desc, b.finished_at asc, b.user_id)::integer as position,
      b.user_id,
      coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      b.score,
      b.reward_total,
      b.finished_at,
      b.user_id = v_user_id as is_me
    from best_runs b
    left join public.profiles p on p.id = b.user_id
  )
  select pg_catalog.jsonb_build_object(
    'rank', r.position,
    'user_id', r.user_id,
    'username', r.username,
    'score', r.score,
    'reward_total', r.reward_total,
    'finished_at', r.finished_at,
    'is_me', r.is_me
  )
  into v_my_entry
  from ranked r
  where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'entries', v_entries,
    'my_entry', coalesce(v_my_entry, 'null'::jsonb)
  );
end;
$$;

revoke all on function public.get_dino_leaderboard() from public, anon, authenticated;
grant execute on function public.get_dino_leaderboard() to authenticated;


-- ===================== 20260827141734_add_visual_demo_roles.sql =====================
-- Clearly labelled, visual-only demo badges for harmless team pranks.
-- These rows never change public.profiles.role and never grant permissions.

create table if not exists private.visual_demo_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  visual_role text not null check (visual_role in ('demo_admin', 'demo_owner')),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table private.visual_demo_roles enable row level security;
revoke all on table private.visual_demo_roles from public, anon, authenticated;

create or replace function public.get_my_visual_role()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_visual_role text;
begin
  select r.visual_role into v_visual_role
  from private.visual_demo_roles r
  where r.user_id = v_user_id;
  return v_visual_role;
end;
$$;

revoke all on function public.get_my_visual_role() from public, anon;
grant execute on function public.get_my_visual_role() to authenticated;

create or replace function public.admin_list_visual_roles()
returns table(user_id uuid, visual_role text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return query
  select r.user_id, r.visual_role
  from private.visual_demo_roles r
  order by r.updated_at desc, r.user_id;
end;
$$;

revoke all on function public.admin_list_visual_roles() from public, anon, authenticated;
grant execute on function public.admin_list_visual_roles() to authenticated;

create or replace function public.admin_set_visual_role(
  p_target_user_id uuid,
  p_visual_role text,
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
  v_target_exists boolean;
begin
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_required');
  end if;
  if p_target_user_id = v_admin_user_id then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_visual_role_self');
  end if;
  if p_visual_role is not null and p_visual_role not in ('demo_admin', 'demo_owner') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_visual_role');
  end if;

  select exists(
    select 1 from public.profiles p where p.id = p_target_user_id
  ) into v_target_exists;
  if not v_target_exists then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;

  if p_visual_role is null then
    delete from private.visual_demo_roles where user_id = p_target_user_id;
  else
    insert into private.visual_demo_roles(user_id, visual_role, updated_by)
    values (p_target_user_id, p_visual_role, v_admin_user_id)
    on conflict (user_id) do update
      set visual_role = excluded.visual_role,
          updated_by = excluded.updated_by,
          updated_at = now();
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'visual_role', p_visual_role);
end;
$$;

revoke all on function public.admin_set_visual_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_visual_role(uuid, text, text) to authenticated;


-- ===================== 20260827164124_add_game_outcome_leaderboards.sql =====================
-- Aggregated win/loss leaderboards for every Game Center game.
-- Only authenticated, active users may call the RPC. It exposes display names
-- and aggregate counts, never wallet balances, wagers, emails, or raw rounds.
create index if not exists game_rounds_outcome_leaderboard_idx
  on public.game_rounds (game_key, user_id)
  include (payout, wager, created_at)
  where payout <> wager;

create or replace function public.get_game_outcome_leaderboards()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_games jsonb;
begin
  with game_keys(game_key, sort_order) as (
    values
      ('roulette'::text, 10),
      ('coin_flip'::text, 20),
      ('blackjack'::text, 30),
      ('dice_duel'::text, 40),
      ('high_card'::text, 50),
      ('poker'::text, 60),
      ('plinko'::text, 70),
      ('dino_run'::text, 80)
  ),
  stats as (
    select
      r.game_key,
      r.user_id,
      pg_catalog.count(*) filter (where r.payout > r.wager)::integer as wins,
      pg_catalog.count(*) filter (where r.payout < r.wager)::integer as losses,
      pg_catalog.max(r.created_at) filter (where r.payout > r.wager) as last_win_at,
      pg_catalog.max(r.created_at) filter (where r.payout < r.wager) as last_loss_at
    from public.game_rounds r
    where r.payout <> r.wager
    group by r.game_key, r.user_id
  ),
  win_ranked as (
    select
      s.game_key,
      s.user_id,
      s.wins as total,
      pg_catalog.row_number() over (
        partition by s.game_key
        order by s.wins desc, s.last_win_at asc, s.user_id
      )::integer as position
    from stats s
    where s.wins > 0
  ),
  loss_ranked as (
    select
      s.game_key,
      s.user_id,
      s.losses as total,
      pg_catalog.row_number() over (
        partition by s.game_key
        order by s.losses desc, s.last_loss_at asc, s.user_id
      )::integer as position
    from stats s
    where s.losses > 0
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'game_key', g.game_key,
        'wins', coalesce((
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'rank', w.position,
              'username', coalesce(
                nullif(p.username, ''),
                nullif(p.display_name, ''),
                'GIBB Spieler'
              ),
              'total', w.total,
              'is_me', w.user_id = v_user_id
            ) order by w.position
          )
          from win_ranked w
          left join public.profiles p on p.id = w.user_id
          where w.game_key = g.game_key and w.position <= 5
        ), '[]'::jsonb),
        'losses', coalesce((
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'rank', l.position,
              'username', coalesce(
                nullif(p.username, ''),
                nullif(p.display_name, ''),
                'GIBB Spieler'
              ),
              'total', l.total,
              'is_me', l.user_id = v_user_id
            ) order by l.position
          )
          from loss_ranked l
          left join public.profiles p on p.id = l.user_id
          where l.game_key = g.game_key and l.position <= 5
        ), '[]'::jsonb),
        'my_wins', coalesce((
          select s.wins from stats s
          where s.game_key = g.game_key and s.user_id = v_user_id
        ), 0),
        'my_losses', coalesce((
          select s.losses from stats s
          where s.game_key = g.game_key and s.user_id = v_user_id
        ), 0)
      ) order by g.sort_order
    ),
    '[]'::jsonb
  )
  into v_games
  from game_keys g;

  return pg_catalog.jsonb_build_object('ok', true, 'games', v_games);
end;
$$;

revoke all on function public.get_game_outcome_leaderboards() from public, anon, authenticated;
grant execute on function public.get_game_outcome_leaderboards() to authenticated;


-- ===================== 20260827185502_add_casino_games_leaderboards.sql =====================
-- Transparent, virtual-coin casino games and a shared online leaderboard.
-- All outcomes are generated and settled on the server. No real-money value is involved.

alter table public.game_settings
  drop constraint if exists game_settings_game_key_check;
alter table public.game_settings
  add constraint game_settings_game_key_check check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card',
    'poker', 'plinko', 'dino_run', 'slots', 'baccarat', 'keno', 'wheel', 'mines',
    'bingo', 'crash'
  ));

alter table public.game_rounds
  drop constraint if exists game_rounds_game_key_check;
alter table public.game_rounds
  add constraint game_rounds_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker', 'plinko',
    'dino_run', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash'
  ));

insert into public.game_settings (game_key, label, enabled, sort_order)
values
  ('slots', 'Slot Machine', true, 90),
  ('baccarat', 'Baccarat', true, 100),
  ('keno', 'Keno', true, 110),
  ('wheel', 'Glücksrad', true, 120),
  ('mines', 'Mines', true, 130),
  ('bingo', 'Bingo', true, 140),
  ('crash', 'Crash', true, 150)
on conflict (game_key) do update
set label = excluded.label, sort_order = excluded.sort_order;

create table if not exists public.game_leaderboard (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_key text not null check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker', 'plinko',
    'dino_run', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash'
  )),
  plays bigint not null default 0 check (plays >= 0),
  wins bigint not null default 0 check (wins >= 0),
  wagered bigint not null default 0 check (wagered >= 0),
  payout bigint not null default 0 check (payout >= 0),
  net bigint not null default 0,
  best_score bigint not null default 0 check (best_score >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, game_key)
);

create index if not exists game_leaderboard_rank_idx
  on public.game_leaderboard (game_key, net desc, best_score desc, updated_at asc);

alter table public.game_leaderboard enable row level security;
revoke all on table public.game_leaderboard from public, anon, authenticated;

create or replace function private.record_game_leaderboard(
  p_user_id uuid,
  p_game_key text,
  p_wager bigint,
  p_payout bigint
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  insert into public.game_leaderboard (user_id, game_key, plays, wins, wagered, payout, net, best_score)
  values (
    p_user_id, p_game_key, 1,
    case when p_payout > p_wager then 1 else 0 end,
    p_wager, p_payout, p_payout - p_wager, p_payout
  )
  on conflict (user_id, game_key) do update set
    plays = public.game_leaderboard.plays + 1,
    wins = public.game_leaderboard.wins + case when excluded.payout > p_wager then 1 else 0 end,
    wagered = public.game_leaderboard.wagered + excluded.wagered,
    payout = public.game_leaderboard.payout + excluded.payout,
    net = public.game_leaderboard.net + excluded.net,
    best_score = greatest(public.game_leaderboard.best_score, excluded.best_score),
    updated_at = pg_catalog.clock_timestamp();
end;
$$;

create or replace function public.get_game_leaderboard(p_game_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_key text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  v_entries jsonb;
  v_me jsonb;
begin
  if v_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker', 'plinko',
    'dino_run', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash'
  ) then raise exception 'invalid_game'; end if;

  with ranked as (
    select row_number() over (
      order by l.net desc, l.best_score desc, l.wins desc, l.updated_at asc, l.user_id
    )::integer as position,
    l.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
    l.plays, l.wins, l.wagered, l.payout, l.net, l.best_score, l.updated_at,
    l.user_id = v_user_id as is_me
    from public.game_leaderboard l
    left join public.profiles p on p.id = l.user_id
    where l.game_key = v_key
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'plays', r.plays, 'wins', r.wins, 'wagered', r.wagered, 'payout', r.payout,
    'net', r.net, 'best_score', r.best_score, 'updated_at', r.updated_at, 'is_me', r.is_me
  ) order by r.position) filter (where r.position <= 10), '[]'::jsonb)
  into v_entries from ranked r;

  with ranked as (
    select row_number() over (
      order by l.net desc, l.best_score desc, l.wins desc, l.updated_at asc, l.user_id
    )::integer as position,
    l.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
    l.plays, l.wins, l.wagered, l.payout, l.net, l.best_score, l.updated_at,
    l.user_id = v_user_id as is_me
    from public.game_leaderboard l
    left join public.profiles p on p.id = l.user_id
    where l.game_key = v_key
  )
  select pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'plays', r.plays, 'wins', r.wins, 'wagered', r.wagered, 'payout', r.payout,
    'net', r.net, 'best_score', r.best_score, 'updated_at', r.updated_at, 'is_me', r.is_me
  ) into v_me from ranked r where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object('ok', true, 'game_key', v_key, 'entries', v_entries,
    'my_entry', coalesce(v_me, 'null'::jsonb));
end;
$$;

create or replace function public.play_casino_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
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
  v_key text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  v_choice text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_choice, 'spielen')));
  v_label text;
  v_payout bigint := 0;
  v_result jsonb := '{}'::jsonb;
  v_round_id uuid;
  v_entry_id uuid;
  v_reward_id uuid;
  v_a integer; v_b integer; v_c integer;
  v_player integer; v_dealer integer;
  v_hits integer; v_candidate integer;
  v_picks integer[]; v_draws integer[] := array[]::integer[];
  v_target numeric; v_crash numeric;
  v_multiplier integer;
  v_number integer;
  v_i integer;
begin
  if v_key not in ('slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash') then
    raise exception 'invalid_game';
  end if;
  if p_wager is null or p_wager < 1 or p_wager > 1000000 then raise exception 'invalid_game_wager'; end if;
  if not private.game_is_enabled(v_key) then raise exception 'game_disabled'; end if;

  if v_key = 'baccarat' and v_choice not in ('spieler', 'bank', 'unentschieden') then
    raise exception 'invalid_game_choice';
  end if;
  if v_key = 'crash' then
    if v_choice !~ '^[1-9][0-9]*(\.[0-9])?$' then raise exception 'invalid_game_choice'; end if;
    v_target := v_choice::numeric;
    if v_target < 1.1 or v_target > 10 then raise exception 'invalid_game_choice'; end if;
  end if;
  if v_key = 'keno' then
    if v_choice !~ '^([0-9]{1,2},){4}[0-9]{1,2}$' then raise exception 'invalid_game_choice'; end if;
    v_picks := pg_catalog.string_to_array(v_choice, ',')::integer[];
    if exists (select 1 from pg_catalog.unnest(v_picks) x where x < 1 or x > 40)
      or (select count(*) from pg_catalog.unnest(v_picks)) <> 5
      or (select count(distinct x) from pg_catalog.unnest(v_picks) x) <> 5 then
      raise exception 'invalid_game_choice';
    end if;
  end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;
  if exists (select 1 from public.game_rounds r where r.user_id = v_user_id
    and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds') then
    raise exception 'game_too_fast';
  end if;

  if v_key = 'slots' then
    v_label := 'Slot Machine';
    v_a := private.game_random(6); v_b := private.game_random(6); v_c := private.game_random(6);
    if v_a = v_b and v_b = v_c then v_multiplier := case when v_a = 4 then 20 else 8 end;
    elsif v_a = v_b or v_a = v_c or v_b = v_c then v_multiplier := 2;
    else v_multiplier := 0; end if;
    v_payout := p_wager * v_multiplier;
    v_result := pg_catalog.jsonb_build_object('symbols', pg_catalog.jsonb_build_array(v_a, v_b, v_c), 'multiplier', v_multiplier);
  elsif v_key = 'baccarat' then
    v_label := 'Baccarat';
    v_player := private.game_random(10); v_dealer := private.game_random(10);
    if v_player > v_dealer then v_number := 0; elsif v_player < v_dealer then v_number := 1; else v_number := 2; end if;
    if (v_choice = 'spieler' and v_number = 0) then v_payout := p_wager * 2;
    elsif (v_choice = 'bank' and v_number = 1) then v_payout := p_wager * 195 / 100;
    elsif (v_choice = 'unentschieden' and v_number = 2) then v_payout := p_wager * 9;
    end if;
    v_result := pg_catalog.jsonb_build_object('player', v_player, 'dealer', v_dealer, 'winner', case v_number when 0 then 'spieler' when 1 then 'bank' else 'unentschieden' end);
  elsif v_key = 'keno' then
    v_label := 'Keno';
    while pg_catalog.cardinality(v_draws) < 5 loop
      v_candidate := private.game_random(40) + 1;
      if not v_candidate = any(v_draws) then v_draws := pg_catalog.array_append(v_draws, v_candidate); end if;
    end loop;
    select count(*) into v_hits from pg_catalog.unnest(v_picks) p where p = any(v_draws);
    v_multiplier := case v_hits when 5 then 25 when 4 then 10 when 3 then 3 when 2 then 1 else 0 end;
    v_payout := p_wager * v_multiplier;
    v_result := pg_catalog.jsonb_build_object('picks', to_jsonb(v_picks), 'draws', to_jsonb(v_draws), 'hits', v_hits, 'multiplier', v_multiplier);
  elsif v_key = 'wheel' then
    v_label := 'Glücksrad';
    v_number := private.game_random(8);
    v_multiplier := case v_number when 0 then 0 when 1 then 0 when 2 then 1 when 3 then 2 when 4 then 0 when 5 then 3 when 6 then 5 else 10 end;
    v_payout := p_wager * v_multiplier;
    v_result := pg_catalog.jsonb_build_object('segment', v_number, 'multiplier', v_multiplier);
  elsif v_key = 'mines' then
    v_label := 'Mines';
    v_number := private.game_random(9);
    if v_number < 3 then v_multiplier := 0; else v_multiplier := 2; end if;
    v_payout := p_wager * v_multiplier;
    v_result := pg_catalog.jsonb_build_object('mine_count', 3, 'field_count', 9, 'revealed_field', v_number, 'safe', v_multiplier > 0, 'multiplier', v_multiplier);
  elsif v_key = 'bingo' then
    v_label := 'Bingo';
    v_number := private.game_random(75) + 1;
    if private.game_random(8) = 0 then v_multiplier := 12; else v_multiplier := 0; end if;
    v_payout := p_wager * v_multiplier;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'multiplier', v_multiplier, 'bingo', v_multiplier > 0);
  else
    v_label := 'Crash';
    v_crash := (private.game_random(70) + 11)::numeric / 10;
    if v_crash >= v_target then v_payout := round(p_wager * v_target)::bigint; else v_payout := 0; end if;
    v_result := pg_catalog.jsonb_build_object('crash_at', v_crash, 'target', v_target, 'cashed_out', v_payout > 0);
  end if;

  update public.wallets set balance = balance - p_wager, updated_at = pg_catalog.clock_timestamp() where id = v_wallet.id;
  v_entry_id := private.append_transaction(v_user_id, null, p_wager, 'GAME_ENTRY', 'Game Center · ' || v_label || ' · Einsatz');
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = pg_catalog.clock_timestamp() where id = v_wallet.id;
    v_reward_id := private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · ' || v_label || ' · Auszahlung');
  end if;
  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (v_user_id, v_key, v_choice, p_wager, v_payout, v_result) returning id into v_round_id;
  perform private.record_game_leaderboard(v_user_id, v_key, p_wager, v_payout);

  return pg_catalog.jsonb_build_object('ok', true, 'round_id', v_round_id, 'game_key', v_key,
    'choice', v_choice, 'wager', p_wager, 'payout', v_payout, 'net', v_payout - p_wager,
    'result', v_result, 'balance', v_wallet.balance - p_wager + v_payout,
    'entry_transaction_id', v_entry_id, 'reward_transaction_id', v_reward_id);
end;
$$;

revoke all on function private.record_game_leaderboard(uuid, text, bigint, bigint) from public, anon, authenticated;
revoke all on function public.get_game_leaderboard(text) from public, anon, authenticated;
revoke all on function public.play_casino_game(text, text, bigint) from public, anon, authenticated;
grant execute on function public.get_game_leaderboard(text) to authenticated;
grant execute on function public.play_casino_game(text, text, bigint) to authenticated;


-- ===================== 20260827191010_leaderboard_from_game_history.sql =====================
-- Build every casino leaderboard from the authoritative game history.
-- This includes rounds created by older game RPCs as well as the new casino RPC.
create or replace function public.get_game_leaderboard(p_game_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_key text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  v_entries jsonb;
  v_me jsonb;
begin
  if v_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker', 'plinko',
    'dino_run', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash'
  ) then raise exception 'invalid_game'; end if;

  with aggregated as (
    select r.user_id, count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      coalesce(sum(r.wager), 0)::bigint as wagered,
      coalesce(sum(r.payout), 0)::bigint as payout,
      coalesce(sum(r.payout - r.wager), 0)::bigint as net,
      coalesce(max(r.payout), 0)::bigint as best_score,
      max(r.created_at) as updated_at
    from public.game_rounds r
    where r.game_key = v_key
    group by r.user_id
  ), ranked as (
    select row_number() over (order by a.net desc, a.best_score desc, a.wins desc, a.updated_at asc, a.user_id)::integer as position,
      a.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      a.plays, a.wins, a.wagered, a.payout, a.net, a.best_score, a.updated_at, a.user_id = v_user_id as is_me
    from aggregated a left join public.profiles p on p.id = a.user_id
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'plays', r.plays, 'wins', r.wins, 'wagered', r.wagered, 'payout', r.payout,
    'net', r.net, 'best_score', r.best_score, 'updated_at', r.updated_at, 'is_me', r.is_me
  ) order by r.position) filter (where r.position <= 10), '[]'::jsonb)
  into v_entries from ranked r;

  with aggregated as (
    select r.user_id, count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      coalesce(sum(r.wager), 0)::bigint as wagered,
      coalesce(sum(r.payout), 0)::bigint as payout,
      coalesce(sum(r.payout - r.wager), 0)::bigint as net,
      coalesce(max(r.payout), 0)::bigint as best_score,
      max(r.created_at) as updated_at
    from public.game_rounds r where r.game_key = v_key group by r.user_id
  ), ranked as (
    select row_number() over (order by a.net desc, a.best_score desc, a.wins desc, a.updated_at asc, a.user_id)::integer as position,
      a.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      a.plays, a.wins, a.wagered, a.payout, a.net, a.best_score, a.updated_at, a.user_id = v_user_id as is_me
    from aggregated a left join public.profiles p on p.id = a.user_id
  )
  select pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'plays', r.plays, 'wins', r.wins, 'wagered', r.wagered, 'payout', r.payout,
    'net', r.net, 'best_score', r.best_score, 'updated_at', r.updated_at, 'is_me', r.is_me
  ) into v_me from ranked r where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object('ok', true, 'game_key', v_key, 'entries', v_entries,
    'my_entry', coalesce(v_me, 'null'::jsonb));
end;
$$;

revoke all on function public.get_game_leaderboard(text) from public, anon, authenticated;
grant execute on function public.get_game_leaderboard(text) to authenticated;


-- ===================== 20260827191608_fix_crash_target_regex.sql =====================
do $$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef(p.oid)
    into v_definition
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'play_casino_game'
    and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_game_key text, p_choice text, p_wager bigint';

  if v_definition is not null then
    v_definition := pg_catalog.replace(v_definition, '(\\.[0-9])', '(\.[0-9])');
    execute v_definition;
  end if;
end;
$$;


-- ===================== 20260901071439_restrict_account_management_to_primary_owner.sql =====================
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

