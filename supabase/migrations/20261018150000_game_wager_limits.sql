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
