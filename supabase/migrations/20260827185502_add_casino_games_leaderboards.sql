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
