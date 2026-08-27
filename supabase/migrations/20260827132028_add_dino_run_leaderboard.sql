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
