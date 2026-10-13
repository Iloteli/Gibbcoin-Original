-- GIBB-Markt: Kurs in Rappen pro GIBB, der auf Käufe und Verkäufe reagiert.
--
-- * Kaufen (Stripe oder mit Credits) hebt den Kurs, Verkaufen an die Bank senkt ihn.
-- * Kurve: Jedes gehandelte GIBB verändert den Kurs um den Faktor (1 + k).
--   Kosten für n GIBB ab Kurs p:  p * ((1+k)^n - 1) / k  (aufgerundet auf ganze Rappen).
--   Ein Verkauf läuft dieselbe Kurve rückwärts – ein Kauf und sofortiger Verkauf
--   bringt also keinen Gewinn; zusätzlich gibt es eine Verkaufsgebühr.
-- * Verkaufen bringt KEIN echtes Geld, sondern Credits (Guthaben in Rappen), mit
--   denen man später wieder GIBB kaufen kann.
-- * Kursgrenzen schützen vor Ausreissern; Handel über eine Grenze hinaus wird abgelehnt.

-- Neue Transaktionstypen (Obermenge der bisherigen Liste)
alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions
  add constraint transactions_type_check check (
    type in (
      'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
      'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN',
      'COIN_PURCHASE', 'GAME_ENTRY', 'GAME_REWARD', 'MINING_REWARD',
      'MARKET_BUY', 'MARKET_SELL'
    )
  );

-- Credits (Rappen) pro Wallet
alter table public.wallets add column if not exists credits bigint not null default 0;
alter table public.wallets drop constraint if exists wallets_credits_check;
alter table public.wallets add constraint wallets_credits_check check (credits >= 0);

create table if not exists private.market_settings (
  singleton boolean primary key default true check (singleton),
  price numeric(20, 8) not null default 1,          -- Rappen pro GIBB
  step numeric(12, 8) not null default 0.0005,      -- Kursänderung pro GIBB (0.05 %)
  min_price numeric(20, 8) not null default 0.25,
  max_price numeric(20, 8) not null default 50,
  sell_fee numeric(6, 4) not null default 0.02,      -- 2 % Gebühr beim Verkauf
  max_trade bigint not null default 1000,           -- höchstens so viele GIBB pro Handel
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into private.market_settings (singleton) values (true) on conflict (singleton) do nothing;
revoke all on table private.market_settings from public, anon, authenticated;

create table if not exists public.market_events (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('buy_stripe', 'buy_credits', 'sell')),
  user_id uuid references auth.users(id) on delete set null,
  gibb bigint not null check (gibb > 0),
  rappen bigint not null check (rappen >= 0),
  price_before numeric(20, 8) not null,
  price_after numeric(20, 8) not null,
  reference text unique,                              -- z. B. Stripe-Event-ID (verhindert Doppelbuchung)
  created_at timestamptz not null default now()
);
create index if not exists market_events_created_idx on public.market_events (created_at desc);
alter table public.market_events enable row level security;
alter table public.market_events force row level security;
revoke all on table public.market_events from public, anon, authenticated;

-- Kosten für n GIBB ab Kurs p (Kauf): Summe p*(1+k)^i, i = 0..n-1
create or replace function private.market_curve_sum(p_price numeric, p_step numeric, p_n bigint)
returns numeric language sql immutable set search_path = '' as $$
  select case when p_step = 0 then p_price * p_n
              else p_price * (pg_catalog.power(1 + p_step, p_n) - 1) / p_step end;
$$;

-- Kurs nach einem Handel bewegen und protokollieren (intern, unter Sperre aufrufen)
create or replace function private.market_apply(p_kind text, p_user uuid, p_gibb bigint, p_rappen bigint, p_reference text)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_after numeric;
begin
  select * into v_s from private.market_settings where singleton for update;
  v_after := case when p_kind = 'sell'
    then v_s.price / pg_catalog.power(1 + v_s.step, p_gibb)
    else v_s.price * pg_catalog.power(1 + v_s.step, p_gibb) end;
  v_after := greatest(v_s.min_price, least(v_s.max_price, v_after));
  update private.market_settings set price = v_after, updated_at = pg_catalog.now() where singleton;
  insert into public.market_events (kind, user_id, gibb, rappen, price_before, price_after, reference)
  values (p_kind, p_user, p_gibb, p_rappen, v_s.price, v_after, p_reference);
  return v_after;
end;
$$;
revoke all on function private.market_apply(text, uuid, bigint, bigint, text) from public, anon, authenticated;

