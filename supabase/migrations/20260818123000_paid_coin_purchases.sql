-- Echte Einmalzahlungen über Stripe Checkout (Karte + TWINT, ausschließlich CHF).
-- Kompatibel mit der bestehenden produktiven GIBB-Coin-Hash-Kette.

alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions add constraint transactions_type_check check (
  type = any (array[
    'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
    'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN', 'COIN_PURCHASE'
  ]::text[])
);

create table if not exists public.coin_purchases (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  stripe_event_id text not null unique,
  checkout_session_id text not null unique,
  payment_intent_id text,
  coins bigint not null check (coins > 0),
  amount_paid bigint not null check (amount_paid > 0),
  currency text not null check (currency = 'chf'),
  transaction_id uuid not null unique references public.transactions(id) on delete restrict,
  status text not null default 'paid' check (status in ('paid', 'refunded', 'review')),
  created_at timestamptz not null default now()
);

create index if not exists coin_purchases_user_idx on public.coin_purchases(user_id, created_at desc);
alter table public.coin_purchases enable row level security;

drop policy if exists "coin_purchases_select_own" on public.coin_purchases;
create policy "coin_purchases_select_own" on public.coin_purchases for select to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.coin_purchases from anon, authenticated;
grant select on public.coin_purchases to authenticated;

create or replace function public.credit_gibb_purchase(
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
  v_existing_transaction uuid;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'service_role_required';
  end if;
  if purchased_user is null or stripe_event is null or checkout_session is null then
    raise exception 'invalid_purchase';
  end if;
  if lower(paid_currency) <> 'chf' or not (
    (purchased_coins = 100 and paid_amount = 100) or
    (purchased_coins = 300 and paid_amount = 300) or
    (purchased_coins = 750 and paid_amount = 750)
  ) then
    raise exception 'invalid_pack';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(938241);

  select p.transaction_id into v_existing_transaction
  from public.coin_purchases p
  where p.stripe_event_id = stripe_event or p.checkout_session_id = checkout_session
  limit 1;
  if found then return v_existing_transaction; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = purchased_user
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;

  update public.wallets set balance = balance + purchased_coins where id = v_wallet.id;

  v_transaction_id := private.append_transaction(
    null,
    purchased_user,
    purchased_coins,
    'COIN_PURCHASE',
    'Stripe Checkout · ' || purchased_coins || ' GIBB für CHF ' ||
      pg_catalog.to_char(paid_amount::numeric / 100, 'FM999999990.00')
  );

  insert into public.coin_purchases (
    user_id, stripe_event_id, checkout_session_id, payment_intent_id,
    coins, amount_paid, currency, transaction_id
  ) values (
    purchased_user, stripe_event, checkout_session, payment_intent,
    purchased_coins, paid_amount, lower(paid_currency), v_transaction_id
  );

  insert into public.notifications (user_id, kind, title, message)
  values (purchased_user, 'coin_purchase', 'Coins gekauft', purchased_coins || ' GIBB wurden deinem Wallet gutgeschrieben.');

  return v_transaction_id;
end;
$$;

revoke all on function public.credit_gibb_purchase(text, text, text, uuid, bigint, bigint, text)
  from public, anon, authenticated;
grant execute on function public.credit_gibb_purchase(text, text, text, uuid, bigint, bigint, text)
  to service_role;
