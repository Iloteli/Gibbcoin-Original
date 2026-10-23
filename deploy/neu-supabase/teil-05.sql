-- GIBB Coin: neues Supabase einrichten – Teil 5 von 5
-- Im SQL Editor des NEUEN Projekts der Reihe nach ausführen (Teil 1, dann 2, …). Jeden Teil nur einmal.

-- ===================== 20261018120000_game_odds.sql =====================
-- Gewinnchancen der Sofort-Spiele einstellbar (Chain-Seite, Recht "Spiele verwalten").
-- Faktor pro Spiel: 100 % = faire Grundchance, 50 % = halb so oft gewinnen, 150 % = 1,5-mal so oft.
-- Gilt für alle gleich (nicht pro Person) und wird den Spielern in den Regeln angezeigt.
create table if not exists private.game_odds (
  game_key text primary key check (game_key in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko')),
  factor numeric(5, 2) not null default 1 check (factor >= 0 and factor <= 3),
  updated_at timestamptz not null default now()
);
alter table private.game_odds enable row level security;

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
  v_factor numeric;
  v_natural numeric;
  v_lose numeric;
  v_target numeric;
  v_roll numeric;
  v_swap integer;
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

  -- Gewinnchance anpassen (Faktor pro Spiel, 100 % = faire Grundchance).
  -- Das Ergebnis wird danach so umgestellt, dass es zur Auszahlung passt.
  select o.factor into v_factor from private.game_odds o where o.game_key = p_game_key;
  v_factor := coalesce(v_factor, 1);
  if v_factor <> 1 then
    v_natural := case p_game_key
      when 'coin_flip' then 0.5
      when 'dice_duel' then 15.0 / 36
      when 'high_card' then 6.0 / 13
      when 'plinko' then 2.0 / 9
      else case when p_choice in ('rot', 'schwarz') then 18.0 / 37 else 1.0 / 37 end
    end;
    v_lose := case p_game_key
      when 'coin_flip' then 0.5
      when 'dice_duel' then 15.0 / 36
      when 'high_card' then 6.0 / 13
      when 'plinko' then 5.0 / 9
      else case when p_choice in ('rot', 'schwarz') then 19.0 / 37 else 36.0 / 37 end
    end;
    v_target := least(v_natural * v_factor, 0.95);
    v_roll := private.game_random(1000000)::numeric / 1000000;
    if v_payout > p_wager and v_target < v_natural and v_roll < 1 - v_target / v_natural then
      -- Gewinn wird zu Verlust
      if p_game_key = 'coin_flip' then
        v_result_text := case p_choice when 'kopf' then 'zahl' else 'kopf' end;
        v_result := pg_catalog.jsonb_build_object('side', v_result_text);
      elsif p_game_key in ('dice_duel', 'high_card') then
        v_swap := v_user_roll; v_user_roll := v_house_roll; v_house_roll := v_swap;
        v_result_text := v_user_roll || ' zu ' || v_house_roll;
        v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
      elsif p_game_key = 'plinko' then
        v_plinko_slot := 2 + private.game_random(5);
        v_plinko_multiplier := 0;
        v_result_text := 'Fach ' || (v_plinko_slot + 1) || ' · 0x';
        v_result := pg_catalog.jsonb_build_object('slot', v_plinko_slot, 'multiplier', 0, 'status', 'lost');
      else
        loop
          v_number := private.game_random(37);
          v_color := case when v_number = 0 then 'grün'
            when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot' else 'schwarz' end;
          exit when p_choice <> v_number::text and p_choice <> v_color;
        end loop;
        v_result_text := v_number || ' · ' || v_color;
        v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
      end if;
      v_payout := 0;
    elsif v_payout = 0 and v_target > v_natural and v_roll < (v_target - v_natural) / v_lose then
      -- Verlust wird zu Gewinn
      if p_game_key = 'coin_flip' then
        v_result_text := p_choice;
        v_result := pg_catalog.jsonb_build_object('side', v_result_text);
        v_payout := p_wager * 2;
      elsif p_game_key in ('dice_duel', 'high_card') then
        v_swap := v_user_roll; v_user_roll := v_house_roll; v_house_roll := v_swap;
        v_result_text := v_user_roll || ' zu ' || v_house_roll;
        v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
        v_payout := p_wager * 2;
      elsif p_game_key = 'plinko' then
        v_plinko_slot := case private.game_random(2) when 0 then 0 else 8 end;
        v_plinko_multiplier := 3;
        v_payout := p_wager * 3;
        v_result_text := 'Fach ' || (v_plinko_slot + 1) || ' · 3x';
        v_result := pg_catalog.jsonb_build_object('slot', v_plinko_slot, 'multiplier', 3, 'status', 'won');
      else
        if p_choice in ('rot', 'schwarz') then
          loop
            v_number := 1 + private.game_random(36);
            v_color := case when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot' else 'schwarz' end;
            exit when v_color = p_choice;
          end loop;
          v_payout := p_wager * 2;
        else
          v_number := p_choice::integer;
          v_color := case when v_number = 0 then 'grün'
            when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot' else 'schwarz' end;
          v_payout := p_wager * 36;
        end if;
        v_result_text := v_number || ' · ' || v_color;
        v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
      end if;
    end if;
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

revoke all on function public.play_instant_game(text, text, bigint) from public, anon;
grant execute on function public.play_instant_game(text, text, bigint) to authenticated;

-- Für die Spiele-Seite: aktuelle Faktoren (alle Spieler sehen sie in den Regeln)
create or replace function public.get_game_odds()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_object_agg(o.game_key, o.factor), '{}'::jsonb) from private.game_odds o;
$$;
revoke all on function public.get_game_odds() from public, anon;
grant execute on function public.get_game_odds() to authenticated;

create or replace function public.node_get_game_odds(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'odds', public.get_game_odds());
end;
$$;
revoke all on function public.node_get_game_odds(text) from public;
grant execute on function public.node_get_game_odds(text) to anon, authenticated, service_role;

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
    if v_game not in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko') or v_factor is null or v_factor < 0 or v_factor > 3 then
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


-- ===================== 20261018150000_game_wager_limits.sql =====================
-- Mindest- und Höchsteinsatz pro Spiel (Chain-Seite, Recht "Spiele verwalten").
-- Dino Run: der Mindesteinsatz ist der Eintritt (Standard 150 GIBB).
create table if not exists private.game_wager_limits (
  game_key text primary key,
  min_wager bigint not null default 1 check (min_wager >= 1),
  max_wager bigint check (max_wager is null or max_wager >= 1),
  updated_at timestamptz not null default now(),
  check (max_wager is null or max_wager >= min_wager)
);
alter table private.game_wager_limits enable row level security;

-- Prüft jeden neuen Einsatz (Sofort- und Casino-Spiele, Blackjack, Poker)
create or replace function private.enforce_game_wager_bounds()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := tg_argv[0];
  v_limit private.game_wager_limits%rowtype;
