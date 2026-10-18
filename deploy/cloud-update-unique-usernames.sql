-- Benutzernamen über beide Websites eindeutig: Namen der Chain-Konten sind auf der Hauptseite reserviert.
-- Die Chain-Seite schickt ihre Namen regelmässig (node_set_reserved_usernames).
create table if not exists private.reserved_usernames (
  username text primary key
);
revoke all on table private.reserved_usernames from public, anon, authenticated;

create or replace function public.node_set_reserved_usernames(p_key text, p_names text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  delete from private.reserved_usernames;
  insert into private.reserved_usernames (username)
  select distinct pg_catalog.lower(pg_catalog.btrim(n)) from pg_catalog.unnest(coalesce(p_names, '{}'::text[])) n
  where pg_catalog.btrim(n) <> '';
  return pg_catalog.jsonb_build_object('ok', true, 'count', (select pg_catalog.count(*) from private.reserved_usernames));
end;
$$;
revoke all on function public.node_set_reserved_usernames(text, text[]) from public;
grant execute on function public.node_set_reserved_usernames(text, text[]) to anon, authenticated, service_role;

-- Beim Ändern des Benutzernamens: Name eines Chain-Kontos = vergeben
create or replace function private.enforce_reserved_username()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.username is distinct from old.username and new.username is not null
     and exists (select 1 from private.reserved_usernames r where r.username = pg_catalog.lower(new.username)) then
    raise exception 'username_taken' using errcode = 'unique_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists enforce_reserved_username on public.profiles;
create trigger enforce_reserved_username
  before update of username on public.profiles
  for each row execute function private.enforce_reserved_username();

notify pgrst, 'reload schema';
