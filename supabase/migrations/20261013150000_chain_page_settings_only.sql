-- Einstellungen nur noch auf der Chain-Seite (Ilja).
-- * Auf der Hauptseite gibt es keine Blockchain-/Coinwert-Einstellungen mehr; die Admin-Funktionen
--   lehnen jede Änderung ab.
-- * Die Chain-Seite (Node) überträgt ihre Einstellungen mit einem geheimen Schlüssel über
--   public.node_push_settings(). Den Schlüssel erzeugt "sudo gibb-chain-key" auf dem Server; der
--   Befehl gibt die passende Zeile "select private.set_node_settings_key('…');" für den SQL Editor aus.

create table if not exists private.node_settings_key (
  singleton boolean primary key default true check (singleton),
  key_hash text not null,
  updated_at timestamptz not null default now()
);
revoke all on table private.node_settings_key from public, anon, authenticated;

create or replace function private.set_node_settings_key(p_key text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_key is null or pg_catalog.char_length(p_key) < 32 then raise exception 'key_too_short'; end if;
  insert into private.node_settings_key (singleton, key_hash, updated_at)
  values (true, pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex'), pg_catalog.now())
  on conflict (singleton) do update set key_hash = excluded.key_hash, updated_at = excluded.updated_at;
  return 'Schlüssel der Chain-Seite gespeichert';
end;
$$;
revoke all on function private.set_node_settings_key(text) from public, anon, authenticated;

-- Hauptseite: niemand darf dort mehr Einstellungen ändern oder sehen.
create or replace function private.can_edit_economy_settings(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select false; $$;
revoke all on function private.can_edit_economy_settings(uuid) from public, anon, authenticated;

create or replace function public.admin_update_blockchain_settings(p_value jsonb, p_pin text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required'); $$;
revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

create or replace function public.admin_update_market_settings(p_value jsonb, p_pin text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required'); $$;
revoke all on function public.admin_update_market_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_market_settings(jsonb, text) to authenticated;

-- Kaufen und Verkaufen vorerst ausgeschaltet (auf der Chain-Seite wieder einschaltbar).
update private.market_settings set buy_enabled = false, sell_enabled = false, updated_at = now() where singleton;

-- Alle Kurse zurücksetzen: 1 Rp pro GIBB, Kursverlauf leer.
update private.market_settings set price = 1, updated_at = now() where singleton;
delete from public.market_events;

-- Chain-Seite -> Hauptseite
create or replace function public.node_push_settings(p_key text, p_blockchain jsonb, p_market jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_before jsonb := private.blockchain_settings();
  v_after jsonb;
  v_s private.market_settings%rowtype;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;

  if p_blockchain is not null and pg_catalog.jsonb_typeof(p_blockchain) = 'object' then
    v_after := pg_catalog.jsonb_build_object(
      'enabled', coalesce((p_blockchain ->> 'enabled')::boolean, (v_before ->> 'enabled')::boolean),
      'reward', greatest(0, least(1000, coalesce((p_blockchain ->> 'reward')::bigint, (v_before ->> 'reward')::bigint))),
      'target_seconds', greatest(10, least(86400, coalesce((p_blockchain ->> 'target_seconds')::integer, (v_before ->> 'target_seconds')::integer))),
      'min_bits', greatest(8, least(48, coalesce((p_blockchain ->> 'min_bits')::integer, (v_before ->> 'min_bits')::integer))),
      'max_bits', greatest(8, least(48, coalesce((p_blockchain ->> 'max_bits')::integer, (v_before ->> 'max_bits')::integer))),
      'cooldown_seconds', greatest(0, least(86400, coalesce((p_blockchain ->> 'cooldown_seconds')::integer, (v_before ->> 'cooldown_seconds')::integer))),
      'max_tx_per_block', greatest(1, least(2000, coalesce((p_blockchain ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer))),
      'halving_blocks', greatest(0, least(1000000, coalesce((p_blockchain ->> 'halving_blocks')::integer, (v_before ->> 'halving_blocks')::integer))),
      'max_blocks_per_day', greatest(0, least(100000, coalesce((p_blockchain ->> 'max_blocks_per_day')::integer, (v_before ->> 'max_blocks_per_day')::integer))),
      'require_real_tx', coalesce((p_blockchain ->> 'require_real_tx')::boolean, (v_before ->> 'require_real_tx')::boolean)
    );
    if (v_after ->> 'min_bits')::integer > (v_after ->> 'max_bits')::integer then
      v_after := v_after || pg_catalog.jsonb_build_object('max_bits', (v_after ->> 'min_bits')::integer);
    end if;
    insert into private.admin_control_settings (key, value, updated_by, updated_at)
    values ('blockchain', v_after, null, pg_catalog.clock_timestamp())
    on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  end if;

  if p_market is not null and pg_catalog.jsonb_typeof(p_market) = 'object' then
    select * into v_s from private.market_settings where singleton for update;
    v_s.min_price := greatest(0.01, least(100000, coalesce((p_market ->> 'min_price')::numeric, v_s.min_price)));
    v_s.max_price := greatest(v_s.min_price, least(100000, coalesce((p_market ->> 'max_price')::numeric, v_s.max_price)));
    -- Kurs nur setzen, wenn ausdrücklich mitgeschickt (sonst bewegt ihn der Handel)
    v_s.price := greatest(v_s.min_price, least(v_s.max_price, coalesce((p_market ->> 'price')::numeric, v_s.price)));
    v_s.step := greatest(0, least(0.05, coalesce((p_market ->> 'step')::numeric, v_s.step)));
    v_s.sell_fee := greatest(0, least(0.9, coalesce((p_market ->> 'sell_fee')::numeric, v_s.sell_fee)));
    v_s.max_trade := greatest(1, least(100000, coalesce((p_market ->> 'max_trade')::bigint, v_s.max_trade)));
    v_s.enabled := coalesce((p_market ->> 'enabled')::boolean, v_s.enabled);
    v_s.buy_enabled := coalesce((p_market ->> 'buy_enabled')::boolean, v_s.buy_enabled);
    v_s.sell_enabled := coalesce((p_market ->> 'sell_enabled')::boolean, v_s.sell_enabled);
    v_s.daily_sell_limit := greatest(0, least(10000000, coalesce((p_market ->> 'daily_sell_limit')::bigint, v_s.daily_sell_limit)));
    update private.market_settings set
      price = v_s.price, step = v_s.step, min_price = v_s.min_price, max_price = v_s.max_price,
      sell_fee = v_s.sell_fee, max_trade = v_s.max_trade, enabled = v_s.enabled,
      buy_enabled = v_s.buy_enabled, sell_enabled = v_s.sell_enabled, daily_sell_limit = v_s.daily_sell_limit,
      updated_at = pg_catalog.now()
    where singleton;
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'blockchain', private.blockchain_settings(), 'market', private.market_settings_json());
end;
$$;
revoke all on function public.node_push_settings(text, jsonb, jsonb) from public;
grant execute on function public.node_push_settings(text, jsonb, jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
