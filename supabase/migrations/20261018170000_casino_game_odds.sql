-- Gewinnchancen auch für die Casino-Spiele (Slots, Baccarat, Keno, Glücksrad, Mines, Bingo, Crash).
alter table private.game_odds drop constraint if exists game_odds_game_key_check;
alter table private.game_odds add constraint game_odds_game_key_check check (game_key in (
  'roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash'));

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
  v_factor numeric;
  v_attempt integer := 0;
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

  -- Gewinnchance (Faktor pro Spiel, 100 % = fair): die Runde wird bei Bedarf neu gezogen,
  -- so bleibt jedes angezeigte Ergebnis ein echtes, stimmiges Ergebnis.
  select o.factor into v_factor from private.game_odds o where o.game_key = v_key;
  v_factor := coalesce(v_factor, 1);
  loop
    v_attempt := v_attempt + 1;
    v_payout := 0; v_multiplier := null; v_draws := array[]::integer[];
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
    exit when v_factor = 1 or v_attempt >= 40;
    if v_payout > p_wager and v_factor < 1 and private.game_random(1000000) < (1 - v_factor) * 1000000 then continue; end if;
    if v_payout < p_wager and v_factor > 1 and private.game_random(1000000) < least(1, v_factor - 1) * 1000000 then continue; end if;
    exit;
  end loop;

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

revoke all on function public.play_casino_game(text, text, bigint) from public, anon;
grant execute on function public.play_casino_game(text, text, bigint) to authenticated;

create or replace function public.node_set_game_odds(p_key text, p_odds jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_game text;
  v_factor numeric;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_odds is null or pg_catalog.jsonb_typeof(p_odds) <> 'object' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  for v_game, v_factor in select k, (v #>> '{}')::numeric from pg_catalog.jsonb_each(p_odds) as e(k, v) loop
    if v_game not in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash')
       or v_factor is null or v_factor < 0 or v_factor > 3 then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_odds');
    end if;
    insert into private.game_odds (game_key, factor) values (v_game, pg_catalog.round(v_factor, 2))
    on conflict (game_key) do update set factor = excluded.factor, updated_at = pg_catalog.now();
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'odds', public.get_game_odds());
end;
$$;
revoke all on function public.node_set_game_odds(text, jsonb) from public;
grant execute on function public.node_set_game_odds(text, jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
