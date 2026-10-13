-- Chain-Seite räumt gelöschte Website-Konten auf: Sie fragt mit ihrem Schlüssel nach, welche
-- ihrer Website-Konten (sb_<uuid>) es noch gibt. Liefert nur IDs, die es noch gibt – keine Kontodaten.
create or replace function public.node_existing_users(p_key text, p_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_ids is null or pg_catalog.cardinality(p_ids) > 5000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_ids');
  end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'existing', coalesce((select pg_catalog.jsonb_agg(u.id) from auth.users u where u.id = any (p_ids)), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.node_existing_users(text, uuid[]) from public;
grant execute on function public.node_existing_users(text, uuid[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
