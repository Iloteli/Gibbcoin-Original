-- Admin-Portal ohne Pflicht-2FA + Ilja als Owner.
--
-- 1) private.require_admin() verlangte seit 20260908063951 für JEDE Adminaktion
--    eine aal2-Sitzung, auch wenn das Konto gar keinen 2FA-Faktor hat. Jetzt gilt
--    dieselbe Regel wie in private.assert_mfa_if_enrolled: 2FA wird nur verlangt,
--    wenn das Konto einen bestätigten Faktor eingerichtet hat. Admin-PIN, Rolle
--    und Kontosperre werden weiterhin geprüft.
-- 2) Ilja (ilja.podorieszach@icloud.com) wird idempotent Owner (super_admin).
--    super_admin umfasst alle Adminrechte.

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if exists (
    select 1 from auth.mfa_factors f
    where f.user_id = v_user_id and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
  select p.role, w.status into v_role, v_wallet_status
  from public.profiles p join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;
  if v_role not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  if v_wallet_status <> 'active' then raise exception 'account_locked'; end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_admin() from public, anon, authenticated;

do $$
declare
  v_user_id uuid;
  v_old_role text;
begin
  select u.id into v_user_id
  from auth.users u
  where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
  order by u.created_at
  limit 1;

  if v_user_id is null then
    raise notice 'Ilja-Konto (auth.users) nicht vorhanden – bitte einmal registrieren, dann erneut ausführen.';
    return;
  end if;

  select p.role into v_old_role from public.profiles p where p.id = v_user_id;
  update public.profiles set role = 'super_admin' where id = v_user_id;
  if not found then
    raise notice 'Ilja hat noch kein Profil – Migration 20260921090000_restore_ilja_owner legt es an.';
  end if;
  update public.wallets set status = 'active' where user_id = v_user_id and status <> 'active';

  if v_old_role is distinct from 'super_admin' then
    begin
      perform private.write_admin_audit(
        v_user_id, v_user_id, 'ROLE_CHANGED',
        pg_catalog.jsonb_build_object('role', coalesce(v_old_role, '(kein Profil)')),
        pg_catalog.jsonb_build_object('role', 'super_admin'),
        'Owner- und Adminrechte für Ilja gesetzt'
      );
    exception when others then
      raise notice 'Audit-Log übersprungen: %', SQLERRM;
    end;
  end if;
end;
$$;

notify pgrst, 'reload schema';
