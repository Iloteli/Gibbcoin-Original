-- Chain-Seite: Owner der Hauptseite können sich auch mit ihrem Benutzernamen (statt E-Mail) anmelden.
-- Gibt die E-Mail nur für Owner (super_admin) zurück und nur an die Chain-Seite (Schlüssel).
create or replace function public.node_owner_login_email(p_key text, p_username text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select u.email into v_email
  from public.profiles p join auth.users u on u.id = p.id
  where pg_catalog.lower(p.username) = pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')))
    and p.role = 'super_admin'
  limit 1;
  if v_email is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'email', v_email);
end;
$$;
revoke all on function public.node_owner_login_email(text, text) from public;
grant execute on function public.node_owner_login_email(text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
