-- Mehr Einstellungen für den Coinwert (GIBB-Markt) und die Miner.
--
-- Markt (neu einstellbar): Kurs direkt setzen, Kursänderung pro GIBB, Kursgrenzen, Verkaufsgebühr,
--   max. Menge pro Handel, Markt an/aus, Kaufen an/aus, Verkaufen an/aus, Verkaufslimit pro Tag.
-- Miner (neu): Halbierung der Belohnung alle N Blöcke, max. Blöcke pro Miner und Tag,
--   "nur mit echten Transaktionen minen" an/aus.
-- Ändern dürfen beides Ilja und Robyn (jeweils als Owner).

create or replace function private.can_edit_economy_settings(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
    and exists (select 1 from public.profiles p where p.id = p_user_id and p.role = 'super_admin')
    and (private.is_ilja(p_user_id) or p_user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'::uuid);
$$;
revoke all on function private.can_edit_economy_settings(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Markt
-- ---------------------------------------------------------------------------
alter table private.market_settings add column if not exists buy_enabled boolean not null default true;
alter table private.market_settings add column if not exists sell_enabled boolean not null default true;
alter table private.market_settings add column if not exists daily_sell_limit bigint not null default 0; -- 0 = kein Limit

create or replace function private.market_settings_json()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'price', s.price, 'step', s.step, 'min_price', s.min_price, 'max_price', s.max_price,
    'sell_fee', s.sell_fee, 'max_trade', s.max_trade, 'enabled', s.enabled,
    'buy_enabled', s.buy_enabled, 'sell_enabled', s.sell_enabled, 'daily_sell_limit', s.daily_sell_limit
  ) from private.market_settings s where s.singleton;
$$;
revoke all on function private.market_settings_json() from public, anon, authenticated;

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
    'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade,
    -- "enabled" prüft auch der Stripe-Checkout: dort zählt, ob Kaufen erlaubt ist.
    'enabled', v_s.enabled and v_s.buy_enabled,
    'market_enabled', v_s.enabled, 'buy_enabled', v_s.enabled and v_s.buy_enabled,
    'sell_enabled', v_s.enabled and v_s.sell_enabled
  );
end;
$$;

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
    'buy_enabled', v_s.enabled and v_s.buy_enabled, 'sell_enabled', v_s.enabled and v_s.sell_enabled,
    'daily_sell_limit', v_s.daily_sell_limit,
    'my_sold_24h', coalesce((select sum(e.gibb) from public.market_events e
                             where e.user_id = v_me and e.kind = 'sell' and e.created_at > pg_catalog.now() - interval '24 hours'), 0),
    'price_24h_ago', coalesce(v_day_ago, (select e.price_before from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours' order by e.created_at limit 1), v_s.price),
    'volume_24h', coalesce((select sum(e.gibb) from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours'), 0),
    'history', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('t', x.created_at, 'p', x.price_after, 'k', x.kind, 'n', x.gibb) order by x.created_at)
                         from (select * from public.market_events order by created_at desc limit 120) x), '[]'::jsonb),
    'my_gibb', (select w.balance from public.wallets w where w.user_id = v_me),
    'my_credits', (select w.credits from public.wallets w where w.user_id = v_me),
    'settings', case when private.can_edit_economy_settings(v_me) then private.market_settings_json() end
  );
end;
$$;

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
  v_limit bigint;
  v_sold bigint;
begin
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'market_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'sell_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'sell_disabled'); end if;
  if not (v_quote ->> 'sell_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'sell_rappen')::bigint;
  if v_rappen < 1 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'amount_too_small'); end if;

  select s.daily_sell_limit into v_limit from private.market_settings s where s.singleton;
  if v_limit > 0 then
    select coalesce(sum(e.gibb), 0) into v_sold from public.market_events e
    where e.user_id = v_me and e.kind = 'sell' and e.created_at > pg_catalog.now() - interval '24 hours';
    if v_sold + p_gibb > v_limit then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'daily_sell_limit', 'remaining', greatest(0, v_limit - v_sold));
    end if;
  end if;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.balance < p_gibb then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_funds'); end if;

  update public.wallets set balance = balance - p_gibb, credits = credits + v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(v_me, null, p_gibb, 'MARKET_SELL', 'GIBB-Markt · Verkauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('sell', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;

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

-- Markt-Einstellungen speichern (Ilja/Robyn, mit Admin-PIN)
create or replace function public.admin_update_market_settings(p_value jsonb, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb := private.market_settings_json();
  v_s private.market_settings%rowtype;
begin
  if not private.can_edit_economy_settings(v_admin) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if p_value is null or pg_catalog.jsonb_typeof(p_value) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  v_pin_status := private.check_admin_pin(v_admin, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select * into v_s from private.market_settings where singleton for update;
  v_s.min_price := greatest(0.01, least(100000, coalesce((p_value ->> 'min_price')::numeric, v_s.min_price)));
  v_s.max_price := greatest(0.01, least(100000, coalesce((p_value ->> 'max_price')::numeric, v_s.max_price)));
  if v_s.min_price > v_s.max_price then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_price_range');
  end if;
  v_s.price := greatest(v_s.min_price, least(v_s.max_price, coalesce((p_value ->> 'price')::numeric, v_s.price)));
  v_s.step := greatest(0, least(0.05, coalesce((p_value ->> 'step')::numeric, v_s.step)));
  v_s.sell_fee := greatest(0, least(0.9, coalesce((p_value ->> 'sell_fee')::numeric, v_s.sell_fee)));
  v_s.max_trade := greatest(1, least(100000, coalesce((p_value ->> 'max_trade')::bigint, v_s.max_trade)));
  v_s.enabled := coalesce((p_value ->> 'enabled')::boolean, v_s.enabled);
  v_s.buy_enabled := coalesce((p_value ->> 'buy_enabled')::boolean, v_s.buy_enabled);
  v_s.sell_enabled := coalesce((p_value ->> 'sell_enabled')::boolean, v_s.sell_enabled);
  v_s.daily_sell_limit := greatest(0, least(10000000, coalesce((p_value ->> 'daily_sell_limit')::bigint, v_s.daily_sell_limit)));

  update private.market_settings set
    price = v_s.price, step = v_s.step, min_price = v_s.min_price, max_price = v_s.max_price,
    sell_fee = v_s.sell_fee, max_trade = v_s.max_trade, enabled = v_s.enabled,
    buy_enabled = v_s.buy_enabled, sell_enabled = v_s.sell_enabled, daily_sell_limit = v_s.daily_sell_limit,
    updated_at = pg_catalog.now()
  where singleton;

  perform private.write_admin_audit(v_admin, v_admin, 'MARKET_SETTING_CHANGED', v_before, private.market_settings_json(), 'Markt-Einstellungen geändert');
  return pg_catalog.jsonb_build_object('ok', true, 'settings', private.market_settings_json());
end;
$$;

revoke all on function public.market_quote(bigint) from public, anon;
revoke all on function public.get_market_state() from public, anon;
revoke all on function public.market_sell(bigint) from public, anon;
revoke all on function public.market_buy_with_credits(bigint) from public, anon;
revoke all on function public.admin_update_market_settings(jsonb, text) from public, anon;
grant execute on function public.market_quote(bigint) to authenticated, service_role;
grant execute on function public.get_market_state() to authenticated;
grant execute on function public.market_sell(bigint) to authenticated;
grant execute on function public.market_buy_with_credits(bigint) to authenticated;
grant execute on function public.admin_update_market_settings(jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Miner
-- ---------------------------------------------------------------------------
create or replace function private.blockchain_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'enabled', coalesce((s.value ->> 'enabled')::boolean, true),
    'reward', greatest(0, least(1000, coalesce((s.value ->> 'reward')::bigint, 2))),
    'target_seconds', greatest(10, least(86400, coalesce((s.value ->> 'target_seconds')::integer, 120))),
    'min_bits', greatest(8, least(48, coalesce((s.value ->> 'min_bits')::integer, 16))),
    'max_bits', greatest(8, least(48, coalesce((s.value ->> 'max_bits')::integer, 36))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((s.value ->> 'cooldown_seconds')::integer, 90))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((s.value ->> 'max_tx_per_block')::integer, 500))),
    'halving_blocks', greatest(0, least(1000000, coalesce((s.value ->> 'halving_blocks')::integer, 0))),
    'max_blocks_per_day', greatest(0, least(100000, coalesce((s.value ->> 'max_blocks_per_day')::integer, 0))),
    'require_real_tx', coalesce((s.value ->> 'require_real_tx')::boolean, true)
  )
  from (select coalesce((select value from private.admin_control_settings where key = 'blockchain'), '{}'::jsonb) as value) s;
$$;
revoke all on function private.blockchain_settings() from public, anon, authenticated;

-- Belohnung für einen Block: Grundbelohnung, halbiert alle "halving_blocks" Blöcke.
create or replace function private.block_reward(p_height bigint)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when (s ->> 'halving_blocks')::integer > 0
      then ((s ->> 'reward')::bigint >> least(62, (greatest(0, p_height) / (s ->> 'halving_blocks')::integer))::integer)
    else (s ->> 'reward')::bigint end
  from (select private.blockchain_settings() as s) x;
$$;
revoke all on function private.block_reward(bigint) from public, anon, authenticated;

create or replace function public.admin_update_blockchain_settings(p_value jsonb, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb := private.blockchain_settings();
  v_after jsonb;
begin
  if not private.can_edit_economy_settings(v_admin) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if p_value is null or pg_catalog.jsonb_typeof(p_value) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  v_pin_status := private.check_admin_pin(v_admin, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_after := pg_catalog.jsonb_build_object(
    'enabled', coalesce((p_value ->> 'enabled')::boolean, (v_before ->> 'enabled')::boolean),
    'reward', greatest(0, least(1000, coalesce((p_value ->> 'reward')::bigint, (v_before ->> 'reward')::bigint))),
    'target_seconds', greatest(10, least(86400, coalesce((p_value ->> 'target_seconds')::integer, (v_before ->> 'target_seconds')::integer))),
    'min_bits', greatest(8, least(48, coalesce((p_value ->> 'min_bits')::integer, (v_before ->> 'min_bits')::integer))),
    'max_bits', greatest(8, least(48, coalesce((p_value ->> 'max_bits')::integer, (v_before ->> 'max_bits')::integer))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((p_value ->> 'cooldown_seconds')::integer, (v_before ->> 'cooldown_seconds')::integer))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((p_value ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer))),
    'halving_blocks', greatest(0, least(1000000, coalesce((p_value ->> 'halving_blocks')::integer, (v_before ->> 'halving_blocks')::integer))),
    'max_blocks_per_day', greatest(0, least(100000, coalesce((p_value ->> 'max_blocks_per_day')::integer, (v_before ->> 'max_blocks_per_day')::integer))),
    'require_real_tx', coalesce((p_value ->> 'require_real_tx')::boolean, (v_before ->> 'require_real_tx')::boolean)
  );
  if (v_after ->> 'min_bits')::integer > (v_after ->> 'max_bits')::integer then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_difficulty_range');
  end if;

  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('blockchain', v_after, v_admin, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;

  perform private.write_admin_audit(v_admin, v_admin, 'BLOCKCHAIN_SETTING_CHANGED', v_before, v_after, 'Blockchain-Einstellungen geändert');

  return pg_catalog.jsonb_build_object('ok', true, 'settings', v_after);
end;
$$;
revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

-- Bestehende Mining-Funktionen gezielt ergänzen (Text-Patch, damit Cloud-Anpassungen erhalten bleiben).
do $migration$
declare
  v_def text;
  v_anchor text;
  v_real_old constant text := $r$-- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if not exists ($r$;
  v_real_new constant text := $r$-- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if coalesce((private.blockchain_settings() ->> 'require_real_tx')::boolean, true) and not exists ($r$;
begin
  -- Vorlage
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_block_template()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'miner_settings_v2') = 0 then
    v_def := pg_catalog.replace(v_def, v_real_old, v_real_new);
    v_anchor := $a$'reward', (v_settings ->> 'reward')::bigint,$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'get_block_template: Belohnung nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $b$'reward', private.block_reward(v_height), -- miner_settings_v2$b$);
    execute v_def;
  end if;

  -- Einreichen
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'miner_settings_v2') = 0 then
    v_def := pg_catalog.replace(v_def, v_real_old, v_real_new);
    v_anchor := $a$v_reward bigint := (v_settings ->> 'reward')::bigint;$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'submit_mined_block: Belohnung nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $b$v_reward bigint := private.block_reward(p_height); -- miner_settings_v2$b$);
    v_anchor := '  select * into v_tip from public.blocks order by height desc limit 1;';
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'submit_mined_block: Einfügestelle nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $c$  -- Tageslimit pro Miner (0 = unbegrenzt)
  if (v_settings ->> 'max_blocks_per_day')::integer > 0 and (
    select count(*) from public.blocks b
    where b.miner_user_id = v_user_id and b.mined_at > v_now - interval '24 hours'
  ) >= (v_settings ->> 'max_blocks_per_day')::integer then
    raise exception 'mining_daily_limit';
  end if;

$c$ || v_anchor);
    execute v_def;
  end if;

  -- Übersicht: zusätzliche Einstellungen mitliefern
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'miner_settings_v2') = 0 then
    v_anchor := $a$'max_bits', (v_settings ->> 'max_bits')::integer,$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'get_blockchain_overview: Einfügestelle nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, v_anchor || $b$
    'halving_blocks', (v_settings ->> 'halving_blocks')::integer, -- miner_settings_v2
    'max_blocks_per_day', (v_settings ->> 'max_blocks_per_day')::integer,
    'require_real_tx', (v_settings ->> 'require_real_tx')::boolean,
    'next_reward', private.block_reward(coalesce(v_tip.height, -1) + 1),
    'can_edit_settings', private.can_edit_economy_settings(v_user_id),$b$);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';
