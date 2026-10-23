-- Kasse für Läden (mit GIBB bezahlen per QR-Code) und Auszahlung von Credits als echtes Geld.
-- Läden schaltet der Owner auf der Chain-Seite frei. Auszahlungen bezahlt der Owner per Überweisung
-- und markiert sie danach als erledigt (keine Gebühren, kein Zahlungsanbieter).

-- ---------- Läden ----------
create table if not exists private.merchants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  shop_name text not null check (char_length(shop_name) between 2 and 40),
  enabled boolean not null default true,
  created_at timestamptz not null default pg_catalog.now()
);
revoke all on table private.merchants from public, anon, authenticated;

create table if not exists public.shop_invoices (
  id uuid primary key default extensions.gen_random_uuid(),
  merchant_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount between 1 and 100000),
  note text check (note is null or char_length(note) <= 80),
  status text not null default 'open' check (status in ('open', 'paid', 'cancelled')),
  payer_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null default pg_catalog.now() + interval '10 minutes',
  paid_at timestamptz
);
create index if not exists shop_invoices_merchant_idx on public.shop_invoices (merchant_id, created_at desc);
alter table public.shop_invoices enable row level security;
alter table public.shop_invoices force row level security;
revoke all on table public.shop_invoices from public, anon, authenticated;

create or replace function private.shop_name_of(p_user uuid)
returns text language sql stable security definer set search_path = ''
as $$ select m.shop_name from private.merchants m where m.user_id = p_user and m.enabled; $$;
revoke all on function private.shop_name_of(uuid) from public, anon, authenticated;

-- Bin ich ein Laden?
create or replace function public.shop_status()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_name text := private.shop_name_of(auth.uid());
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  return pg_catalog.jsonb_build_object('is_merchant', v_name is not null, 'shop_name', v_name);
end;
$$;

-- Kasse: Rechnung mit Betrag erstellen (gilt 10 Minuten, nur einmal bezahlbar)
create or replace function public.shop_create_invoice(p_amount bigint, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_inv public.shop_invoices%rowtype;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  if private.shop_name_of(v_me) is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_a_shop'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount'); end if;
  -- alte offene Rechnungen dieses Ladens schliessen
  update public.shop_invoices set status = 'cancelled' where merchant_id = v_me and status = 'open';
  insert into public.shop_invoices (merchant_id, amount, note)
  values (v_me, p_amount, nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_note, '')), 80), ''))
  returning * into v_inv;
  return pg_catalog.jsonb_build_object('ok', true, 'id', v_inv.id, 'amount', v_inv.amount, 'expires_at', v_inv.expires_at);
end;
$$;

-- Kasse: Stand der Rechnung (nur der eigene Laden)
create or replace function public.shop_invoice_status(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_inv public.shop_invoices%rowtype; v_payer text;
begin
  select * into v_inv from public.shop_invoices where id = p_id and merchant_id = auth.uid();
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select coalesce(nullif(p.username, ''), p.display_name) into v_payer from public.profiles p where p.id = v_inv.payer_id;
  return pg_catalog.jsonb_build_object('ok', true, 'status',
    case when v_inv.status = 'open' and v_inv.expires_at < pg_catalog.now() then 'expired' else v_inv.status end,
    'amount', v_inv.amount, 'payer', v_payer, 'paid_at', v_inv.paid_at);
end;
$$;

create or replace function public.shop_cancel_invoice(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
begin
  update public.shop_invoices set status = 'cancelled' where id = p_id and merchant_id = auth.uid() and status = 'open';
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

-- Kunde: Was soll ich bezahlen?
create or replace function public.shop_invoice_info(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_inv public.shop_invoices%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select * into v_inv from public.shop_invoices where id = p_id;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'shop_name', coalesce(private.shop_name_of(v_inv.merchant_id), 'Laden'),
    'amount', v_inv.amount, 'note', v_inv.note,
    'status', case when v_inv.status = 'open' and v_inv.expires_at < pg_catalog.now() then 'expired' else v_inv.status end,
    'own', v_inv.merchant_id = auth.uid());
end;
$$;

-- Kunde: bezahlen (normale GIBB-Überweisung an den Laden, landet in der Kette)
create or replace function public.shop_pay_invoice(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_inv public.shop_invoices%rowtype;
  v_shop text;
  v_result jsonb;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  select * into v_inv from public.shop_invoices where id = p_id for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_inv.status = 'paid' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'already_paid'); end if;
  if v_inv.status <> 'open' or v_inv.expires_at < pg_catalog.now() then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invoice_expired'); end if;
  if v_inv.merchant_id = v_me then return pg_catalog.jsonb_build_object('ok', false, 'error', 'own_invoice'); end if;
  v_shop := private.shop_name_of(v_inv.merchant_id);
  if v_shop is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_a_shop'); end if;
  v_result := public.transfer_coins_with_guardian_approval(v_inv.merchant_id, v_inv.amount, pg_catalog.left('Einkauf bei ' || v_shop || coalesce(': ' || v_inv.note, ''), 160));
  if coalesce(v_result ->> 'status', '') = 'pending' then
    raise exception 'shop_payment_needs_approval';
  end if;
  update public.shop_invoices set status = 'paid', payer_id = v_me, paid_at = pg_catalog.now() where id = p_id;
  return pg_catalog.jsonb_build_object('ok', true, 'shop_name', v_shop, 'amount', v_inv.amount);
end;
$$;

-- Kasse: letzte Verkäufe
create or replace function public.shop_list_sales(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', i.id, 'amount', i.amount, 'note', i.note, 'paid_at', i.paid_at,
    'payer', (select coalesce(nullif(p.username, ''), p.display_name) from public.profiles p where p.id = i.payer_id)
  ) order by i.paid_at desc), '[]'::jsonb)
  from (select * from public.shop_invoices where merchant_id = auth.uid() and status = 'paid'
        order by paid_at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) i;
