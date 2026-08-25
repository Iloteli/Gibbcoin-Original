-- Server-authoritative Game Center. Every round uses the normal GIBB wallet;
-- browser clients can neither choose results nor write balances directly.

alter table public.transactions
  drop constraint if exists transactions_type_check;

alter table public.transactions
  add constraint transactions_type_check check (
    type in (
      'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
      'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN',
      'COIN_PURCHASE', 'GAME_ENTRY', 'GAME_REWARD'
    )
  );

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED'
    )
  );

create table public.game_settings (
  game_key text primary key check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card'
  )),
  label text not null check (char_length(label) between 3 and 40),
  enabled boolean not null default true,
  sort_order smallint not null default 0,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.game_settings (game_key, label, sort_order) values
  ('game_center', 'Gesamtes Game Center', 0),
  ('roulette', 'Roulette', 10),
  ('coin_flip', 'Münzwurf', 20),
  ('blackjack', 'Blackjack', 30),
  ('dice_duel', 'Würfelduell', 40),
  ('high_card', 'High Card', 50)
on conflict (game_key) do nothing;

create table public.game_rounds (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  game_key text not null check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card'
  )),
  choice text,
  wager bigint not null check (wager between 5 and 1000),
  payout bigint not null check (payout between 0 and 36000),
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index game_rounds_user_created_idx
  on public.game_rounds (user_id, created_at desc);

create table public.blackjack_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  wager bigint not null check (wager between 5 and 1000),
  player_cards smallint[] not null,
  dealer_cards smallint[] not null,
  status text not null default 'active' check (status in ('active', 'won', 'lost', 'push')),
  payout bigint not null default 0 check (payout between 0 and 2500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index blackjack_one_active_session_per_user
  on public.blackjack_sessions (user_id)
  where status = 'active';

alter table public.game_settings enable row level security;
alter table public.game_rounds enable row level security;
alter table public.blackjack_sessions enable row level security;

create policy game_settings_authenticated_read
  on public.game_settings for select to authenticated using (true);

create policy game_rounds_own_read
  on public.game_rounds for select to authenticated using ((select auth.uid()) = user_id);

revoke all on table public.game_settings from public, anon, authenticated;
revoke all on table public.game_rounds from public, anon, authenticated;
revoke all on table public.blackjack_sessions from public, anon, authenticated;
grant select on table public.game_settings, public.game_rounds to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_settings'
  ) then
    alter publication supabase_realtime add table public.game_settings;
  end if;
end;
$$;

create or replace function private.game_random(p_max integer)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_bytes bytea;
  v_number bigint;
begin
  if p_max is null or p_max < 1 or p_max > 1000000 then
    raise exception 'invalid_random_range';
  end if;
  v_bytes := extensions.gen_random_bytes(4);
  v_number := pg_catalog.get_byte(v_bytes, 0)::bigint * 16777216
    + pg_catalog.get_byte(v_bytes, 1)::bigint * 65536
    + pg_catalog.get_byte(v_bytes, 2)::bigint * 256
    + pg_catalog.get_byte(v_bytes, 3)::bigint;
  return (v_number % p_max)::integer;
end;
$$;

create or replace function private.blackjack_score(p_cards smallint[])
returns integer
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_card smallint;
  v_total integer := 0;
  v_aces integer := 0;
begin
  foreach v_card in array coalesce(p_cards, array[]::smallint[]) loop
    if v_card = 1 then
      v_total := v_total + 11;
      v_aces := v_aces + 1;
    else
      v_total := v_total + least(v_card, 10);
    end if;
  end loop;
  while v_total > 21 and v_aces > 0 loop
    v_total := v_total - 10;
    v_aces := v_aces - 1;
  end loop;
  return v_total;
end;
$$;

create or replace function private.game_is_enabled(p_game_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.enabled from public.game_settings s where s.game_key = 'game_center'), false)
    and coalesce((select s.enabled from public.game_settings s where s.game_key = p_game_key), false);
$$;

