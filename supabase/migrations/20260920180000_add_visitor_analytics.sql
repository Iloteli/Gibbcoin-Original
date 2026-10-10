-- Besucherstatistik fuer das Adminpanel.
-- Zaehlt echte Seitenaufrufe und eindeutige Browser pro Webadresse.
-- Rohdaten sind nur ueber Security-Definer-Funktionen erreichbar.

create table if not exists public.site_visits (
  id uuid primary key default gen_random_uuid(),
  visitor_id text not null check (char_length(visitor_id) between 8 and 64),
  site text not null check (site in ('chatgpt-site', 'workers-dev', 'other')),
  path text not null default '/' check (char_length(path) between 1 and 200),
  visited_at timestamptz not null default now()
);

create index if not exists site_visits_visited_at_idx on public.site_visits (visited_at desc);
create index if not exists site_visits_site_idx on public.site_visits (site, visited_at desc);
create index if not exists site_visits_visitor_idx on public.site_visits (visitor_id, visited_at desc);

alter table public.site_visits enable row level security;
revoke all on public.site_visits from anon, authenticated;
grant all on public.site_visits to service_role;

-- Ein Besuch wird nur ueber diese Funktion geschrieben. Sie entfernt doppelte
-- Aufrufe derselben Seite innerhalb von 30 Sekunden und begrenzt Spam.
create or replace function public.record_site_visit(
  p_visitor_id text,
  p_site text,
  p_path text default '/'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_visitor text := nullif(trim(p_visitor_id), '');
  v_site text := lower(coalesce(nullif(trim(p_site), ''), 'other'));
  v_path text := left(coalesce(nullif(trim(p_path), ''), '/'), 200);
  v_recent_total integer;
begin
  if v_visitor is null or char_length(v_visitor) < 8 or char_length(v_visitor) > 64 then
    return;
  end if;
  if v_site not in ('chatgpt-site', 'workers-dev', 'other') then
    v_site := 'other';
  end if;

  -- Neuladen derselben Seite zaehlt nicht mehrfach.
  if exists (
    select 1 from public.site_visits
    where visitor_id = v_visitor
      and site = v_site
      and path = v_path
      and visited_at > now() - interval '30 seconds'
  ) then
    return;
  end if;

  -- Schutz gegen kuenstlich aufgeblasene Zahlen.
  select count(*) into v_recent_total
  from public.site_visits
  where visitor_id = v_visitor
    and visited_at > now() - interval '1 hour';
  if v_recent_total >= 240 then
    return;
  end if;

  insert into public.site_visits (visitor_id, site, path)
  values (v_visitor, v_site, v_path);
end;
$$;

revoke all on function public.record_site_visit(text, text, text) from public;
grant execute on function public.record_site_visit(text, text, text) to anon, authenticated;

-- Auswertung ausschliesslich fuer Admins und Owner.
create or replace function public.admin_visitor_stats(p_days integer default 30)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_from timestamptz;
  v_result json;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if coalesce(v_role, '') not in ('admin', 'super_admin') then
    raise exception 'admin_required';
  end if;

  v_from := date_trunc('day', now()) - make_interval(days => v_days - 1);

  select json_build_object(
    'range_days', v_days,
    'first_visit_at', (select min(visited_at) from public.site_visits),
    'range_unique_visitors', (
      select count(distinct visitor_id) from public.site_visits where visited_at >= v_from
    ),
    'range_page_views', (
      select count(*) from public.site_visits where visited_at >= v_from
    ),
    'total_unique_visitors', (select count(distinct visitor_id) from public.site_visits),
    'total_page_views', (select count(*) from public.site_visits),
    'daily', coalesce((
      select json_agg(row_to_json(day_rows) order by day_rows.day)
      from (
        select
          to_char(days.day, 'YYYY-MM-DD') as day,
          coalesce(count(distinct v.visitor_id), 0) as unique_visitors,
          coalesce(count(v.id), 0) as page_views
        from generate_series(v_from, date_trunc('day', now()), interval '1 day') as days(day)
        left join public.site_visits v
          on v.visited_at >= days.day and v.visited_at < days.day + interval '1 day'
        group by days.day
      ) as day_rows
    ), '[]'::json),
    'sites', coalesce((
      select json_agg(row_to_json(site_rows))
      from (
        select
          site,
          count(distinct visitor_id) as unique_visitors,
          count(*) as page_views
        from public.site_visits
        where visited_at >= v_from
        group by site
        order by count(*) desc
      ) as site_rows
    ), '[]'::json),
    'pages', coalesce((
      select json_agg(row_to_json(page_rows))
      from (
        select
          path,
          count(distinct visitor_id) as unique_visitors,
          count(*) as page_views
        from public.site_visits
        where visited_at >= v_from
        group by path
        order by count(*) desc
        limit 10
      ) as page_rows
    ), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_visitor_stats(integer) from public;
grant execute on function public.admin_visitor_stats(integer) to authenticated;
