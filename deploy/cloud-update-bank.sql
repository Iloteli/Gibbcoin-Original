-- GIBB per Banküberweisung kaufen.
-- * Hauptseite: Kundin/Kunde erstellt eine Bestellung, bekommt IBAN, Betrag und Verwendungszweck.
-- * Chain-Seite (Ilja): sieht offene Bestellungen und bestätigt den Zahlungseingang -> GIBB werden gutgeschrieben.
-- IBAN und Kontoinhaber trägt Ilja auf der Chain-Seite ein; sie werden mit dem Chain-Schlüssel übertragen.

alter table private.market_settings add column if not exists bank_enabled boolean not null default false;
alter table private.market_settings add column if not exists bank_iban text not null default '';
alter table private.market_settings add column if not exists bank_holder text not null default '';

alter table public.market_events drop constraint if exists market_events_kind_check;
alter table public.market_events add constraint market_events_kind_check
  check (kind in ('buy_stripe', 'buy_credits', 'buy_bank', 'sell'));

create table if not exists public.bank_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  gibb bigint not null check (gibb > 0),
  rappen bigint not null check (rappen >= 100),
  reference text not null unique,
  status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  transaction_id uuid
);
create index if not exists bank_orders_user_idx on public.bank_orders(user_id, created_at desc);
alter table public.bank_orders enable row level security;
drop policy if exists "read own bank orders" on public.bank_orders;
create policy "read own bank orders" on public.bank_orders for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.bank_orders from anon, authenticated;
grant select on public.bank_orders to authenticated;

-- Bestellung anlegen (Preis wird zum aktuellen Kurs festgehalten; Überweisung ab CHF 1.00)
create or replace function public.create_bank_order(p_gibb bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_s private.market_settings%rowtype;
  v_quote jsonb;
  v_rappen bigint;
  v_ref text;
  v_order public.bank_orders%rowtype;
begin
  select * into v_s from private.market_settings where singleton;
  if not v_s.enabled or not v_s.buy_enabled then return pg_catalog.jsonb_build_object('ok', false, 'error', 'buy_disabled'); end if;
  if not v_s.bank_enabled or pg_catalog.btrim(v_s.bank_iban) = '' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'bank_disabled'); end if;
  if (select count(*) from public.bank_orders o where o.user_id = v_me and o.status = 'pending') >= 3 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'too_many_open_orders');
  end if;
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'buy_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'buy_rappen')::bigint;
  if v_rappen < 100 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'bank_amount_too_small'); end if;
  loop
    v_ref := 'GIBB-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.translate(pg_catalog.encode(extensions.gen_random_bytes(8), 'base64'), '+/=0O1Il', ''), 1, 6));
    exit when pg_catalog.char_length(v_ref) = 11 and not exists (select 1 from public.bank_orders o where o.reference = v_ref);
  end loop;
  insert into public.bank_orders (user_id, gibb, rappen, reference) values (v_me, p_gibb, v_rappen, v_ref) returning * into v_order;
  return pg_catalog.jsonb_build_object('ok', true, 'id', v_order.id, 'gibb', v_order.gibb, 'rappen', v_order.rappen,
    'reference', v_order.reference, 'iban', v_s.bank_iban, 'holder', v_s.bank_holder);
end;
$$;
revoke all on function public.create_bank_order(bigint) from public, anon;
grant execute on function public.create_bank_order(bigint) to authenticated;

create or replace function public.cancel_bank_order(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
begin
  update public.bank_orders set status = 'cancelled', decided_at = pg_catalog.now()
  where id = p_id and user_id = v_me and status = 'pending';
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.cancel_bank_order(uuid) from public, anon;
grant execute on function public.cancel_bank_order(uuid) to authenticated;

-- Bankdaten für die Anzeige (nur angemeldete Nutzer)
create or replace function public.get_bank_details()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object('enabled', s.bank_enabled and pg_catalog.btrim(s.bank_iban) <> '', 'iban', s.bank_iban, 'holder', s.bank_holder)
  from private.market_settings s where s.singleton;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

-- Chain-Seite: Bankdaten setzen
create or replace function public.node_set_bank_settings(p_key text, p_enabled boolean, p_iban text, p_holder text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_iban text := pg_catalog.upper(pg_catalog.regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_iban <> '' and v_iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_iban');
  end if;
  -- Für die Anzeige in Vierergruppen
  v_iban := pg_catalog.btrim(pg_catalog.regexp_replace(v_iban, '(.{4})', '\1 ', 'g'));
  update private.market_settings set bank_enabled = coalesce(p_enabled, false), bank_iban = v_iban,
    bank_holder = pg_catalog.left(pg_catalog.btrim(coalesce(p_holder, '')), 80), updated_at = pg_catalog.now()
  where singleton;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_bank_settings(text, boolean, text, text) from public;
grant execute on function public.node_set_bank_settings(text, boolean, text, text) to anon, authenticated, service_role;

-- Chain-Seite: Bestellungen auflisten
create or replace function public.node_list_bank_orders(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'orders', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', o.id, 'gibb', o.gibb, 'rappen', o.rappen, 'reference', o.reference, 'status', o.status,
      'created_at', o.created_at, 'decided_at', o.decided_at,
      'username', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer')
    ) order by (o.status = 'pending') desc, o.created_at desc)
    from (select * from public.bank_orders order by created_at desc limit 200) o
    left join public.profiles p on p.id = o.user_id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_bank_orders(text) from public;
grant execute on function public.node_list_bank_orders(text) to anon, authenticated, service_role;

-- Chain-Seite: Zahlung bestätigen (GIBB gutschreiben) oder ablehnen
create or replace function public.node_decide_bank_order(p_key text, p_id uuid, p_paid boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_order public.bank_orders%rowtype;
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  select * into v_order from public.bank_orders where id = p_id for update;
  if v_order.id is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_order.status <> 'pending' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'already_decided'); end if;

  if not coalesce(p_paid, false) then
    update public.bank_orders set status = 'rejected', decided_at = pg_catalog.now() where id = p_id;
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (v_order.user_id, 'coin_purchase', 'Überweisung nicht erhalten',
              'Für die Bestellung ' || v_order.reference || ' ist keine Zahlung eingegangen. Die Bestellung wurde geschlossen.');
    exception when others then null;
    end;
    return pg_catalog.jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  update public.wallets set balance = balance + v_order.gibb, updated_at = pg_catalog.now() where user_id = v_order.user_id;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found'); end if;
  v_tx := private.append_transaction(null, v_order.user_id, v_order.gibb, 'COIN_PURCHASE',
    'GIBB-Kauf per Überweisung · ' || v_order.reference || ' · CHF ' || pg_catalog.to_char(v_order.rappen::numeric / 100, 'FM999999990.00'));
  update public.bank_orders set status = 'paid', decided_at = pg_catalog.now(), transaction_id = v_tx where id = p_id;
  perform private.market_apply('buy_bank', v_order.user_id, v_order.gibb, v_order.rappen, 'bank:' || v_order.reference);
  begin
    insert into public.notifications (user_id, kind, title, message)
    values (v_order.user_id, 'coin_purchase', 'Coins gekauft', v_order.gibb || ' GIBB wurden deinem Wallet gutgeschrieben (Überweisung ' || v_order.reference || ').');
  exception when others then null;
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'status', 'paid', 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_decide_bank_order(text, uuid, boolean) from public;
grant execute on function public.node_decide_bank_order(text, uuid, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
