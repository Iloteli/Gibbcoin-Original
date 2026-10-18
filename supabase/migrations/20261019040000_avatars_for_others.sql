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
