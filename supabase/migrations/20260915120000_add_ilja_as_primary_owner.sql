-- Ilja erhält dieselben Haupt-Owner-Rechte wie Robyn: Bannen, Entbannen und
-- dauerhaftes Löschen fremder Konten, auch anderer Owner-Konten.
--
-- Robyn bleibt über die unveränderliche User-ID hinterlegt. Ilja wird über die
-- Login-E-Mail in auth.users aufgelöst; diese kann nur mit Bestätigung geändert
-- werden und ist für den Browser weder les- noch schreibbar. Beide Konten müssen
-- zusätzlich die Rolle super_admin besitzen. Alle Ban- und Löschfunktionen
-- (admin_apply_wallet_status, dessen v2-Variante, admin_authorize_account_deletion,
-- admin_finalize_account_deletion und der auth.users-Trigger) verwenden
-- private.is_primary_owner und übernehmen die Änderung automatisch.

create or replace function private.is_primary_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = p_user_id
        and p.role = 'super_admin'
    )
    and (
      p_user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'::uuid
      or exists (
        select 1
        from auth.users u
        where u.id = p_user_id
          and pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
      )
    );
$$;

revoke all on function private.is_primary_owner(uuid)
from public, anon, authenticated;

create or replace function public.get_my_admin_account_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_is_primary_owner boolean := false;
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object(
      'is_primary_owner', false,
      'can_manage_standard_accounts', false,
      'can_manage_owner_accounts', false
    );
  end if;

  select p.role into v_role
  from public.profiles p
  where p.id = v_user_id;

  v_is_primary_owner := private.is_primary_owner(v_user_id);

  return pg_catalog.jsonb_build_object(
    'is_primary_owner', v_is_primary_owner,
    'can_manage_standard_accounts', v_role = 'admin' or v_is_primary_owner,
    'can_manage_owner_accounts', v_is_primary_owner
  );
end;
$$;

revoke all on function public.get_my_admin_account_capabilities()
from public, anon;
grant execute on function public.get_my_admin_account_capabilities()
to authenticated;

notify pgrst, 'reload schema';
