-- Jede geoeffnete Seite wird als eigener Seitenaufruf gezaehlt.
-- Die bisherige 30-Sekunden-Deduplizierung und das Stundenlimit wurden entfernt,
-- damit der Counter bei jedem neuen Seitenaufruf erhoeht wird.

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
begin
  if v_visitor is null or char_length(v_visitor) < 8 or char_length(v_visitor) > 64 then
    return;
  end if;

  if v_site not in ('chatgpt-site', 'workers-dev', 'other') then
    v_site := 'other';
  end if;

  -- Absichtlich kein EXISTS-/Zeitfenster-Check: Jeder Seitenaufruf zaehlt.
  insert into public.site_visits (visitor_id, site, path)
  values (v_visitor, v_site, v_path);
end;
$$;

revoke all on function public.record_site_visit(text, text, text) from public;
grant execute on function public.record_site_visit(text, text, text) to anon, authenticated;