begin
  if v_key is null then v_key := new.game_key; end if;
  -- Abrechnungszeilen von Blackjack, Poker und Dino Run nicht erneut prüfen
  if tg_table_name = 'game_rounds' and v_key in ('blackjack', 'poker', 'dino_run') then return new; end if;
  select l.* into v_limit from private.game_wager_limits l where l.game_key = v_key;
  if v_limit.game_key is null then return new; end if;
  if new.wager < v_limit.min_wager then raise exception 'game_min_wager:%', v_limit.min_wager; end if;
  if v_limit.max_wager is not null and new.wager > v_limit.max_wager then raise exception 'game_max_wager:%', v_limit.max_wager; end if;
  return new;
end;
$$;
revoke all on function private.enforce_game_wager_bounds() from public, anon, authenticated;

drop trigger if exists enforce_game_wager_bounds on public.game_rounds;
create trigger enforce_game_wager_bounds before insert on public.game_rounds
for each row execute function private.enforce_game_wager_bounds();
drop trigger if exists enforce_blackjack_wager_bounds on public.blackjack_sessions;
create trigger enforce_blackjack_wager_bounds before insert on public.blackjack_sessions
for each row execute function private.enforce_game_wager_bounds('blackjack');
drop trigger if exists enforce_poker_wager_bounds on public.poker_sessions;
create trigger enforce_poker_wager_bounds before insert on public.poker_sessions
for each row execute function private.enforce_game_wager_bounds('poker');

-- Dino Run: Eintritt einstellbar (statt fest 150 GIBB)
alter table public.dino_run_sessions drop constraint if exists dino_run_sessions_wager_check;
alter table public.dino_run_sessions add constraint dino_run_sessions_wager_check check (wager >= 0);

create or replace function private.dino_entry_cost()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select l.min_wager from private.game_wager_limits l where l.game_key = 'dino_run'), 150);
$$;
revoke all on function private.dino_entry_cost() from public, anon, authenticated;

create or replace function public.start_dino_run()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_entry_cost bigint := private.dino_entry_cost();
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
revoke all on function public.start_dino_run() from public, anon;
grant execute on function public.start_dino_run() to authenticated;

-- Für die Spiele-Seite: Grenzen anzeigen und vorab prüfen
create or replace function public.get_game_wager_limits()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_object_agg(l.game_key, pg_catalog.jsonb_build_object('min', l.min_wager, 'max', l.max_wager)), '{}'::jsonb)
  from private.game_wager_limits l;
$$;
revoke all on function public.get_game_wager_limits() from public, anon;
grant execute on function public.get_game_wager_limits() to authenticated;

create or replace function public.node_get_game_wager_limits(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'limits', public.get_game_wager_limits());
end;
$$;
revoke all on function public.node_get_game_wager_limits(text) from public;
grant execute on function public.node_get_game_wager_limits(text) to anon, authenticated, service_role;

-- p_limits: {"coin_flip": {"min": 5, "max": 500}, "dino_run": {"min": 150}, "roulette": null (= keine Grenze)}
create or replace function public.node_set_game_wager_limits(p_key text, p_limits jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_game text;
  v_val jsonb;
  v_min bigint;
  v_max bigint;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_limits is null or pg_catalog.jsonb_typeof(p_limits) <> 'object' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  for v_game, v_val in select k, v from pg_catalog.jsonb_each(p_limits) as e(k, v) loop
    if v_game !~ '^[a-z_]{2,30}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
    if v_val is null or pg_catalog.jsonb_typeof(v_val) = 'null' then
      delete from private.game_wager_limits where game_key = v_game;
      continue;
    end if;
    v_min := coalesce(nullif(v_val ->> 'min', '')::bigint, 1);
    v_max := nullif(v_val ->> 'max', '')::bigint;
    if v_min < 1 or v_min > 1000000 or (v_max is not null and (v_max < v_min or v_max > 100000000)) then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_limits', 'game', v_game);
    end if;
    insert into private.game_wager_limits (game_key, min_wager, max_wager) values (v_game, v_min, v_max)
    on conflict (game_key) do update set min_wager = excluded.min_wager, max_wager = excluded.max_wager, updated_at = pg_catalog.now();
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'limits', public.get_game_wager_limits());
end;
$$;
revoke all on function public.node_set_game_wager_limits(text, jsonb) from public;
grant execute on function public.node_set_game_wager_limits(text, jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261018170000_casino_game_odds.sql =====================
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


-- ===================== 20261018190000_registration_switch.sql =====================
-- Selbst-Registrierung per Schalter auf der Chain-Seite ein-/ausschalten.
-- Aus (Standard): nur vom Owner freigegebene E-Mails dürfen ein Konto anlegen.
-- An: jeder kann sich auf der Hauptseite registrieren.
create or replace function private.registration_open()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value ->> 'enabled')::boolean from private.admin_control_settings s where s.key = 'registration'), false);
$$;
revoke all on function private.registration_open() from public, anon, authenticated;

create or replace function private.block_public_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Nur Registrierungen über die Supabase-Anmeldung (Rolle supabase_auth_admin) prüfen
  if current_user::text <> 'supabase_auth_admin' and session_user::text <> 'supabase_auth_admin' then
    return new;
  end if;
  if private.registration_open() then return new; end if;
  if exists (
    select 1 from private.signup_allowlist a
    where a.email = pg_catalog.lower(coalesce(new.email, '')) and a.expires_at > pg_catalog.now()
  ) then
    delete from private.signup_allowlist where email = pg_catalog.lower(coalesce(new.email, ''));
    return new;
  end if;
  raise exception using errcode = '42501', message = 'signup_disabled';
end;
$$;
revoke all on function private.block_public_signup() from public, anon, authenticated;

