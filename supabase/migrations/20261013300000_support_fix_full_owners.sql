-- 1) Neue Support-Tickets: Absender automatisch setzen (fehlte -> "Das hat nicht geklappt").
alter table public.support_cases alter column requester_id set default auth.uid();

-- 2) "Support bearbeiten" nur für Full-Owner (Ilja + auf der Chain-Seite zu Full hochgestufte Owner).
--    Die Chain-Seite überträgt die Liste der Full-Owner mit ihrem Schlüssel.
create or replace function public.node_set_owner_levels(p_key text, p_full uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('owner_levels', pg_catalog.jsonb_build_object('full', pg_catalog.to_jsonb(coalesce(p_full, '{}'::uuid[]))), null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_owner_levels(text, uuid[]) from public;
grant execute on function public.node_set_owner_levels(text, uuid[]) to anon, authenticated, service_role;

create or replace function private.is_full_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
    and exists (select 1 from public.profiles p where p.id = p_user_id and p.role = 'super_admin')
    and (
      private.is_ilja(p_user_id)
      or coalesce((select s.value -> 'full' from private.admin_control_settings s where s.key = 'owner_levels'), '[]'::jsonb) ? p_user_id::text
    );
$$;
revoke all on function private.is_full_owner(uuid) from public, anon, authenticated;

create or replace function private.require_support_owner()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if not private.is_full_owner(v_user_id)
     or not exists (select 1 from public.wallets w where w.user_id = v_user_id and w.status = 'active') then
    raise exception 'owner_required';
  end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_support_owner() from public, anon, authenticated;

-- Für die Hauptseite: darf dieses Konto Support bearbeiten?
create or replace function public.get_support_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select private.is_full_owner(auth.uid()); $$;
revoke all on function public.get_support_access() from public, anon;
grant execute on function public.get_support_access() to authenticated;

notify pgrst, 'reload schema';
