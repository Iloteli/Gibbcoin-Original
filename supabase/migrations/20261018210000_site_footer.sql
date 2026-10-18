-- "Made by"-Fusszeile der Hauptseite, bearbeitbar auf der Chain-Seite.
create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb),
    'registration_enabled', private.registration_open(),
    'footer_text', coalesce((select s.value ->> 'text' from private.admin_control_settings s where s.key = 'site_footer'), 'Made by Ilja')
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_footer(p_key text, p_text text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_text text := pg_catalog.left(pg_catalog.btrim(coalesce(p_text, '')), 120);
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  insert into private.admin_control_settings (key, value) values ('site_footer', pg_catalog.jsonb_build_object('text', v_text))
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'text', v_text);
end;
$$;
revoke all on function public.node_set_footer(text, text) from public;
grant execute on function public.node_set_footer(text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
