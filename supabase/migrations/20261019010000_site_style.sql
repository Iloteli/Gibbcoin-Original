-- Design der Hauptseite: zusätzlich "Original" (erstes grünes Design) oder "Neu" (Neon Glass).
drop function if exists public.node_set_site_design(text, text, text, text);

create or replace function public.node_set_site_design(p_key text, p_accent text, p_mode text, p_motion text, p_style text default 'new')
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
    'motion', case when p_motion in ('full', 'reduced', 'off') then p_motion else 'full' end,
    'style', case when p_style = 'original' then 'original' else 'new' end
  );
  insert into private.admin_control_settings (key, value) values ('site_design', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'design', v_value);
end;
$$;
revoke all on function public.node_set_site_design(text, text, text, text, text) from public;
grant execute on function public.node_set_site_design(text, text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