create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb),
    'registration_enabled', private.registration_open()
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_registration(p_key text, p_enabled boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  insert into private.admin_control_settings (key, value) values ('registration', pg_catalog.jsonb_build_object('enabled', coalesce(p_enabled, false)))
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'enabled', coalesce(p_enabled, false));
end;
$$;
revoke all on function public.node_set_registration(text, boolean) from public;
grant execute on function public.node_set_registration(text, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261018210000_site_footer.sql =====================
-- "Made by"-Fusszeile der Hauptseite, bearbeitbar auf der Chain-Seite.
create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb),
    'registration_enabled', private.registration_open(),
    'footer_text', coalesce((select s.value ->> 'text' from private.admin_control_settings s where s.key = 'site_footer'), 'Made by Ilja')
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_footer(p_key text, p_text text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_text text := pg_catalog.left(pg_catalog.btrim(coalesce(p_text, '')), 120);
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  insert into private.admin_control_settings (key, value) values ('site_footer', pg_catalog.jsonb_build_object('text', v_text))
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'text', v_text);
end;
$$;
revoke all on function public.node_set_footer(text, text) from public;
grant execute on function public.node_set_footer(text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261018230000_site_design.sql =====================
-- Design der Hauptseite (Farbwelt, Standard-Modus, Animationen), eingestellt auf der Chain-Seite.
create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb),
    'registration_enabled', private.registration_open(),
    'footer_text', coalesce((select s.value ->> 'text' from private.admin_control_settings s where s.key = 'site_footer'), 'Made by Ilja'),
    'design', coalesce((select s.value from private.admin_control_settings s where s.key = 'site_design'), '{"accent":"neon","mode":"dark","motion":"full"}'::jsonb)
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_site_design(p_key text, p_accent text, p_mode text, p_motion text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_value := pg_catalog.jsonb_build_object(
    'accent', case when p_accent in ('neon', 'emerald', 'violet', 'gold') then p_accent else 'neon' end,
    'mode', case when p_mode in ('dark', 'light') then p_mode else 'dark' end,
    'motion', case when p_motion in ('full', 'reduced', 'off') then p_motion else 'full' end
  );
  insert into private.admin_control_settings (key, value) values ('site_design', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'design', v_value);
end;
$$;
revoke all on function public.node_set_site_design(text, text, text, text) from public;
grant execute on function public.node_set_site_design(text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019000000_node_profile.sql =====================
-- Profil der Hauptseite (Anzeigename, Benutzername, Über mich, Farbe, Bild) auch auf der Chain-Seite bearbeiten.
-- Die Chain-Seite ruft das mit ihrem Schlüssel auf – und nur für das eigene, angemeldete Konto.
create or replace function public.node_get_profile(p_key text, p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.profiles%rowtype;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select * into v_row from public.profiles where id = p_user;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'profile', pg_catalog.jsonb_build_object(
    'username', v_row.username, 'display_name', v_row.display_name, 'bio', v_row.bio,
    'profile_color', v_row.profile_color, 'avatar_url', v_row.avatar_url));
end;
$$;
revoke all on function public.node_get_profile(text, uuid) from public;
grant execute on function public.node_get_profile(text, uuid) to anon, authenticated, service_role;

-- Gleiche Regeln wie update_my_profile_atomic. Das Bild kann hier nur behalten oder entfernt werden.
create or replace function public.node_update_profile(p_key text, p_user uuid, p_username text, p_display_name text, p_bio text, p_profile_color text, p_remove_avatar boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
  v_name text := pg_catalog.btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(pg_catalog.btrim(coalesce(p_bio, '')), '');
  v_color text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_profile_color, '')));
  v_row public.profiles%rowtype;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_username'); end if;
  if pg_catalog.char_length(v_name) not between 2 and 60 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_display_name'); end if;
  if v_bio is not null and pg_catalog.char_length(v_bio) > 180 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_bio'); end if;
  if v_color !~ '^#[0-9a-f]{6}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_profile_color'); end if;
  if exists (select 1 from public.profiles where pg_catalog.lower(username) = v_username and id <> p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;
  update public.profiles
  set username = v_username, display_name = v_name, bio = v_bio, profile_color = v_color,
      avatar_url = case when coalesce(p_remove_avatar, false) then null else avatar_url end
  where id = p_user
  returning * into v_row;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'profile', pg_catalog.jsonb_build_object(
    'username', v_row.username, 'display_name', v_row.display_name, 'bio', v_row.bio,
    'profile_color', v_row.profile_color, 'avatar_url', v_row.avatar_url));
exception when unique_violation then
  return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
end;
$$;
revoke all on function public.node_update_profile(text, uuid, text, text, text, text, boolean) from public;
grant execute on function public.node_update_profile(text, uuid, text, text, text, text, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019010000_site_style.sql =====================
-- Design der Hauptseite: zusätzlich "Original" (erstes grünes Design) oder "Neu" (Neon Glass).
drop function if exists public.node_set_site_design(text, text, text, text);

create or replace function public.node_set_site_design(p_key text, p_accent text, p_mode text, p_motion text, p_style text default 'new')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_value := pg_catalog.jsonb_build_object(
    'accent', case when p_accent in ('neon', 'emerald', 'violet', 'gold') then p_accent else 'neon' end,
    'mode', case when p_mode in ('dark', 'light') then p_mode else 'dark' end,
    'motion', case when p_motion in ('full', 'reduced', 'off') then p_motion else 'full' end,
    'style', case when p_style = 'original' then 'original' else 'new' end
  );
  insert into private.admin_control_settings (key, value) values ('site_design', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'design', v_value);
end;
$$;
revoke all on function public.node_set_site_design(text, text, text, text, text) from public;
grant execute on function public.node_set_site_design(text, text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019020000_node_list_users_avatars.sql =====================
-- node_list_users liefert auch Profilbild und Profilfarbe, damit die Chain-Seite sie zeigen kann.
create or replace function public.node_list_users(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'users', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', p.id, 'username', p.username, 'display_name', p.display_name, 'role', p.role,
      'balance', coalesce(w.balance, 0), 'status', coalesce(w.status, 'active'),
      'is_primary', private.is_ilja(p.id),
      'avatar_url', p.avatar_url, 'profile_color', p.profile_color
    ) order by pg_catalog.lower(coalesce(nullif(p.username, ''), p.display_name, '')))
    from public.profiles p left join public.wallets w on w.user_id = p.id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_users(text) from public;
grant execute on function public.node_list_users(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019030000_avatar_block.sql =====================
-- Profilbild für einzelne Benutzer sperren (eingestellt auf der Chain-Seite).
-- Gesperrt = das Profilbild wird entfernt und ein neues wird nicht gespeichert.
create table if not exists private.avatar_blocks (
  user_id uuid primary key,
  created_at timestamptz not null default pg_catalog.now()
);
revoke all on table private.avatar_blocks from public, anon, authenticated;

create or replace function private.enforce_avatar_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.avatar_url is not null and exists (select 1 from private.avatar_blocks b where b.user_id = new.id) then
    new.avatar_url := null;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_avatar_block on public.profiles;
create trigger enforce_avatar_block
  before insert or update of avatar_url on public.profiles
  for each row execute function private.enforce_avatar_block();

create or replace function public.node_set_avatar_blocked(p_key text, p_user uuid, p_blocked boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if coalesce(p_blocked, false) then
    insert into private.avatar_blocks (user_id) values (p_user) on conflict (user_id) do nothing;
    update public.profiles set avatar_url = null where id = p_user and avatar_url is not null;
  else
    delete from private.avatar_blocks where user_id = p_user;
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'blocked', coalesce(p_blocked, false));
end;
$$;
revoke all on function public.node_set_avatar_blocked(text, uuid, boolean) from public;
grant execute on function public.node_set_avatar_blocked(text, uuid, boolean) to anon, authenticated, service_role;

-- Für die Hauptseite: darf ich ein Profilbild haben?
create or replace function public.get_my_avatar_blocked()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.avatar_blocks b where b.user_id = auth.uid());
$$;
revoke all on function public.get_my_avatar_blocked() from public, anon;
grant execute on function public.get_my_avatar_blocked() to authenticated;

create or replace function public.node_list_users(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'users', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', p.id, 'username', p.username, 'display_name', p.display_name, 'role', p.role,
      'balance', coalesce(w.balance, 0), 'status', coalesce(w.status, 'active'),
      'is_primary', private.is_ilja(p.id),
      'avatar_url', p.avatar_url, 'profile_color', p.profile_color,
      'avatar_blocked', exists (select 1 from private.avatar_blocks b where b.user_id = p.id)
    ) order by pg_catalog.lower(coalesce(nullif(p.username, ''), p.display_name, '')))
    from public.profiles p left join public.wallets w on w.user_id = p.id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_users(text) from public;
