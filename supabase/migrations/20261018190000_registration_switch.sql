-- Selbst-Registrierung per Schalter auf der Chain-Seite ein-/ausschalten.
-- Aus (Standard): nur vom Owner freigegebene E-Mails dürfen ein Konto anlegen.
-- An: jeder kann sich auf der Hauptseite registrieren.
create or replace function private.registration_open()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value ->> 'enabled')::boolean from private.admin_control_settings s where s.key = 'registration'), false);
$$;
revoke all on function private.registration_open() from public, anon, authenticated;

create or replace function private.block_public_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Nur Registrierungen über die Supabase-Anmeldung (Rolle supabase_auth_admin) prüfen
  if current_user::text <> 'supabase_auth_admin' and session_user::text <> 'supabase_auth_admin' then
    return new;
  end if;
  if private.registration_open() then return new; end if;
  if exists (
    select 1 from private.signup_allowlist a
    where a.email = pg_catalog.lower(coalesce(new.email, '')) and a.expires_at > pg_catalog.now()
  ) then
    delete from private.signup_allowlist where email = pg_catalog.lower(coalesce(new.email, ''));
    return new;
  end if;
  raise exception using errcode = '42501', message = 'signup_disabled';
end;
$$;
revoke all on function private.block_public_signup() from public, anon, authenticated;

create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb),
    'registration_enabled', private.registration_open()
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_registration(p_key text, p_enabled boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  insert into private.admin_control_settings (key, value) values ('registration', pg_catalog.jsonb_build_object('enabled', coalesce(p_enabled, false)))
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'enabled', coalesce(p_enabled, false));
end;
$$;
revoke all on function public.node_set_registration(text, boolean) from public;
grant execute on function public.node_set_registration(text, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