$$;

revoke all on function public.shop_status() from public, anon;
revoke all on function public.shop_create_invoice(bigint, text) from public, anon;
revoke all on function public.shop_invoice_status(uuid) from public, anon;
revoke all on function public.shop_cancel_invoice(uuid) from public, anon;
revoke all on function public.shop_invoice_info(uuid) from public, anon;
revoke all on function public.shop_pay_invoice(uuid) from public, anon;
revoke all on function public.shop_list_sales(integer) from public, anon;
grant execute on function public.shop_status() to authenticated;
grant execute on function public.shop_create_invoice(bigint, text) to authenticated;
grant execute on function public.shop_invoice_status(uuid) to authenticated;
grant execute on function public.shop_cancel_invoice(uuid) to authenticated;
grant execute on function public.shop_invoice_info(uuid) to authenticated;
grant execute on function public.shop_pay_invoice(uuid) to authenticated;
grant execute on function public.shop_list_sales(integer) to authenticated;

-- Chain-Seite: Läden verwalten
create or replace function public.node_list_merchants(p_key text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'merchants', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'user_id', m.user_id, 'shop_name', m.shop_name, 'enabled', m.enabled,
      'username', p.username,
      'sales', (select pg_catalog.count(*) from public.shop_invoices i where i.merchant_id = m.user_id and i.status = 'paid'),
      'revenue', (select coalesce(sum(i.amount), 0) from public.shop_invoices i where i.merchant_id = m.user_id and i.status = 'paid')
    ) order by m.shop_name)
    from private.merchants m join public.profiles p on p.id = m.user_id
  ), '[]'::jsonb));
end;
$$;

create or replace function public.node_set_merchant(p_key text, p_user uuid, p_shop_name text, p_enabled boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_name text := pg_catalog.btrim(coalesce(p_shop_name, ''));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p_enabled is null then
    delete from private.merchants where user_id = p_user;
    return pg_catalog.jsonb_build_object('ok', true, 'removed', true);
  end if;
  if pg_catalog.char_length(v_name) not between 2 and 40 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_shop_name'); end if;
  insert into private.merchants (user_id, shop_name, enabled) values (p_user, v_name, p_enabled)
  on conflict (user_id) do update set shop_name = excluded.shop_name, enabled = excluded.enabled;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_list_merchants(text) from public;
revoke all on function public.node_set_merchant(text, uuid, text, boolean) from public;
grant execute on function public.node_list_merchants(text) to anon, authenticated, service_role;
grant execute on function public.node_set_merchant(text, uuid, text, boolean) to anon, authenticated, service_role;

-- ---------- Auszahlung von Credits ----------
create table if not exists public.payout_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  rappen bigint not null check (rappen > 0),
  iban text not null check (char_length(iban) between 15 and 34),
  holder text not null check (char_length(holder) between 2 and 80),
  status text not null default 'pending' check (status in ('pending', 'paid', 'rejected', 'cancelled')),
  created_at timestamptz not null default pg_catalog.now(),
  decided_at timestamptz
);
create index if not exists payout_requests_user_idx on public.payout_requests (user_id, created_at desc);
alter table public.payout_requests enable row level security;
alter table public.payout_requests force row level security;
revoke all on table public.payout_requests from public, anon, authenticated;

create or replace function private.payout_settings()
returns jsonb language sql stable security definer set search_path = ''
as $$ select coalesce((select s.value from private.admin_control_settings s where s.key = 'payouts'), '{"enabled":false,"min_rappen":500}'::jsonb); $$;
revoke all on function private.payout_settings() from public, anon, authenticated;

create or replace function public.get_payout_state()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_me uuid := auth.uid(); v_set jsonb := private.payout_settings();
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  return pg_catalog.jsonb_build_object(
    'enabled', coalesce((v_set ->> 'enabled')::boolean, false),
    'min_rappen', coalesce((v_set ->> 'min_rappen')::bigint, 500),
    'credits', (select w.credits from public.wallets w where w.user_id = v_me),
    'requests', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', r.id, 'rappen', r.rappen, 'status', r.status, 'created_at', r.created_at,
        'iban_end', pg_catalog.right(r.iban, 4)) order by r.created_at desc)
      from (select * from public.payout_requests where user_id = v_me order by created_at desc limit 10) r), '[]'::jsonb));
