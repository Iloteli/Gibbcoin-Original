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
