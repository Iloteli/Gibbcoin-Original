-- Keine Selbst-Registrierung mehr: Neue Konten legt nur Ilja auf der Chain-Seite an.
-- * Ein Konto über die Supabase-Anmeldung (signup) entsteht nur, wenn die Chain-Seite die E-Mail
--   vorher freigegeben hat (10 Minuten gültig). Alle anderen Registrierungen werden abgelehnt.
-- * Direkte Einträge im SQL Editor / durch Migrationen bleiben möglich.

create table if not exists private.signup_allowlist (
  email text primary key,
  username text,
  expires_at timestamptz not null
);
revoke all on table private.signup_allowlist from public, anon, authenticated;

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
drop trigger if exists block_public_signup on auth.users;
create trigger block_public_signup before insert on auth.users
  for each row execute function private.block_public_signup();

-- Chain-Seite: E-Mail für ein neues Konto freigeben (danach legt die Chain-Seite das Konto an)
create or replace function public.node_allow_signup(p_key text, p_email text, p_username text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_email, '')));
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_email'); end if;
  if v_username !~ '^[a-z0-9._-]{3,30}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_username'); end if;
  if exists (select 1 from auth.users u where pg_catalog.lower(u.email) = v_email) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'email_taken');
  end if;
  if exists (select 1 from public.profiles p where pg_catalog.lower(p.username) = v_username) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;
  delete from private.signup_allowlist where expires_at < pg_catalog.now();
  insert into private.signup_allowlist (email, username, expires_at)
  values (v_email, v_username, pg_catalog.now() + interval '10 minutes')
  on conflict (email) do update set username = excluded.username, expires_at = excluded.expires_at;
  return pg_catalog.jsonb_build_object('ok', true, 'email', v_email, 'username', v_username);
end;
$$;
revoke all on function public.node_allow_signup(text, text, text) from public;
grant execute on function public.node_allow_signup(text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
