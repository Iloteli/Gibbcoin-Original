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
