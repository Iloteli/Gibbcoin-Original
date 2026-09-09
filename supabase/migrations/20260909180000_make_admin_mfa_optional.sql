-- Zwei-Faktor-Bestätigung ist nicht mehr zwingend. Bisher scheiterte jede
-- geschützte Adminaktion mit 'mfa_required', sobald ein Konto einen bestätigten
-- Faktor hatte und die Sitzung nur 'aal1' war. Wer sein Authenticator-Gerät
-- verlor, kam damit an keine Adminfunktion mehr heran.
--
-- Die Prüfung bleibt vollständig erhalten, ist aber jetzt über eine Einstellung
-- schaltbar und standardmässig aus. Einschalten mit:
--   update private.security_settings set enabled = true, updated_at = now()
--   where key = 'require_admin_mfa';
create table if not exists private.security_settings (
  key text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

revoke all on table private.security_settings
from public, anon, authenticated;

insert into private.security_settings (key, enabled)
values ('require_admin_mfa', false)
on conflict (key) do nothing;

create or replace function private.assert_mfa_if_enrolled(p_user_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Die Identitätsprüfung bleibt in jedem Fall bestehen.
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'authentication_required';
  end if;

  if not coalesce(
    (select s.enabled from private.security_settings s where s.key = 'require_admin_mfa'),
    false
  ) then
    return;
  end if;

  if exists (
    select 1
    from auth.mfa_factors f
    where f.user_id = p_user_id
      and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
end;
$$;

revoke all on function private.assert_mfa_if_enrolled(uuid)
from public, anon, authenticated;

notify pgrst, 'reload schema';