revoke all on function private.game_random(integer) from public, anon, authenticated;
revoke all on function private.blackjack_score(smallint[]) from public, anon, authenticated;
revoke all on function private.game_is_enabled(text) from public, anon, authenticated;

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
    'id', b.id, 'wager', b.wager, 'player_cards', pg_catalog.to_jsonb(b.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(b.dealer_cards[1:1]), 'dealer_hidden', true,
    'status', b.status, 'payout', b.payout,
    'player_score', private.blackjack_score(b.player_cards)
  ) into v_blackjack
  from public.blackjack_sessions b
  where b.user_id = v_user_id and b.status = 'active'
  order by b.created_at desc limit 1;

  return pg_catalog.jsonb_build_object(
    'balance', v_balance,
    'settings', v_settings,
    'recent_rounds', v_rounds,
    'blackjack', v_blackjack
  );
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
begin
  p_game_key := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  p_choice := pg_catalog.lower(pg_catalog.btrim(coalesce(p_choice, '')));
  if p_game_key not in ('roulette', 'coin_flip', 'dice_duel', 'high_card') then
    raise exception 'invalid_game';
  end if;
  if p_wager is null or p_wager < 5 or p_wager > 1000 then
    raise exception 'invalid_game_wager';
  end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  if p_game_key = 'roulette' and p_choice not in ('rot', 'schwarz', '0','1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','18','19','20','21','22','23','24','25','26','27','28','29','30','31','32','33','34','35','36') then
    raise exception 'invalid_game_choice';
  elsif p_game_key = 'coin_flip' and p_choice not in ('kopf', 'zahl') then
    raise exception 'invalid_game_choice';
  elsif p_game_key in ('dice_duel', 'high_card') and p_choice <> 'spielen' then
    raise exception 'invalid_game_choice';
  end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;
  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
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
  else
    v_label := 'High Card';
    v_user_roll := private.game_random(13) + 1;
    v_house_roll := private.game_random(13) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  end if;

  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;
  v_entry_id := private.append_transaction(v_user_id, null, p_wager, 'GAME_ENTRY', 'Game Center · ' || v_label || ' · Einsatz');
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = now() where id = v_wallet.id;
    v_reward_id := private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · ' || v_label || ' · Ergebnis ' || v_result_text);
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

