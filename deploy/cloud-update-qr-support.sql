-- GIBB Coin: QR-Rechnung (Adresse), Support-Tickets reparieren, Support bearbeiten nur für Full-Owner. Kann mehrfach ausgeführt werden.

-- ===== 20261013290000_qr_bill_address.sql =====
-- QR-Rechnung für den Kauf per Überweisung: Adresse der Empfängerin/des Empfängers (PLZ und Ort sind Pflicht).
alter table private.market_settings add column if not exists bank_street text not null default '';
alter table private.market_settings add column if not exists bank_zip text not null default '';
alter table private.market_settings add column if not exists bank_city text not null default '';

create or replace function public.get_bank_details()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'enabled', s.bank_enabled and pg_catalog.btrim(s.bank_iban) <> '',
    'iban', s.bank_iban, 'holder', s.bank_holder,
    'street', s.bank_street, 'zip', s.bank_zip, 'city', s.bank_city,
    'card_enabled', s.card_enabled, 'credits_enabled', s.credits_enabled
  )
  from private.market_settings s where s.singleton;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

create or replace function public.node_set_bank_address(p_key text, p_street text, p_zip text, p_city text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_zip text := pg_catalog.btrim(coalesce(p_zip, ''));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_zip <> '' and v_zip !~ '^[0-9]{4}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_zip'); end if;
  update private.market_settings set
    bank_street = pg_catalog.left(pg_catalog.btrim(coalesce(p_street, '')), 70),
    bank_zip = v_zip,
    bank_city = pg_catalog.left(pg_catalog.btrim(coalesce(p_city, '')), 35),
    updated_at = pg_catalog.now()
  where singleton;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_bank_address(text, text, text, text) from public;
grant execute on function public.node_set_bank_address(text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- ===== 20261013300000_support_fix_full_owners.sql =====
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
