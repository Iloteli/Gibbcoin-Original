-- Einzelne Tabs der Hauptseite ein-/ausschalten (auf der Chain-Seite, mit dem Chain-Schlüssel).
-- Home und Konto bleiben immer sichtbar.

create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb)
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_site_tabs(p_key text, p_disabled text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tabs text[];
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select coalesce(array_agg(distinct t), '{}') into v_tabs
  from unnest(coalesce(p_disabled, '{}')) t
  where t in ('send', 'games', 'community', 'activity', 'chain', 'market');
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('site_tabs', pg_catalog.jsonb_build_object('disabled_tabs', pg_catalog.to_jsonb(v_tabs)), null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true, 'disabled_tabs', pg_catalog.to_jsonb(v_tabs));
end;
$$;
revoke all on function public.node_set_site_tabs(text, text[]) from public;
grant execute on function public.node_set_site_tabs(text, text[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