grant execute on function public.node_list_users(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019040000_avatars_for_others.sql =====================
-- Profilbilder für andere sichtbar: Empfängersuche (Senden) und Community-Rangliste liefern das Bild mit.
drop function if exists public.search_users(text);
create function public.search_users(p_query text)
returns table (user_id uuid, username text, display_name text, avatar_url text, profile_color text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_needle text := pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(coalesce(p_query, '')), '@'));
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if pg_catalog.char_length(v_needle) < 2 then return; end if;
  return query
  select p.id, coalesce(p.username, ''), p.display_name, p.avatar_url, p.profile_color
  from public.profiles p
  join public.wallets w on w.user_id = p.id and w.status = 'active'
  where p.id <> auth.uid()
    and p.email not like '%@gibbcoin.invalid'
    and (pg_catalog.strpos(pg_catalog.lower(coalesce(p.username, '')), v_needle) > 0
      or pg_catalog.strpos(pg_catalog.lower(p.display_name), v_needle) > 0)
  order by (pg_catalog.lower(coalesce(p.username, '')) = v_needle) desc, p.display_name
  limit 10;
end;
$$;
revoke all on function public.search_users(text) from public, anon;
grant execute on function public.search_users(text) to authenticated;


create or replace function public.get_community_leaderboard(p_period text default 'week')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_period text := case when p_period in ('week', 'month', 'all') then p_period else 'week' end;
  v_since timestamptz;
  v_rows jsonb;
  v_mine jsonb;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  v_since := case v_period
    when 'week' then pg_catalog.date_trunc('week', pg_catalog.now())
    when 'month' then pg_catalog.date_trunc('month', pg_catalog.now())
    else '-infinity'::timestamptz end;

  with scores as (
    select p.id as user_id,
           coalesce(nullif(p.username, ''), p.display_name) as username,
           p.display_name,
           p.profile_color,
           (case when exists (select 1 from private.avatar_blocks ab where ab.user_id = p.id) then null else p.avatar_url end) as avatar_url,
           p.equipped_title,
           (select count(*) from public.user_challenges c where c.user_id = p.id and c.claimed_at >= v_since) as achievements,
           (select count(*) from public.daily_task_claims d where d.user_id = p.id and d.created_at >= v_since) as tasks,
           (select count(*) from public.daily_rewards r where r.user_id = p.id and r.created_at >= v_since) as check_ins,
           (select count(*) from public.blocks b where b.miner_user_id = p.id and b.height > 0 and b.mined_at >= v_since) as blocks
    from public.profiles p
    join public.wallets w on w.user_id = p.id and w.status = 'active'
  ), ranked as (
    select s.*,
           s.achievements * 10 + s.tasks * 3 + s.blocks * 2 + s.check_ins as points,
           pg_catalog.rank() over (order by s.achievements * 10 + s.tasks * 3 + s.blocks * 2 + s.check_ins desc) as rank
    from scores s
  )
  select
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by x.rank, x.username)
              from (select * from ranked where points > 0 order by rank, username limit 20) x), '[]'::jsonb),
    (select pg_catalog.to_jsonb(r) from ranked r where r.user_id = v_me)
  into v_rows, v_mine;

  return pg_catalog.jsonb_build_object('period', v_period, 'since', case when v_period = 'all' then null else v_since end, 'entries', v_rows, 'me', v_mine);
end;
$$;

revoke all on function public.get_community_leaderboard(text) from public, anon;
grant execute on function public.get_community_leaderboard(text) to authenticated;


notify pgrst, 'reload schema';


-- ===================== 20261019050000_delete_support_case.sql =====================
-- Support-Fälle auf der Chain-Seite löschen (Admin-PIN nötig, wie beim Ändern).
create or replace function public.node_delete_support_case(p_key text, p_case uuid, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_pin text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_owner := private.node_act_as_owner();
  v_pin := private.check_admin_pin(v_owner, p_pin);
  if v_pin <> 'ok' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin); end if;
  delete from public.support_cases where id = p_case;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'case_not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_delete_support_case(text, uuid, text) from public;
grant execute on function public.node_delete_support_case(text, uuid, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019060000_owner_login_by_username.sql =====================
-- Chain-Seite: Owner der Hauptseite können sich auch mit ihrem Benutzernamen (statt E-Mail) anmelden.
-- Gibt die E-Mail nur für Owner (super_admin) zurück und nur an die Chain-Seite (Schlüssel).
create or replace function public.node_owner_login_email(p_key text, p_username text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select u.email into v_email
  from public.profiles p join auth.users u on u.id = p.id
  where pg_catalog.lower(p.username) = pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')))
    and p.role = 'super_admin'
  limit 1;
  if v_email is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'email', v_email);
end;
$$;
revoke all on function public.node_owner_login_email(text, text) from public;
grant execute on function public.node_owner_login_email(text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261019070000_reserved_usernames.sql =====================
-- Benutzernamen über beide Websites eindeutig: Namen der Chain-Konten sind auf der Hauptseite reserviert.
-- Die Chain-Seite schickt ihre Namen regelmässig (node_set_reserved_usernames).
create table if not exists private.reserved_usernames (
  username text primary key
);
revoke all on table private.reserved_usernames from public, anon, authenticated;

create or replace function public.node_set_reserved_usernames(p_key text, p_names text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  delete from private.reserved_usernames;
  insert into private.reserved_usernames (username)
  select distinct pg_catalog.lower(pg_catalog.btrim(n)) from pg_catalog.unnest(coalesce(p_names, '{}'::text[])) n
  where pg_catalog.btrim(n) <> '';
  return pg_catalog.jsonb_build_object('ok', true, 'count', (select pg_catalog.count(*) from private.reserved_usernames));
end;
$$;
revoke all on function public.node_set_reserved_usernames(text, text[]) from public;
grant execute on function public.node_set_reserved_usernames(text, text[]) to anon, authenticated, service_role;

-- Beim Ändern des Benutzernamens: Name eines Chain-Kontos = vergeben
create or replace function private.enforce_reserved_username()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.username is distinct from old.username and new.username is not null
     and exists (select 1 from private.reserved_usernames r where r.username = pg_catalog.lower(new.username)) then
    raise exception 'username_taken' using errcode = 'unique_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists enforce_reserved_username on public.profiles;
create trigger enforce_reserved_username
  before update of username on public.profiles
  for each row execute function private.enforce_reserved_username();

notify pgrst, 'reload schema';


-- ===================== 20261020080000_leaderboard_current_names.sql =====================
-- Bestenliste (Blockchain): aktueller Benutzername statt des Namens beim Minen,
-- gelöschte Konten fallen heraus (ihre Blöcke bleiben in der Kette gültig).
do $migration$
declare
  v_def text;
  v_old text := $o$    select miner_user_id, max(miner_label) as miner_label, count(*) as blocks, sum(reward) as reward
    from public.blocks where miner_user_id is not null
    group by miner_user_id order by count(*) desc, sum(reward) desc limit 5$o$;
  v_new text := $n$    select b.miner_user_id, coalesce(nullif(max(p.username), ''), max(p.display_name), max(b.miner_label)) as miner_label, count(*) as blocks, sum(b.reward) as reward
    from public.blocks b join public.profiles p on p.id = b.miner_user_id -- leaderboard_current_names
    group by b.miner_user_id order by count(*) desc, sum(b.reward) desc limit 5$n$;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'leaderboard_current_names') > 0 then return; end if;
  if pg_catalog.strpos(v_def, v_old) = 0 then
    raise warning 'get_blockchain_overview: Bestenliste nicht gefunden – unverändert gelassen';
    return;
  end if;
  execute pg_catalog.replace(v_def, v_old, v_new);
end;
$migration$;

notify pgrst, 'reload schema';


-- ===================== 20261020090000_leaderboard_hide_deleted.sql =====================
-- Bestenliste (Blockchain), robuste Version: gelöschte Konten ausblenden und aktuelle Benutzernamen zeigen.
-- Funktioniert auch, wenn die Funktion andere Leerzeichen/Zeilenumbrüche hat. Mehrfach ausführen ist sicher.
do $migration$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'leaderboard_current_names') > 0 then return; end if;
  v_new := pg_catalog.regexp_replace(v_def,
    'from\s+public\.blocks\s+where\s+miner_user_id\s+is\s+not\s+null',
    'from public.blocks where miner_user_id is not null and exists (select 1 from public.profiles lp where lp.id = miner_user_id) /* leaderboard_current_names */', 'i');
  if v_new = v_def then
    raise warning 'get_blockchain_overview: Bestenliste nicht gefunden – unverändert gelassen';
    return;
  end if;
  v_new := pg_catalog.regexp_replace(v_new,
    'max\(\s*miner_label\s*\)\s+as\s+miner_label',
    $r$coalesce((select nullif(lp.username, '') from public.profiles lp where lp.id = miner_user_id), max(miner_label)) as miner_label$r$, 'i');
  execute v_new;
end;
$migration$;

notify pgrst, 'reload schema';

select case when pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), 'leaderboard_current_names') > 0
  then 'OK: Bestenliste zeigt nur noch bestehende Konten' else 'FEHLER: Bestenliste nicht geändert – Ausgabe an Claude schicken' end as status;