create or replace function public.start_blackjack(p_wager bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_session public.blackjack_sessions%rowtype;
  v_player_score integer;
  v_dealer_score integer;
  v_payout bigint := 0;
  v_status text := 'active';
  v_round_id uuid;
begin
  if p_wager is null or p_wager < 5 or p_wager > 1000 then raise exception 'invalid_game_wager'; end if;
  if not private.game_is_enabled('blackjack') then raise exception 'game_disabled'; end if;
  if exists (select 1 from public.blackjack_sessions b where b.user_id = v_user_id and b.status = 'active') then
    raise exception 'blackjack_session_active';
  end if;
  if exists (
    select 1 from public.blackjack_sessions b
    where b.user_id = v_user_id and b.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;

  v_session.player_cards := array[(private.game_random(13) + 1)::smallint, (private.game_random(13) + 1)::smallint];
  v_session.dealer_cards := array[(private.game_random(13) + 1)::smallint, (private.game_random(13) + 1)::smallint];
  v_player_score := private.blackjack_score(v_session.player_cards);
  v_dealer_score := private.blackjack_score(v_session.dealer_cards);
  if v_player_score = 21 and v_dealer_score = 21 then v_status := 'push'; v_payout := p_wager;
  elsif v_player_score = 21 then v_status := 'won'; v_payout := p_wager * 5 / 2;
  elsif v_dealer_score = 21 then v_status := 'lost'; end if;

  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;
  perform private.append_transaction(v_user_id, null, p_wager, 'GAME_ENTRY', 'Game Center · Blackjack · Einsatz');
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = now() where id = v_wallet.id;
    perform private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · Blackjack · Auszahlung');
  end if;

  insert into public.blackjack_sessions (user_id, wager, player_cards, dealer_cards, status, payout)
  values (v_user_id, p_wager, v_session.player_cards, v_session.dealer_cards, v_status, v_payout)
  returning * into v_session;

  if v_status <> 'active' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (v_user_id, 'blackjack', 'deal', p_wager, v_payout, pg_catalog.jsonb_build_object(
      'player_cards', v_session.player_cards, 'dealer_cards', v_session.dealer_cards,
      'player_score', v_player_score, 'dealer_score', v_dealer_score, 'status', v_status
    )) returning id into v_round_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'wager', p_wager,
    'player_cards', pg_catalog.to_jsonb(v_session.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(case when v_status = 'active' then v_session.dealer_cards[1:1] else v_session.dealer_cards end),
    'dealer_hidden', v_status = 'active', 'status', v_status, 'payout', v_payout,
    'player_score', v_player_score,
    'dealer_score', case when v_status = 'active' then null else v_dealer_score end,
    'balance', v_wallet.balance - p_wager + v_payout, 'round_id', v_round_id
  );
end;
$$;

create or replace function public.blackjack_action(p_session_id uuid, p_action text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_session public.blackjack_sessions%rowtype;
  v_player_score integer;
  v_dealer_score integer;
  v_status text := 'active';
  v_payout bigint := 0;
  v_round_id uuid;
begin
  p_action := pg_catalog.lower(pg_catalog.btrim(coalesce(p_action, '')));
  if p_action not in ('hit', 'stand') then raise exception 'invalid_blackjack_action'; end if;
  select b.* into v_session
  from public.blackjack_sessions b
  where b.id = p_session_id and b.user_id = v_user_id
  for update;
  if v_session.id is null then raise exception 'blackjack_session_not_found'; end if;
  if v_session.status <> 'active' then raise exception 'blackjack_session_finished'; end if;

  if p_action = 'hit' then
    v_session.player_cards := pg_catalog.array_append(v_session.player_cards, (private.game_random(13) + 1)::smallint);
    v_player_score := private.blackjack_score(v_session.player_cards);
    if v_player_score > 21 then v_status := 'lost'; end if;
  else
    v_player_score := private.blackjack_score(v_session.player_cards);
    v_dealer_score := private.blackjack_score(v_session.dealer_cards);
    while v_dealer_score < 17 loop
      v_session.dealer_cards := pg_catalog.array_append(v_session.dealer_cards, (private.game_random(13) + 1)::smallint);
      v_dealer_score := private.blackjack_score(v_session.dealer_cards);
    end loop;
    if v_dealer_score > 21 or v_player_score > v_dealer_score then v_status := 'won'; v_payout := v_session.wager * 2;
    elsif v_player_score = v_dealer_score then v_status := 'push'; v_payout := v_session.wager;
    else v_status := 'lost'; end if;
  end if;

  if v_status = 'active' then
    update public.blackjack_sessions
    set player_cards = v_session.player_cards, updated_at = now()
    where id = v_session.id;
    return pg_catalog.jsonb_build_object(
      'ok', true, 'id', v_session.id, 'wager', v_session.wager,
      'player_cards', pg_catalog.to_jsonb(v_session.player_cards),
      'dealer_cards', pg_catalog.to_jsonb(v_session.dealer_cards[1:1]),
      'dealer_hidden', true, 'status', 'active', 'payout', 0,
      'player_score', v_player_score
    );
  end if;

  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_payout > 0 then
    update public.wallets set balance = balance + v_payout, updated_at = now() where id = v_wallet.id;
    perform private.append_transaction(null, v_user_id, v_payout, 'GAME_REWARD', 'Game Center · Blackjack · Auszahlung');
  end if;
  v_dealer_score := private.blackjack_score(v_session.dealer_cards);
  update public.blackjack_sessions set
    player_cards = v_session.player_cards, dealer_cards = v_session.dealer_cards,
    status = v_status, payout = v_payout, updated_at = now()
  where id = v_session.id;
  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (v_user_id, 'blackjack', p_action, v_session.wager, v_payout, pg_catalog.jsonb_build_object(
    'player_cards', v_session.player_cards, 'dealer_cards', v_session.dealer_cards,
    'player_score', v_player_score, 'dealer_score', v_dealer_score, 'status', v_status
  )) returning id into v_round_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_session.id, 'wager', v_session.wager,
    'player_cards', pg_catalog.to_jsonb(v_session.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(v_session.dealer_cards),
    'dealer_hidden', false, 'status', v_status, 'payout', v_payout,
    'player_score', v_player_score, 'dealer_score', v_dealer_score,
    'balance', v_wallet.balance + v_payout, 'round_id', v_round_id
  );
end;
$$;

create or replace function public.admin_set_game_enabled(
  p_game_key text,
  p_enabled boolean,
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
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  p_game_key := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  select s.enabled into v_old_enabled from public.game_settings s where s.game_key = p_game_key for update;
  if v_old_enabled is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game'); end if;
  if p_enabled is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting'); end if;
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;
  update public.game_settings set enabled = p_enabled, updated_by = v_admin_user_id, updated_at = now()
  where game_key = p_game_key;
  if v_old_enabled is distinct from p_enabled then
    perform private.write_admin_audit(
      v_admin_user_id, null, 'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object('game_key', p_game_key, 'enabled', v_old_enabled),
      pg_catalog.jsonb_build_object('game_key', p_game_key, 'enabled', p_enabled),
      'Game-Center-Schalter geändert'
    );
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'game_key', p_game_key, 'enabled', p_enabled);
end;
$$;

revoke all on function public.get_game_center_state() from public, anon, authenticated;
revoke all on function public.play_instant_game(text, text, bigint) from public, anon, authenticated;
revoke all on function public.start_blackjack(bigint) from public, anon, authenticated;
revoke all on function public.blackjack_action(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_set_game_enabled(text, boolean, text) from public, anon, authenticated;

grant execute on function public.get_game_center_state() to authenticated;
grant execute on function public.play_instant_game(text, text, bigint) to authenticated;
grant execute on function public.start_blackjack(bigint) to authenticated;
grant execute on function public.blackjack_action(uuid, text) to authenticated;
grant execute on function public.admin_set_game_enabled(text, boolean, text) to authenticated;
