-- QR-Rechnung nur für verifizierte Käufer: Ilja schaltet Konten auf der Chain-Seite frei.
-- Nicht verifizierte Konten bekommen die Adresse (PLZ/Ort/Strasse) gar nicht erst – sie können weiterhin
-- von Hand mit IBAN und Code überweisen.

create table if not exists private.verified_buyers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  verified_at timestamptz not null default now()
);
revoke all on table private.verified_buyers from public, anon, authenticated;

create or replace function public.get_bank_details()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_verified boolean := exists (select 1 from private.verified_buyers v where v.user_id = auth.uid());
  v_qr boolean;
begin
  select * into v_s from private.market_settings where singleton;
  v_qr := v_verified and v_s.bank_zip <> '' and v_s.bank_city <> '' and pg_catalog.btrim(v_s.bank_holder) <> '';
  return pg_catalog.jsonb_build_object(
    'enabled', v_s.bank_enabled and pg_catalog.btrim(v_s.bank_iban) <> '',
    'iban', v_s.bank_iban, 'holder', v_s.bank_holder,
    'verified', v_verified,
    'qr_allowed', v_qr,
    'street', case when v_qr then v_s.bank_street end,
    'zip', case when v_qr then v_s.bank_zip end,
    'city', case when v_qr then v_s.bank_city end,
    'card_enabled', v_s.card_enabled, 'credits_enabled', v_s.credits_enabled
  );
end;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

create or replace function public.node_set_buyer_verified(p_key text, p_user uuid, p_verified boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or not exists (select 1 from auth.users u where u.id = p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if coalesce(p_verified, false) then
    insert into private.verified_buyers (user_id) values (p_user) on conflict (user_id) do nothing;
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (p_user, 'account', 'Konto verifiziert', 'Du kannst jetzt per QR-Rechnung GIBB kaufen.');
    exception when others then null;
    end;
  else
    delete from private.verified_buyers where user_id = p_user;
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'verified', coalesce(p_verified, false));
end;
$$;
revoke all on function public.node_set_buyer_verified(text, uuid, boolean) from public;
grant execute on function public.node_set_buyer_verified(text, uuid, boolean) to anon, authenticated, service_role;

create or replace function public.node_list_verified_buyers(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'ids', coalesce((select pg_catalog.jsonb_agg(v.user_id) from private.verified_buyers v), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_verified_buyers(text) from public;
grant execute on function public.node_list_verified_buyers(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