-- ===================== 20261020100000_custom_ban_and_logout.sql =====================
-- Chain-Seite: Bannen mit frei wählbarer Dauer und Konten überall abmelden.
-- Abmelden = alle Sitzungen der Hauptseite widerrufen (auth.sessions / Refresh-Tokens) und den Zeitpunkt merken;
-- die Hauptseite fragt ihn regelmässig ab (my_session_revoked_at) und meldet sich dann sofort ab.

create table if not exists private.session_revocations (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  revoked_at timestamptz not null default pg_catalog.now()
);
revoke all on table private.session_revocations from public, anon, authenticated;

create or replace function private.revoke_user_sessions(p_user uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  insert into private.session_revocations (user_id, revoked_at) values (p_user, pg_catalog.now())
  on conflict (user_id) do update set revoked_at = excluded.revoked_at;
  begin
    delete from auth.refresh_tokens where user_id = p_user::text;
  exception when others then null; -- ältere/abweichende Auth-Tabellen
  end;
  begin
    delete from auth.sessions where user_id = p_user;
  exception when others then null;
  end;
end;
$$;
revoke all on function private.revoke_user_sessions(uuid) from public, anon, authenticated;

-- Hauptseite: wurde meine Anmeldung widerrufen? (Zeitpunkt oder null)
create or replace function public.my_session_revoked_at()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select r.revoked_at from private.session_revocations r where r.user_id = auth.uid();
$$;
revoke all on function public.my_session_revoked_at() from public, anon;
grant execute on function public.my_session_revoked_at() to authenticated;

-- Chain-Seite: Konto überall abmelden (geschützte Konten wie Ilja ausgenommen)
create or replace function public.node_logout_user(p_key text, p_user uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or not exists (select 1 from public.profiles p where p.id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found'); end if;
  if private.is_protected_account(p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected'); end if;
  perform private.revoke_user_sessions(p_user);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_logout_user(text, uuid) from public;
grant execute on function public.node_logout_user(text, uuid) to anon, authenticated, service_role;

-- Bannen: Dauer frei wählbar (1 Minute bis 5 Jahre, null = dauerhaft); Bann meldet das Konto auch sofort ab
create or replace function public.node_set_account_status(p_key text, p_user uuid, p_status text, p_minutes integer, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_until timestamptz;
  v_reason text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or p_status not in ('active', 'locked') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  if p_minutes is not null and (p_minutes < 1 or p_minutes > 2628000) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_lock_duration'); end if;
  v_owner := private.node_act_as_owner();
  if p_user = v_owner then return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_lock_own_account'); end if;
  if p_status = 'locked' and private.is_protected_account(p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected');
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found'); end if;
  v_until := case when p_status = 'locked' and p_minutes is not null then pg_catalog.now() + pg_catalog.make_interval(mins => p_minutes) end;
  v_reason := case when p_status = 'locked'
    then coalesce(nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_reason, '')), 120), ''), 'Konto auf der Chain-Seite gebannt')
    else 'Bann auf der Chain-Seite aufgehoben' end;
  begin
    update auth.users set banned_until = case when p_status = 'locked' then coalesce(v_until, pg_catalog.now() + interval '100 years') end
    where id = p_user;
    perform public.admin_apply_wallet_status_v2(v_owner, p_user, p_status, v_reason, v_until);
    if p_status = 'locked' then perform private.revoke_user_sessions(p_user); end if;
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'status', p_status, 'locked_until', v_until);
end;
$$;
revoke all on function public.node_set_account_status(text, uuid, text, integer, text) from public;
grant execute on function public.node_set_account_status(text, uuid, text, integer, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261023010000_shop_checkout_and_payouts.sql =====================
-- Kasse für Läden (mit GIBB bezahlen per QR-Code) und Auszahlung von Credits als echtes Geld.
-- Läden schaltet der Owner auf der Chain-Seite frei. Auszahlungen bezahlt der Owner per Überweisung
-- und markiert sie danach als erledigt (keine Gebühren, kein Zahlungsanbieter).

-- ---------- Läden ----------
create table if not exists private.merchants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  shop_name text not null check (char_length(shop_name) between 2 and 40),
  enabled boolean not null default true,
  created_at timestamptz not null default pg_catalog.now()
);
revoke all on table private.merchants from public, anon, authenticated;

create table if not exists public.shop_invoices (
  id uuid primary key default extensions.gen_random_uuid(),
  merchant_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount between 1 and 100000),
  note text check (note is null or char_length(note) <= 80),
  status text not null default 'open' check (status in ('open', 'paid', 'cancelled')),
  payer_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null default pg_catalog.now() + interval '10 minutes',
  paid_at timestamptz
);
create index if not exists shop_invoices_merchant_idx on public.shop_invoices (merchant_id, created_at desc);
alter table public.shop_invoices enable row level security;
alter table public.shop_invoices force row level security;
revoke all on table public.shop_invoices from public, anon, authenticated;

