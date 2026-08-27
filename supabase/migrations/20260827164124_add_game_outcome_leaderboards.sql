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
