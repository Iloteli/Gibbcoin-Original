-- Community-Rangliste: Punkte aus Erfolgen, Tagesaufgaben, Check-ins und gefundenen Blöcken.
-- Bewusst OHNE Kontostände – niemand sieht, wie viele Coins andere haben.
-- Punkte: Erfolg 10 · Tagesaufgabe 3 · Block 2 · Check-in 1. Zeitraum: week | month | all.

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