create or replace function private.shop_name_of(p_user uuid)
returns text language sql stable security definer set search_path = ''
as $$ select m.shop_name from private.merchants m where m.user_id = p_user and m.enabled; $$;
revoke all on function private.shop_name_of(uuid) from public, anon, authenticated;

-- Bin ich ein Laden?
create or replace function public.shop_status()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_name text := private.shop_name_of(auth.uid());
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  return pg_catalog.jsonb_build_object('is_merchant', v_name is not null, 'shop_name', v_name);
end;
$$;

-- Kasse: Rechnung mit Betrag erstellen (gilt 10 Minuten, nur einmal bezahlbar)
create or replace function public.shop_create_invoice(p_amount bigint, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_inv public.shop_invoices%rowtype;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  if private.shop_name_of(v_me) is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_a_shop'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount'); end if;
  -- alte offene Rechnungen dieses Ladens schliessen
  update public.shop_invoices set status = 'cancelled' where merchant_id = v_me and status = 'open';
  insert into public.shop_invoices (merchant_id, amount, note)
  values (v_me, p_amount, nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_note, '')), 80), ''))
  returning * into v_inv;
  return pg_catalog.jsonb_build_object('ok', true, 'id', v_inv.id, 'amount', v_inv.amount, 'expires_at', v_inv.expires_at);
end;
$$;

-- Kasse: Stand der Rechnung (nur der eigene Laden)
create or replace function public.shop_invoice_status(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_inv public.shop_invoices%rowtype; v_payer text;
begin
  select * into v_inv from public.shop_invoices where id = p_id and merchant_id = auth.uid();
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select coalesce(nullif(p.username, ''), p.display_name) into v_payer from public.profiles p where p.id = v_inv.payer_id;
  return pg_catalog.jsonb_build_object('ok', true, 'status',
    case when v_inv.status = 'open' and v_inv.expires_at < pg_catalog.now() then 'expired' else v_inv.status end,
    'amount', v_inv.amount, 'payer', v_payer, 'paid_at', v_inv.paid_at);
end;
$$;

create or replace function public.shop_cancel_invoice(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
begin
  update public.shop_invoices set status = 'cancelled' where id = p_id and merchant_id = auth.uid() and status = 'open';
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

-- Kunde: Was soll ich bezahlen?
create or replace function public.shop_invoice_info(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_inv public.shop_invoices%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select * into v_inv from public.shop_invoices where id = p_id;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'shop_name', coalesce(private.shop_name_of(v_inv.merchant_id), 'Laden'),
    'amount', v_inv.amount, 'note', v_inv.note,
    'status', case when v_inv.status = 'open' and v_inv.expires_at < pg_catalog.now() then 'expired' else v_inv.status end,
    'own', v_inv.merchant_id = auth.uid());
end;
$$;

-- Kunde: bezahlen (normale GIBB-Überweisung an den Laden, landet in der Kette)
create or replace function public.shop_pay_invoice(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_inv public.shop_invoices%rowtype;
  v_shop text;
  v_result jsonb;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  select * into v_inv from public.shop_invoices where id = p_id for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_inv.status = 'paid' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'already_paid'); end if;
  if v_inv.status <> 'open' or v_inv.expires_at < pg_catalog.now() then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invoice_expired'); end if;
  if v_inv.merchant_id = v_me then return pg_catalog.jsonb_build_object('ok', false, 'error', 'own_invoice'); end if;
  v_shop := private.shop_name_of(v_inv.merchant_id);
  if v_shop is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_a_shop'); end if;
  v_result := public.transfer_coins_with_guardian_approval(v_inv.merchant_id, v_inv.amount, pg_catalog.left('Einkauf bei ' || v_shop || coalesce(': ' || v_inv.note, ''), 160));
  if coalesce(v_result ->> 'status', '') = 'pending' then
    raise exception 'shop_payment_needs_approval';
  end if;
  update public.shop_invoices set status = 'paid', payer_id = v_me, paid_at = pg_catalog.now() where id = p_id;
  return pg_catalog.jsonb_build_object('ok', true, 'shop_name', v_shop, 'amount', v_inv.amount);
end;
$$;

-- Kasse: letzte Verkäufe
create or replace function public.shop_list_sales(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', i.id, 'amount', i.amount, 'note', i.note, 'paid_at', i.paid_at,
    'payer', (select coalesce(nullif(p.username, ''), p.display_name) from public.profiles p where p.id = i.payer_id)
  ) order by i.paid_at desc), '[]'::jsonb)
  from (select * from public.shop_invoices where merchant_id = auth.uid() and status = 'paid'
        order by paid_at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) i;
$$;

revoke all on function public.shop_status() from public, anon;
revoke all on function public.shop_create_invoice(bigint, text) from public, anon;
revoke all on function public.shop_invoice_status(uuid) from public, anon;
revoke all on function public.shop_cancel_invoice(uuid) from public, anon;
revoke all on function public.shop_invoice_info(uuid) from public, anon;
revoke all on function public.shop_pay_invoice(uuid) from public, anon;
revoke all on function public.shop_list_sales(integer) from public, anon;
grant execute on function public.shop_status() to authenticated;
grant execute on function public.shop_create_invoice(bigint, text) to authenticated;
grant execute on function public.shop_invoice_status(uuid) to authenticated;
grant execute on function public.shop_cancel_invoice(uuid) to authenticated;
grant execute on function public.shop_invoice_info(uuid) to authenticated;
grant execute on function public.shop_pay_invoice(uuid) to authenticated;
grant execute on function public.shop_list_sales(integer) to authenticated;

-- Chain-Seite: Läden verwalten
create or replace function public.node_list_merchants(p_key text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'merchants', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'user_id', m.user_id, 'shop_name', m.shop_name, 'enabled', m.enabled,
      'username', p.username,
      'sales', (select pg_catalog.count(*) from public.shop_invoices i where i.merchant_id = m.user_id and i.status = 'paid'),
      'revenue', (select coalesce(sum(i.amount), 0) from public.shop_invoices i where i.merchant_id = m.user_id and i.status = 'paid')
    ) order by m.shop_name)
    from private.merchants m join public.profiles p on p.id = m.user_id
  ), '[]'::jsonb));
end;
$$;

create or replace function public.node_set_merchant(p_key text, p_user uuid, p_shop_name text, p_enabled boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_name text := pg_catalog.btrim(coalesce(p_shop_name, ''));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p_enabled is null then
    delete from private.merchants where user_id = p_user;
    return pg_catalog.jsonb_build_object('ok', true, 'removed', true);
  end if;
  if pg_catalog.char_length(v_name) not between 2 and 40 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_shop_name'); end if;
  insert into private.merchants (user_id, shop_name, enabled) values (p_user, v_name, p_enabled)
  on conflict (user_id) do update set shop_name = excluded.shop_name, enabled = excluded.enabled;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_list_merchants(text) from public;
revoke all on function public.node_set_merchant(text, uuid, text, boolean) from public;
grant execute on function public.node_list_merchants(text) to anon, authenticated, service_role;
grant execute on function public.node_set_merchant(text, uuid, text, boolean) to anon, authenticated, service_role;

-- ---------- Auszahlung von Credits ----------
create table if not exists public.payout_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  rappen bigint not null check (rappen > 0),
  iban text not null check (char_length(iban) between 15 and 34),
  holder text not null check (char_length(holder) between 2 and 80),
  status text not null default 'pending' check (status in ('pending', 'paid', 'rejected', 'cancelled')),
  created_at timestamptz not null default pg_catalog.now(),
  decided_at timestamptz
);
create index if not exists payout_requests_user_idx on public.payout_requests (user_id, created_at desc);
alter table public.payout_requests enable row level security;
alter table public.payout_requests force row level security;
revoke all on table public.payout_requests from public, anon, authenticated;

