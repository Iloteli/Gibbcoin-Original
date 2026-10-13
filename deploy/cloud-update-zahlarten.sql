-- Zahlarten im Kaufen-Tab einzeln auf der Chain-Seite ein-/ausschalten:
-- Karte/TWINT (Stripe, standardmässig AUS), mit Credits kaufen (standardmässig AN), Banküberweisung (bank_enabled).
alter table private.market_settings add column if not exists card_enabled boolean not null default false;
alter table private.market_settings add column if not exists credits_enabled boolean not null default true;

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
    'card_enabled', s.card_enabled, 'credits_enabled', s.credits_enabled
  )
  from private.market_settings s where s.singleton;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

create or replace function public.node_set_payment_methods(p_key text, p_card boolean, p_credits boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  update private.market_settings
  set card_enabled = coalesce(p_card, false), credits_enabled = coalesce(p_credits, true), updated_at = pg_catalog.now()
  where singleton;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_payment_methods(text, boolean, boolean) from public;
grant execute on function public.node_set_payment_methods(text, boolean, boolean) to anon, authenticated, service_role;

-- Mit Credits kaufen nur, wenn eingeschaltet
create or replace function public.market_buy_with_credits(p_gibb bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_quote jsonb;
  v_rappen bigint;
  v_wallet public.wallets%rowtype;
  v_after numeric;
begin
  if not coalesce((select s.credits_enabled from private.market_settings s where s.singleton), true) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'credits_disabled');
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'market_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'buy_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'buy_disabled'); end if;
  if not (v_quote ->> 'buy_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'buy_rappen')::bigint;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.credits < v_rappen then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_credits', 'needed', v_rappen); end if;

  update public.wallets set balance = balance + p_gibb, credits = credits - v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(null, v_me, p_gibb, 'MARKET_BUY', 'GIBB-Markt · Kauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('buy_credits', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;
revoke all on function public.market_buy_with_credits(bigint) from public, anon;
grant execute on function public.market_buy_with_credits(bigint) to authenticated;

notify pgrst, 'reload schema';
