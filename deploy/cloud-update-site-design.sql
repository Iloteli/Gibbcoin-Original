-- Design der Hauptseite (Farbwelt, Standard-Modus, Animationen), eingestellt auf der Chain-Seite.
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
    'footer_text', coalesce((select s.value ->> 'text' from private.admin_control_settings s where s.key = 'site_footer'), 'Made by Ilja'),
    'design', coalesce((select s.value from private.admin_control_settings s where s.key = 'site_design'), '{"accent":"neon","mode":"dark","motion":"full"}'::jsonb)
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_site_design(p_key text, p_accent text, p_mode text, p_motion text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_value := pg_catalog.jsonb_build_object(
    'accent', case when p_accent in ('neon', 'emerald', 'violet', 'gold') then p_accent else 'neon' end,
    'mode', case when p_mode in ('dark', 'light') then p_mode else 'dark' end,
    'motion', case when p_motion in ('full', 'reduced', 'off') then p_motion else 'full' end
  );
  insert into private.admin_control_settings (key, value) values ('site_design', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'design', v_value);
end;
$$;
revoke all on function public.node_set_site_design(text, text, text, text) from public;
grant execute on function public.node_set_site_design(text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