create or replace function private.payout_settings()
returns jsonb language sql stable security definer set search_path = ''
as $$ select coalesce((select s.value from private.admin_control_settings s where s.key = 'payouts'), '{"enabled":false,"min_rappen":500}'::jsonb); $$;
revoke all on function private.payout_settings() from public, anon, authenticated;

create or replace function public.get_payout_state()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_me uuid := auth.uid(); v_set jsonb := private.payout_settings();
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  return pg_catalog.jsonb_build_object(
    'enabled', coalesce((v_set ->> 'enabled')::boolean, false),
    'min_rappen', coalesce((v_set ->> 'min_rappen')::bigint, 500),
    'credits', (select w.credits from public.wallets w where w.user_id = v_me),
    'requests', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', r.id, 'rappen', r.rappen, 'status', r.status, 'created_at', r.created_at,
        'iban_end', pg_catalog.right(r.iban, 4)) order by r.created_at desc)
      from (select * from public.payout_requests where user_id = v_me order by created_at desc limit 10) r), '[]'::jsonb));
end;
$$;

-- Credits werden sofort reserviert (abgezogen); bei Ablehnen/Abbrechen kommen sie zurück.
create or replace function public.request_payout(p_rappen bigint, p_iban text, p_holder text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_set jsonb := private.payout_settings();
  v_iban text := pg_catalog.upper(pg_catalog.regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
  v_holder text := pg_catalog.btrim(coalesce(p_holder, ''));
  v_wallet public.wallets%rowtype;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  if not coalesce((v_set ->> 'enabled')::boolean, false) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'payouts_disabled'); end if;
  if p_rappen is null or p_rappen < coalesce((v_set ->> 'min_rappen')::bigint, 500) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'below_minimum'); end if;
  if v_iban !~ '^(CH|LI)[0-9]{2}[0-9A-Z]{17}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_iban'); end if;
  if pg_catalog.char_length(v_holder) not between 2 and 80 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_holder'); end if;
  if exists (select 1 from public.payout_requests where user_id = v_me and status = 'pending') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'payout_pending');
  end if;
  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.id is null or v_wallet.status <> 'active' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_locked'); end if;
  if v_wallet.credits < p_rappen then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_credits'); end if;
  update public.wallets set credits = credits - p_rappen, updated_at = pg_catalog.now() where id = v_wallet.id;
  insert into public.payout_requests (user_id, rappen, iban, holder) values (v_me, p_rappen, v_iban, v_holder);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.cancel_my_payout(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_req public.payout_requests%rowtype;
begin
  select * into v_req from public.payout_requests where id = p_id and user_id = auth.uid() and status = 'pending' for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update public.payout_requests set status = 'cancelled', decided_at = pg_catalog.now() where id = p_id;
  update public.wallets set credits = credits + v_req.rappen, updated_at = pg_catalog.now() where user_id = v_req.user_id;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.get_payout_state() from public, anon;
revoke all on function public.request_payout(bigint, text, text) from public, anon;
revoke all on function public.cancel_my_payout(uuid) from public, anon;
grant execute on function public.get_payout_state() to authenticated;
grant execute on function public.request_payout(bigint, text, text) to authenticated;
grant execute on function public.cancel_my_payout(uuid) to authenticated;

-- Chain-Seite: Auszahlungen ansehen, als bezahlt markieren oder ablehnen; Einstellungen
create or replace function public.node_list_payouts(p_key text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'settings', private.payout_settings(), 'payouts', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', r.id, 'rappen', r.rappen, 'iban', r.iban, 'holder', r.holder, 'status', r.status,
      'created_at', r.created_at, 'decided_at', r.decided_at,
      'username', (select coalesce(nullif(p.username, ''), p.display_name) from public.profiles p where p.id = r.user_id)
    ) order by (r.status = 'pending') desc, r.created_at desc)
    from (select * from public.payout_requests order by created_at desc limit 100) r
  ), '[]'::jsonb));
end;
$$;

