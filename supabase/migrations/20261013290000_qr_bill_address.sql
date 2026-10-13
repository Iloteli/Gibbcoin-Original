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