-- Angebot: Was kosten n GIBB gerade? Was bringt ein Verkauf von n GIBB?
create or replace function public.market_quote(p_gibb bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_buy numeric; v_sell numeric; v_after_buy numeric; v_after_sell numeric;
begin
  select * into v_s from private.market_settings where singleton;
  if p_gibb is null or p_gibb < 1 or p_gibb > v_s.max_trade then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount', 'max_trade', v_s.max_trade);
  end if;
  v_after_buy := v_s.price * pg_catalog.power(1 + v_s.step, p_gibb);
  v_after_sell := v_s.price / pg_catalog.power(1 + v_s.step, p_gibb);
  v_buy := pg_catalog.ceil(private.market_curve_sum(v_s.price, v_s.step, p_gibb));
  v_sell := pg_catalog.floor(private.market_curve_sum(v_after_sell, v_s.step, p_gibb) * (1 - v_s.sell_fee));
  return pg_catalog.jsonb_build_object(
    'ok', true, 'gibb', p_gibb, 'price', v_s.price,
    'buy_rappen', v_buy, 'buy_possible', v_after_buy <= v_s.max_price,
    'sell_rappen', v_sell, 'sell_possible', v_after_sell >= v_s.min_price,
    'price_after_buy', v_after_buy, 'price_after_sell', v_after_sell,
    'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade, 'enabled', v_s.enabled
  );
end;
$$;

-- Marktübersicht: Kurs, Verlauf, eigene Bestände
create or replace function public.get_market_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_s private.market_settings%rowtype;
  v_day_ago numeric;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  select * into v_s from private.market_settings where singleton;
  select e.price_after into v_day_ago from public.market_events e
  where e.created_at <= pg_catalog.now() - interval '24 hours' order by e.created_at desc limit 1;
  return pg_catalog.jsonb_build_object(
    'price', v_s.price, 'enabled', v_s.enabled, 'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade,
    'min_price', v_s.min_price, 'max_price', v_s.max_price,
    'price_24h_ago', coalesce(v_day_ago, (select e.price_before from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours' order by e.created_at limit 1), v_s.price),
    'volume_24h', coalesce((select sum(e.gibb) from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours'), 0),
    'history', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('t', x.created_at, 'p', x.price_after, 'k', x.kind, 'n', x.gibb) order by x.created_at)
                         from (select * from public.market_events order by created_at desc limit 120) x), '[]'::jsonb),
    'my_gibb', (select w.balance from public.wallets w where w.user_id = v_me),
    'my_credits', (select w.credits from public.wallets w where w.user_id = v_me)
  );
end;
$$;

-- GIBB an die Bank verkaufen -> Credits
create or replace function public.market_sell(p_gibb bigint)
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
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'sell_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'sell_rappen')::bigint;
  if v_rappen < 1 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'amount_too_small'); end if;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.balance < p_gibb then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_funds'); end if;

  update public.wallets set balance = balance - p_gibb, credits = credits + v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(v_me, null, p_gibb, 'MARKET_SELL', 'GIBB-Markt · Verkauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('sell', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;

-- GIBB mit Credits kaufen
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
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
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

-- Stripe-Kauf: Kurs bewegen (vom Webhook nach credit_gibb_purchase aufgerufen; idempotent pro Event)
create or replace function public.market_record_stripe_buy(p_event text, p_user uuid, p_gibb bigint, p_rappen bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_after numeric;
begin
  if exists (select 1 from public.market_events where reference = p_event) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_after := private.market_apply('buy_stripe', p_user, p_gibb, p_rappen, p_event);
  return pg_catalog.jsonb_build_object('ok', true, 'price', v_after);
end;
$$;

revoke all on function public.market_quote(bigint) from public, anon;
revoke all on function public.get_market_state() from public, anon;
revoke all on function public.market_sell(bigint) from public, anon;
revoke all on function public.market_buy_with_credits(bigint) from public, anon;
revoke all on function public.market_record_stripe_buy(text, uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.market_quote(bigint) to authenticated, service_role;
grant execute on function public.get_market_state() to authenticated;
grant execute on function public.market_sell(bigint) to authenticated;
grant execute on function public.market_buy_with_credits(bigint) to authenticated;
grant execute on function public.market_record_stripe_buy(text, uuid, bigint, bigint) to service_role;


-- Stripe-Kauf zum Marktkurs gutschreiben (nur service_role, idempotent pro Stripe-Event/Session).
-- Prüft, dass der bezahlte Betrag dem beim Checkout berechneten Angebot entspricht (min. 50 Rappen).
create or replace function public.credit_market_purchase(
  stripe_event text,
  checkout_session text,
  payment_intent text,
  purchased_user uuid,
  purchased_coins bigint,
  paid_amount bigint,
  paid_currency text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet public.wallets%rowtype;
  v_transaction_id uuid;
  v_existing uuid;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'service_role_required';
  end if;
  if purchased_user is null or stripe_event is null or checkout_session is null
     or purchased_coins is null or purchased_coins < 1 or purchased_coins > 1000
     or paid_amount is null or paid_amount < 50 or lower(coalesce(paid_currency, '')) <> 'chf' then
    raise exception 'invalid_purchase';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(938241);
  select p.transaction_id into v_existing from public.coin_purchases p
  where p.stripe_event_id = stripe_event or p.checkout_session_id = checkout_session limit 1;
  if found then return v_existing; end if;

  select w.* into v_wallet from public.wallets w where w.user_id = purchased_user for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;

  update public.wallets set balance = balance + purchased_coins, updated_at = pg_catalog.now() where id = v_wallet.id;
  v_transaction_id := private.append_transaction(null, purchased_user, purchased_coins, 'COIN_PURCHASE',
    'GIBB-Markt · Stripe · ' || purchased_coins || ' GIBB für CHF ' || pg_catalog.to_char(paid_amount::numeric / 100, 'FM999999990.00'));
  insert into public.coin_purchases (user_id, stripe_event_id, checkout_session_id, payment_intent_id, coins, amount_paid, currency, transaction_id)
  values (purchased_user, stripe_event, checkout_session, payment_intent, purchased_coins, paid_amount, 'chf', v_transaction_id);
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  perform private.market_apply('buy_stripe', purchased_user, purchased_coins, paid_amount, stripe_event);
  insert into public.notifications (user_id, kind, title, message)
  values (purchased_user, 'coin_purchase', 'Coins gekauft', purchased_coins || ' GIBB wurden deinem Wallet gutgeschrieben.');
  return v_transaction_id;
end;
$$;
revoke all on function public.credit_market_purchase(text, text, text, uuid, bigint, bigint, text) from public, anon, authenticated;
grant execute on function public.credit_market_purchase(text, text, text, uuid, bigint, bigint, text) to service_role;

notify pgrst, 'reload schema';