create or replace function public.node_decide_payout(p_key text, p_id uuid, p_status text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_req public.payout_requests%rowtype;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_status not in ('paid', 'rejected') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_status'); end if;
  select * into v_req from public.payout_requests where id = p_id and status = 'pending' for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update public.payout_requests set status = p_status, decided_at = pg_catalog.now() where id = p_id;
  if p_status = 'rejected' then
    update public.wallets set credits = credits + v_req.rappen, updated_at = pg_catalog.now() where user_id = v_req.user_id;
  end if;
  insert into public.notifications (user_id, kind, title, message) values (v_req.user_id, 'payout',
    case when p_status = 'paid' then 'Auszahlung überwiesen' else 'Auszahlung abgelehnt' end,
    case when p_status = 'paid' then 'CHF ' || pg_catalog.to_char(v_req.rappen / 100.0, 'FM999990.00') || ' wurden auf dein Konto überwiesen.'
         else 'Deine Auszahlung wurde abgelehnt. Die Credits sind wieder in deinem Wallet.' end);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.node_set_payouts(p_key text, p_enabled boolean, p_min_rappen bigint)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_value := pg_catalog.jsonb_build_object('enabled', coalesce(p_enabled, false),
    'min_rappen', least(greatest(coalesce(p_min_rappen, 500), 100), 1000000));
  insert into private.admin_control_settings (key, value) values ('payouts', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'settings', v_value);
end;
$$;
revoke all on function public.node_list_payouts(text) from public;
revoke all on function public.node_decide_payout(text, uuid, text) from public;
revoke all on function public.node_set_payouts(text, boolean, bigint) from public;
grant execute on function public.node_list_payouts(text) to anon, authenticated, service_role;
grant execute on function public.node_decide_payout(text, uuid, text) to anon, authenticated, service_role;
grant execute on function public.node_set_payouts(text, boolean, bigint) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261023020000_payout_from_gibb.sql =====================
-- Auszahlen direkt aus GIBB: verkauft die GIBB zum aktuellen Kurs (wie "An die Bank verkaufen")
-- und fordert den Erlös sofort als Auszahlung an. Klappt die Auszahlung nicht, wird auch nichts verkauft.
create or replace function public.request_payout_gibb(p_gibb bigint, p_iban text, p_holder text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_sell jsonb;
  v_payout jsonb;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if p_gibb is null or p_gibb < 1 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount'); end if;
  if not coalesce((private.payout_settings() ->> 'enabled')::boolean, false) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'payouts_disabled'); end if;
  v_sell := public.market_sell(p_gibb);
  if not coalesce((v_sell ->> 'ok')::boolean, false) then return v_sell; end if;
  v_payout := public.request_payout((v_sell ->> 'rappen')::bigint, p_iban, p_holder);
  if not coalesce((v_payout ->> 'ok')::boolean, false) then
    -- Verkauf rückgängig machen (ganze Anfrage zurückrollen)
    raise exception 'payout_failed:%', coalesce(v_payout ->> 'error', 'unknown');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', (v_sell ->> 'rappen')::bigint);
end;
$$;
revoke all on function public.request_payout_gibb(bigint, text, text) from public, anon;
grant execute on function public.request_payout_gibb(bigint, text, text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== selfhost-final (App-Funktionen) =====================
-- Abschluss für die SELBST GEHOSTETE Datenbank (nicht für die Supabase-Cloud).
-- Läuft nach allen Migrationen. Ergänzt Funktionen, die die App aufruft, die aber
-- nur in der Cloud angelegt wurden, plus die Gutschrift für Node-Mining.
-- Alles ist idempotent.

-- Nutzerliste für das Admin-Panel.
create or replace function public.admin_list_users(p_query text default '')
returns table (
  user_id uuid, username text, display_name text, role text, visual_role text,
  balance bigint, wallet_status text, locked_until timestamptz, lock_reason text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_needle text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
begin
  perform private.require_admin();
  return query
  select p.id, coalesce(p.username, ''), p.display_name, p.role, v.visual_role,
         w.balance, w.status, w.locked_until, w.lock_reason
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  left join private.visual_demo_roles v on v.user_id = p.id
  where v_needle = ''
     or pg_catalog.strpos(pg_catalog.lower(coalesce(p.username, '')), v_needle) > 0
     or pg_catalog.strpos(pg_catalog.lower(p.display_name), v_needle) > 0
  order by p.display_name
  limit 500;
end;
$$;
revoke all on function public.admin_list_users(text) from public, anon;
grant execute on function public.admin_list_users(text) to authenticated;

-- Empfängersuche (Senden, Zahlungen): nur Benutzername und Anzeigename, nie E-Mail.
drop function if exists public.search_users(text);
create function public.search_users(p_query text)
returns table (user_id uuid, username text, display_name text, avatar_url text, profile_color text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_needle text := pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(coalesce(p_query, '')), '@'));
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if pg_catalog.char_length(v_needle) < 2 then return; end if;
  return query
  select p.id, coalesce(p.username, ''), p.display_name, p.avatar_url, p.profile_color
  from public.profiles p
  join public.wallets w on w.user_id = p.id and w.status = 'active'
  where p.id <> auth.uid()
    and p.email not like '%@gibbcoin.invalid'
    and (pg_catalog.strpos(pg_catalog.lower(coalesce(p.username, '')), v_needle) > 0
      or pg_catalog.strpos(pg_catalog.lower(p.display_name), v_needle) > 0)
  order by (pg_catalog.lower(coalesce(p.username, '')) = v_needle) desc, p.display_name
  limit 10;
end;
$$;
revoke all on function public.search_users(text) from public, anon;
grant execute on function public.search_users(text) to authenticated;

-- QR-Wallet: Empfänger über die Konto-ID auflösen.
create or replace function public.get_recipient(p_user_id uuid)
returns table (user_id uuid, username text, display_name text, wallet_code text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  return query
  select p.id, coalesce(p.username, ''), p.display_name,
         pg_catalog.upper(pg_catalog.right(pg_catalog.replace(w.id::text, '-', ''), 6))
  from public.profiles p
  join public.wallets w on w.user_id = p.id and w.status = 'active'
  where p.id = p_user_id and p.id <> auth.uid();
end;
$$;
revoke all on function public.get_recipient(uuid) from public, anon;
grant execute on function public.get_recipient(uuid) to authenticated;

-- Prüft die Hash-Kette mit derselben Formel wie private.append_transaction.
create or replace function public.verify_hash_chain()
returns table (valid boolean, checked bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  item record;
  v_previous text := pg_catalog.repeat('0', 64);
  v_expected text;
  v_count bigint := 0;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  for item in select t.sender_user_id, t.receiver_user_id, t.amount, t.created_at, t.previous_hash, t.hash
              from public.transactions t order by t.chain_index loop
    v_expected := pg_catalog.encode(extensions.digest(
      coalesce(item.sender_user_id::text, '') || coalesce(item.receiver_user_id::text, '') || item.amount::text ||
      pg_catalog.to_char(item.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || v_previous,
      'sha256'), 'hex');
    if item.previous_hash <> v_previous or item.hash <> v_expected then
      return query select false, v_count; return;
    end if;
    v_previous := item.hash;
    v_count := v_count + 1;
  end loop;
  return query select true, v_count;
end;
$$;
revoke all on function public.verify_hash_chain() from public, anon;
grant execute on function public.verify_hash_chain() to authenticated;

-- Mining über den Blockchain-Node: Belohnung aufs Website-Wallet (nur service_role, einmal pro Block).
create table if not exists private.node_mining_credits (
  block_hash text primary key,
  user_id uuid not null,
  amount bigint not null,
  height bigint,
  transaction_id uuid,
  created_at timestamptz not null default now()
);
revoke all on table private.node_mining_credits from public, anon, authenticated;

create or replace function public.node_credit_mining_reward(p_user_id uuid, p_amount bigint, p_block_hash text, p_height bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx uuid;
begin
  if p_user_id is null or p_block_hash is null or pg_catalog.char_length(p_block_hash) < 16 then raise exception 'invalid_request'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000 then raise exception 'invalid_amount'; end if;
  if exists (select 1 from private.node_mining_credits c where c.block_hash = p_block_hash) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now()
  where user_id = p_user_id and status = 'active';
  if not found then raise exception 'wallet_not_found'; end if;
  v_tx := private.append_transaction(null, p_user_id, p_amount, 'MINING_REWARD',
    'Blockchain-Node · Block #' || coalesce(p_height::text, '?') || ' gefunden');
  insert into private.node_mining_credits (block_hash, user_id, amount, height, transaction_id)
  values (p_block_hash, p_user_id, p_amount, p_height, v_tx);
  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_credit_mining_reward(uuid, bigint, text, bigint) from public, anon, authenticated;
grant execute on function public.node_credit_mining_reward(uuid, bigint, text, bigint) to service_role;

-- Platzhalter des alten Owner-Kontos: keine Rechte, gesperrt, kein Login.
do $$
begin
  set local session_replication_role = replica; -- Schutz-Trigger für diesen Schritt aussetzen
  update public.profiles set role = 'user'
  where id = 'd465d88f-0acb-4bff-ad55-945761acaeea' and email = 'platzhalter-owner@gibbcoin.invalid';
  update public.wallets set status = 'locked'
  where user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'
    and exists (select 1 from public.profiles p where p.id = 'd465d88f-0acb-4bff-ad55-945761acaeea' and p.email = 'platzhalter-owner@gibbcoin.invalid');
end;
$$;

notify pgrst, 'reload schema';