end;
$$;

-- Credits werden sofort reserviert (abgezogen); bei Ablehnen/Abbrechen kommen sie zurück.
create or replace function public.request_payout(p_rappen bigint, p_iban text, p_holder text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_set jsonb := private.payout_settings();
  v_iban text := pg_catalog.upper(pg_catalog.regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
  v_holder text := pg_catalog.btrim(coalesce(p_holder, ''));
  v_wallet public.wallets%rowtype;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  if not coalesce((v_set ->> 'enabled')::boolean, false) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'payouts_disabled'); end if;
  if p_rappen is null or p_rappen < coalesce((v_set ->> 'min_rappen')::bigint, 500) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'below_minimum'); end if;
  if v_iban !~ '^(CH|LI)[0-9]{2}[0-9A-Z]{17}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_iban'); end if;
  if pg_catalog.char_length(v_holder) not between 2 and 80 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_holder'); end if;
  if exists (select 1 from public.payout_requests where user_id = v_me and status = 'pending') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'payout_pending');
  end if;
  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.id is null or v_wallet.status <> 'active' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_locked'); end if;
  if v_wallet.credits < p_rappen then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_credits'); end if;
  update public.wallets set credits = credits - p_rappen, updated_at = pg_catalog.now() where id = v_wallet.id;
  insert into public.payout_requests (user_id, rappen, iban, holder) values (v_me, p_rappen, v_iban, v_holder);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.cancel_my_payout(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_req public.payout_requests%rowtype;
begin
  select * into v_req from public.payout_requests where id = p_id and user_id = auth.uid() and status = 'pending' for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update public.payout_requests set status = 'cancelled', decided_at = pg_catalog.now() where id = p_id;
  update public.wallets set credits = credits + v_req.rappen, updated_at = pg_catalog.now() where user_id = v_req.user_id;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.get_payout_state() from public, anon;
revoke all on function public.request_payout(bigint, text, text) from public, anon;
revoke all on function public.cancel_my_payout(uuid) from public, anon;
grant execute on function public.get_payout_state() to authenticated;
grant execute on function public.request_payout(bigint, text, text) to authenticated;
grant execute on function public.cancel_my_payout(uuid) to authenticated;

-- Chain-Seite: Auszahlungen ansehen, als bezahlt markieren oder ablehnen; Einstellungen
create or replace function public.node_list_payouts(p_key text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'settings', private.payout_settings(), 'payouts', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', r.id, 'rappen', r.rappen, 'iban', r.iban, 'holder', r.holder, 'status', r.status,
      'created_at', r.created_at, 'decided_at', r.decided_at,
      'username', (select coalesce(nullif(p.username, ''), p.display_name) from public.profiles p where p.id = r.user_id)
    ) order by (r.status = 'pending') desc, r.created_at desc)
    from (select * from public.payout_requests order by created_at desc limit 100) r
  ), '[]'::jsonb));
end;
$$;

create or replace function public.node_decide_payout(p_key text, p_id uuid, p_status text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_req public.payout_requests%rowtype;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_status not in ('paid', 'rejected') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_status'); end if;
  select * into v_req from public.payout_requests where id = p_id and status = 'pending' for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update public.payout_requests set status = p_status, decided_at = pg_catalog.now() where id = p_id;
  if p_status = 'rejected' then
    update public.wallets set credits = credits + v_req.rappen, updated_at = pg_catalog.now() where user_id = v_req.user_id;
  end if;
  insert into public.notifications (user_id, kind, title, message) values (v_req.user_id, 'payout',
    case when p_status = 'paid' then 'Auszahlung überwiesen' else 'Auszahlung abgelehnt' end,
    case when p_status = 'paid' then 'CHF ' || pg_catalog.to_char(v_req.rappen / 100.0, 'FM999990.00') || ' wurden auf dein Konto überwiesen.'
         else 'Deine Auszahlung wurde abgelehnt. Die Credits sind wieder in deinem Wallet.' end);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.node_set_payouts(p_key text, p_enabled boolean, p_min_rappen bigint)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_value := pg_catalog.jsonb_build_object('enabled', coalesce(p_enabled, false),
    'min_rappen', least(greatest(coalesce(p_min_rappen, 500), 100), 1000000));
  insert into private.admin_control_settings (key, value) values ('payouts', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'settings', v_value);
end;
$$;
revoke all on function public.node_list_payouts(text) from public;
revoke all on function public.node_decide_payout(text, uuid, text) from public;
revoke all on function public.node_set_payouts(text, boolean, bigint) from public;
grant execute on function public.node_list_payouts(text) to anon, authenticated, service_role;
grant execute on function public.node_decide_payout(text, uuid, text) to anon, authenticated, service_role;
grant execute on function public.node_set_payouts(text, boolean, bigint) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
