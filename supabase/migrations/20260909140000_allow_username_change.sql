-- Jeder Benutzer darf seinen Benutzernamen selbst ändern. Es gelten dieselben
-- Regeln wie bei der Registrierung: Kleinbuchstaben, Ziffern, Punkt, Bindestrich
-- und Unterstrich, 3 bis 24 Zeichen, Beginn alphanumerisch. Die Eindeutigkeit
-- wird case-insensitiv geprüft und zusätzlich vom Unique-Index erzwungen.
-- Rollen, Guthaben und Transaktionen bleiben unberührt.
create or replace function public.set_my_username(p_username text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
  v_current text;
begin
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_username');
  end if;

  select p.username into v_current
  from public.profiles p
  where p.id = v_user_id;

  if v_current = v_username then
    return pg_catalog.jsonb_build_object('ok', true, 'username', v_username, 'changed', false);
  end if;

  if exists (
    select 1
    from public.profiles p
    where pg_catalog.lower(p.username) = v_username
      and p.id <> v_user_id
  ) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;

  update public.profiles
  set username = v_username,
      updated_at = now()
  where id = v_user_id;

  return pg_catalog.jsonb_build_object('ok', true, 'username', v_username, 'changed', true);
exception
  when unique_violation then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
end;
$$;

revoke all on function public.set_my_username(text)
from public, anon, authenticated;
grant execute on function public.set_my_username(text)
to authenticated;
