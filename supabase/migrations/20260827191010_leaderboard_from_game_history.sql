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
