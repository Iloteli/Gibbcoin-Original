-- Chain-Seite (mit dem Schlüssel aus "sudo gibb-chain-key"):
-- * node_owner_stats: Kennzahlen und Tagesverläufe (neue Konten, aktive Konten, Umlauf, Einnahmen)
-- * node_bulk_adjust: allen aktiven Konten auf einmal GIBB gutschreiben (z. B. Weihnachtsbonus)
-- * node_get_announcement / node_set_announcement: Banner auf der Hauptseite

create or replace function public.node_owner_stats(p_key text, p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_from date := (pg_catalog.now() at time zone 'Europe/Zurich')::date - (v_days - 1);
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'days', v_days,
    'totals', pg_catalog.jsonb_build_object(
      'users', (select pg_catalog.count(*) from public.wallets),
      'circulation', (select coalesce(pg_catalog.sum(balance), 0) from public.wallets),
      'active_7d', (select pg_catalog.count(distinct t.sender_user_id) from public.transactions t where t.sender_user_id is not null and t.created_at > pg_catalog.now() - interval '7 days'),
      'tx_24h', (select pg_catalog.count(*) from public.transactions t where t.created_at > pg_catalog.now() - interval '24 hours'),
      'revenue_rappen', (select coalesce(pg_catalog.sum(rappen), 0) from public.bank_orders where status = 'paid'),
      'revenue_gibb', (select coalesce(pg_catalog.sum(gibb), 0) from public.bank_orders where status = 'paid'),
      'bank_pending', (select pg_catalog.count(*) from public.bank_orders where status = 'pending')
    ),
    'series', (
      select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'day', d.day,
        'new_users', (select pg_catalog.count(*) from public.wallets w where (w.created_at at time zone 'Europe/Zurich')::date = d.day),
        'active', (select pg_catalog.count(distinct t.sender_user_id) from public.transactions t where t.sender_user_id is not null and (t.created_at at time zone 'Europe/Zurich')::date = d.day),
        'tx', (select pg_catalog.count(*) from public.transactions t where (t.created_at at time zone 'Europe/Zurich')::date = d.day),
        'revenue_rappen', (select coalesce(pg_catalog.sum(b.rappen), 0) from public.bank_orders b where b.status = 'paid' and (coalesce(b.decided_at, b.created_at) at time zone 'Europe/Zurich')::date = d.day)
      ) order by d.day), '[]'::jsonb)
      from (select pg_catalog.generate_series(v_from, v_from + (v_days - 1), interval '1 day')::date as day) d
    )
  );
end;
$$;
revoke all on function public.node_owner_stats(text, integer) from public;
grant execute on function public.node_owner_stats(text, integer) to anon, authenticated, service_role;

create or replace function public.node_bulk_adjust(p_key text, p_amount bigint, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_reason text := pg_catalog.left(pg_catalog.btrim(coalesce(p_reason, '')), 120);
  v_wallet record;
  v_count integer := 0;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount'); end if;
  if pg_catalog.char_length(v_reason) < 3 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'reason_required'); end if;

  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  for v_wallet in
    select w.id, w.user_id from public.wallets w
    where coalesce(w.status, 'active') <> 'locked' and (w.locked_until is null or w.locked_until < pg_catalog.now())
    order by w.created_at
    for update
  loop
    update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where id = v_wallet.id;
    perform private.append_transaction(null, v_wallet.user_id, p_amount, 'ADMIN_MINT', 'Bonus für alle · ' || v_reason);
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (v_wallet.user_id, 'admin_adjustment', 'Bonus erhalten', p_amount || ' GIBB für alle: ' || v_reason);
    exception when others then null; -- Mitteilung ist optional
    end;
    v_count := v_count + 1;
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'users', v_count, 'total', v_count * p_amount);
end;
$$;
revoke all on function public.node_bulk_adjust(text, bigint, text) from public;
grant execute on function public.node_bulk_adjust(text, bigint, text) to anon, authenticated, service_role;

create or replace function public.node_get_announcement(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'announcement', coalesce(
    (select value from private.admin_control_settings where key = 'announcement'),
    '{"enabled":false,"title":"","message":"","until":null}'::jsonb));
end;
$$;
revoke all on function public.node_get_announcement(text) from public;
grant execute on function public.node_get_announcement(text) to anon, authenticated, service_role;

create or replace function public.node_set_announcement(p_key text, p_enabled boolean, p_title text, p_message text, p_until timestamptz default null, p_tone text default 'info')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if coalesce(p_enabled, false) and pg_catalog.char_length(pg_catalog.btrim(coalesce(p_message, ''))) < 2 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'message_required');
  end if;
  v_value := pg_catalog.jsonb_build_object(
    'enabled', coalesce(p_enabled, false),
    'title', pg_catalog.left(pg_catalog.btrim(coalesce(p_title, '')), 80),
    'message', pg_catalog.left(pg_catalog.btrim(coalesce(p_message, '')), 400),
    'until', p_until,
    'tone', case when p_tone in ('info', 'success', 'warning') then p_tone else 'info' end
  );
  insert into private.admin_control_settings (key, value) values ('announcement', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'announcement', v_value);
end;
$$;
revoke all on function public.node_set_announcement(text, boolean, text, text, timestamptz, text) from public;
grant execute on function public.node_set_announcement(text, boolean, text, text, timestamptz, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
