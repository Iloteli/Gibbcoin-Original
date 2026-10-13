-- GIBB Blockchain: Blöcke über der bestehenden Transaktions-Hash-Kette.
--
-- Jeder Block versiegelt eine Menge unbestätigter Transaktionen (Merkle-Root),
-- verweist auf den Hash des Vorgängerblocks und trägt einen Proof-of-Work
-- (SHA-256, führende Nullbits). Blöcke werden von Schülern im Browser gefunden
-- (CPU-Mining); der Server prüft Header, Merkle-Root und Schwierigkeit und
-- schreibt die Belohnung serverautoritativ über private.append_transaction.
--
-- Die bestehende lineare Hash-Kette der Transaktionen bleibt unverändert.

-- ---------------------------------------------------------------------------
-- Ledger: neuer Transaktionstyp und Blockzuordnung
-- ---------------------------------------------------------------------------
-- Kompatibilität: In der Supabase-Cloud wurde die Ledger-Tabelle ohne chain_index angelegt
-- (Reihenfolge der Hash-Kette dort: created_at, id). Die Blöcke brauchen eine laufende Nummer.
-- Fehlt die Spalte, wird sie angelegt und in Ketten-Reihenfolge aufgefüllt; neue Buchungen
-- bekommen die nächste Nummer automatisch. Bei frischen Datenbanken existiert sie bereits.
do $compat$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'transactions' and column_name = 'chain_index'
  ) then
    alter table public.transactions add column chain_index bigint;
    with ordered as (
      select t.id, pg_catalog.row_number() over (order by t.created_at, t.id) as rn
      from public.transactions t
    )
    update public.transactions t set chain_index = ordered.rn from ordered where ordered.id = t.id;
    create sequence if not exists public.transactions_chain_index_seq owned by public.transactions.chain_index;
    perform pg_catalog.setval('public.transactions_chain_index_seq',
      coalesce((select max(chain_index) from public.transactions), 0) + 1, false);
    alter table public.transactions
      alter column chain_index set default pg_catalog.nextval('public.transactions_chain_index_seq'::regclass),
      alter column chain_index set not null;
    create unique index if not exists transactions_chain_index_key on public.transactions(chain_index);
  end if;
end;
$compat$;

alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions
  add constraint transactions_type_check check (
    type in (
      'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
      'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN',
      'COIN_PURCHASE', 'GAME_ENTRY', 'GAME_REWARD', 'MINING_REWARD'
    )
  );

alter table public.transactions add column if not exists block_height bigint;
create index if not exists transactions_block_height_idx on public.transactions(block_height);
create index if not exists transactions_pending_block_idx on public.transactions(chain_index) where block_height is null;

alter table public.admin_audit_logs drop constraint if exists admin_audit_logs_action_check;
alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED',
      'STATS_RESET', 'ADMIN_OPERATION_CHANGED', 'BLOCKCHAIN_SETTING_CHANGED'
    )
  );

-- ---------------------------------------------------------------------------
-- Blöcke
-- ---------------------------------------------------------------------------
create table if not exists public.blocks (
  height bigint primary key check (height >= 0),
  previous_hash text not null check (previous_hash ~ '^[0-9a-f]{64}$'),
  merkle_root text not null check (merkle_root ~ '^[0-9a-f]{64}$'),
  first_chain_index bigint,
  last_chain_index bigint,
  tx_count integer not null check (tx_count >= 0),
  mined_at timestamptz not null,
  difficulty_bits integer not null check (difficulty_bits between 0 and 64),
  nonce bigint not null check (nonce >= 0),
  hash text not null unique check (hash ~ '^[0-9a-f]{64}$'),
  miner_user_id uuid references private.ledger_identities(id) on delete restrict,
  miner_label text not null default 'Genesis' check (char_length(miner_label) between 1 and 100),
  reward bigint not null default 0 check (reward >= 0),
  reward_transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint blocks_chain_range check (
    (tx_count = 0 and first_chain_index is null and last_chain_index is null)
    or (tx_count > 0 and first_chain_index is not null and last_chain_index >= first_chain_index)
  )
);

create index if not exists blocks_miner_idx on public.blocks(miner_user_id, mined_at desc);

alter table public.blocks enable row level security;
alter table public.blocks force row level security;
revoke all on table public.blocks from public, anon, authenticated;
grant select on table public.blocks to authenticated;

drop policy if exists "read blocks" on public.blocks;
create policy "read blocks" on public.blocks for select to authenticated using (true);

-- Blockchain-Einstellungen (Admin) liegen in der bestehenden Kontrolltabelle.
insert into private.admin_control_settings (key, value) values
  ('blockchain', pg_catalog.jsonb_build_object(
    'enabled', true,
    'reward', 2,
    'target_seconds', 120,
    'min_bits', 16,
    'max_bits', 36,
    'cooldown_seconds', 90,
    'max_tx_per_block', 500
  ))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Reine Hilfsfunktionen (identisch im Browser nachgerechnet, siehe app/lib/blockchain-core.js)
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
    'max_tx_per_block', greatest(1, least(2000, coalesce((s.value ->> 'max_tx_per_block')::integer, 500)))
  )
  from (select coalesce((select value from private.admin_control_settings where key = 'blockchain'), '{}'::jsonb) as value) s;
$$;
revoke all on function private.blockchain_settings() from public, anon, authenticated;

create or replace function private.merkle_root(p_hashes text[])
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_level text[] := p_hashes;
  v_next text[];
  v_count integer;
  v_i integer;
begin
  if v_level is null or coalesce(pg_catalog.array_length(v_level, 1), 0) = 0 then
    return pg_catalog.repeat('0', 64);
  end if;
  loop
    v_count := pg_catalog.array_length(v_level, 1);
    if v_count = 1 then return v_level[1]; end if;
    if v_count % 2 = 1 then
      v_level := v_level || v_level[v_count];
      v_count := v_count + 1;
    end if;
    v_next := '{}'::text[];
    v_i := 1;
    while v_i < v_count loop
      v_next := v_next || pg_catalog.encode(extensions.digest(v_level[v_i] || v_level[v_i + 1], 'sha256'), 'hex');
      v_i := v_i + 2;
    end loop;
    v_level := v_next;
  end loop;
end;
$$;
revoke all on function private.merkle_root(text[]) from public, anon, authenticated;

create or replace function private.block_header(
  p_height bigint, p_previous_hash text, p_merkle_root text, p_timestamp bigint,
  p_difficulty_bits integer, p_miner_user_id uuid, p_nonce bigint
)
returns text
language sql
immutable
set search_path = ''
as $$
  select p_height::text || '|' || p_previous_hash || '|' || p_merkle_root || '|' || p_timestamp::text || '|'
    || p_difficulty_bits::text || '|' || coalesce(p_miner_user_id::text, '') || '|' || p_nonce::text;
$$;
revoke all on function private.block_header(bigint, text, text, bigint, integer, uuid, bigint) from public, anon, authenticated;

create or replace function private.block_hash(
  p_height bigint, p_previous_hash text, p_merkle_root text, p_timestamp bigint,
  p_difficulty_bits integer, p_miner_user_id uuid, p_nonce bigint
)
returns text
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.encode(extensions.digest(
    private.block_header(p_height, p_previous_hash, p_merkle_root, p_timestamp, p_difficulty_bits, p_miner_user_id, p_nonce),
    'sha256'), 'hex');
$$;
revoke all on function private.block_hash(bigint, text, text, bigint, integer, uuid, bigint) from public, anon, authenticated;

-- Anzahl führender Nullbits eines Hex-Hashes (Proof-of-Work-Mass).
create or replace function private.leading_zero_bits(p_hex text)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_bits integer := 0;
  v_i integer := 1;
  v_nibble integer;
begin
  while v_i <= pg_catalog.length(p_hex) loop
    v_nibble := pg_catalog.strpos('0123456789abcdef', pg_catalog.substr(p_hex, v_i, 1)) - 1;
    if v_nibble < 0 then raise exception 'invalid_hex'; end if;
    if v_nibble = 0 then
      v_bits := v_bits + 4;
    else
      v_bits := v_bits + case when v_nibble < 2 then 3 when v_nibble < 4 then 2 when v_nibble < 8 then 1 else 0 end;
      return v_bits;
    end if;
    v_i := v_i + 1;
  end loop;
  return v_bits;
end;
$$;
revoke all on function private.leading_zero_bits(text) from public, anon, authenticated;

-- Unbestätigte Transaktionen bis zu einem Kettenindex, in Kettenreihenfolge.
create or replace function private.pending_transaction_hashes(p_last_chain_index bigint)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.array_agg(t.hash order by t.chain_index), '{}'::text[])
  from public.transactions t
  where t.block_height is null and t.chain_index <= p_last_chain_index;
$$;
revoke all on function private.pending_transaction_hashes(bigint) from public, anon, authenticated;

-- Schwierigkeit für den nächsten Block, abgeleitet aus der Blockzeit der letzten Blöcke.
create or replace function private.blockchain_difficulty()
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_settings jsonb := private.blockchain_settings();
  v_min integer := (v_settings ->> 'min_bits')::integer;
  v_max integer := (v_settings ->> 'max_bits')::integer;
  v_target integer := (v_settings ->> 'target_seconds')::integer;
  v_tip public.blocks%rowtype;
  v_window_start timestamptz;
  v_window_count integer;
  v_average double precision;
  v_bits integer;
  v_stalled_periods integer;
begin
  select * into v_tip from public.blocks order by height desc limit 1;
  if not found or v_tip.height = 0 then return v_min; end if;

  v_bits := v_tip.difficulty_bits;

  -- Durchschnittliche Blockzeit der letzten bis zu 10 Blöcke (ohne Genesis).
  select min(w.mined_at), count(*) into v_window_start, v_window_count
  from (select mined_at from public.blocks where height > 0 order by height desc limit 10) w;
  if v_window_count >= 2 then
    v_average := pg_catalog.date_part('epoch', (v_tip.mined_at - v_window_start)) / (v_window_count - 1);
    if v_average < v_target / 2.0 then v_bits := v_bits + 1;
    elsif v_average > v_target * 2.0 then v_bits := v_bits - 1;
    end if;
  end if;

  -- Notbremse: steht die Kette lange still, sinkt die Schwierigkeit schrittweise.
  v_stalled_periods := floor(pg_catalog.date_part('epoch', (pg_catalog.now() - v_tip.mined_at)) / (v_target * 4.0))::integer;
  if v_stalled_periods > 0 then v_bits := v_bits - v_stalled_periods; end if;

  return greatest(v_min, least(v_max, v_bits));
end;
$$;
revoke all on function private.blockchain_difficulty() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Öffentliche RPCs (nur angemeldete Benutzer)
-- ---------------------------------------------------------------------------
create or replace function public.get_blockchain_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_settings jsonb := private.blockchain_settings();
  v_tip public.blocks%rowtype;
  v_pending_count bigint;
  v_pending_first bigint;
  v_pending_last bigint;
  v_block_count bigint;
  v_minted bigint;
  v_average double precision;
  v_my_blocks bigint;
  v_my_last timestamptz;
  v_next_allowed timestamptz;
  v_top jsonb;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;

  select * into v_tip from public.blocks order by height desc limit 1;
  select count(*), min(chain_index), max(chain_index) into v_pending_count, v_pending_first, v_pending_last
  from public.transactions where block_height is null;
  select count(*), coalesce(sum(reward), 0) into v_block_count, v_minted from public.blocks;

  select case when count(*) >= 2 then pg_catalog.date_part('epoch', (max(mined_at) - min(mined_at))) / (count(*) - 1) end
  into v_average
  from (select mined_at from public.blocks where height > 0 order by height desc limit 10) w;

  select count(*), max(mined_at) into v_my_blocks, v_my_last from public.blocks where miner_user_id = v_user_id;
  v_next_allowed := case when v_my_last is null then null
    else v_my_last + make_interval(secs => (v_settings ->> 'cooldown_seconds')::integer) end;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'user_id', m.miner_user_id, 'label', m.miner_label, 'blocks', m.blocks, 'reward', m.reward
  ) order by m.blocks desc, m.reward desc), '[]'::jsonb)
  into v_top
  from (
    select miner_user_id, max(miner_label) as miner_label, count(*) as blocks, sum(reward) as reward
    from public.blocks where miner_user_id is not null
    group by miner_user_id order by count(*) desc, sum(reward) desc limit 5
  ) m;

  return pg_catalog.jsonb_build_object(
    'enabled', (v_settings ->> 'enabled')::boolean,
    'reward', (v_settings ->> 'reward')::bigint,
    'target_seconds', (v_settings ->> 'target_seconds')::integer,
    'cooldown_seconds', (v_settings ->> 'cooldown_seconds')::integer,
    'max_tx_per_block', (v_settings ->> 'max_tx_per_block')::integer,
    'min_bits', (v_settings ->> 'min_bits')::integer,
    'max_bits', (v_settings ->> 'max_bits')::integer,
    'height', v_tip.height,
    'tip_hash', v_tip.hash,
    'tip_mined_at', v_tip.mined_at,
    'difficulty_bits', private.blockchain_difficulty(),
    'block_count', v_block_count,
    'minted_reward', v_minted,
    'pending_count', v_pending_count,
    'pending_first_chain_index', v_pending_first,
    'pending_last_chain_index', v_pending_last,
    'average_block_seconds', v_average,
    'my_blocks', v_my_blocks,
    'my_next_mining_at', case when v_next_allowed > pg_catalog.now() then v_next_allowed end,
    'top_miners', v_top,
    'server_time', pg_catalog.now()
  );
end;
$$;

-- Liefert alles, was ein Miner für die Nonce-Suche braucht. Der Header wird im
-- Browser exakt so zusammengesetzt wie in private.block_header.
create or replace function public.get_block_template()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_settings jsonb := private.blockchain_settings();
  v_tip public.blocks%rowtype;
  v_hashes text[];
  v_first bigint;
  v_last bigint;
  v_count integer;
  v_height bigint;
  v_previous text;
  v_bits integer;
  v_timestamp bigint := floor(pg_catalog.date_part('epoch', pg_catalog.now()))::bigint;
  v_my_last timestamptz;
begin
  if not (v_settings ->> 'enabled')::boolean then raise exception 'mining_disabled'; end if;

  select max(mined_at) into v_my_last from public.blocks where miner_user_id = v_user_id;
  if v_my_last is not null and v_my_last + make_interval(secs => (v_settings ->> 'cooldown_seconds')::integer) > pg_catalog.now() then
    raise exception 'mining_cooldown';
  end if;

  select * into v_tip from public.blocks order by height desc limit 1;
  v_height := coalesce(v_tip.height + 1, 0);
  v_previous := coalesce(v_tip.hash, pg_catalog.repeat('0', 64));

  select min(p.chain_index), max(p.chain_index), count(*) into v_first, v_last, v_count
  from (
    select chain_index from public.transactions where block_height is null
    order by chain_index limit (v_settings ->> 'max_tx_per_block')::integer
  ) p;
  if coalesce(v_count, 0) = 0 then raise exception 'no_pending_transactions'; end if;

  v_hashes := private.pending_transaction_hashes(v_last);
  v_bits := private.blockchain_difficulty();

  return pg_catalog.jsonb_build_object(
    'height', v_height,
    'previous_hash', v_previous,
    'merkle_root', private.merkle_root(v_hashes),
    'first_chain_index', v_first,
    'last_chain_index', v_last,
    'tx_count', v_count,
    'tx_hashes', pg_catalog.to_jsonb(v_hashes),
    'timestamp', v_timestamp,
    'difficulty_bits', v_bits,
    'miner_user_id', v_user_id,
    'reward', (v_settings ->> 'reward')::bigint,
    'header_prefix', private.block_header(v_height, v_previous, private.merkle_root(v_hashes), v_timestamp, v_bits, v_user_id, 0)
  );
end;
$$;

create or replace function public.submit_mined_block(
  p_height bigint,
  p_previous_hash text,
  p_last_chain_index bigint,
  p_timestamp bigint,
  p_difficulty_bits integer,
  p_nonce bigint,
  p_hash text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_settings jsonb := private.blockchain_settings();
  v_tip public.blocks%rowtype;
  v_hashes text[];
  v_first bigint;
  v_count integer;
  v_merkle text;
  v_hash text;
  v_required_bits integer;
  v_reward bigint := (v_settings ->> 'reward')::bigint;
  v_label text;
  v_wallet_id uuid;
  v_reward_tx uuid;
  v_block public.blocks%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_my_last timestamptz;
begin
  if not (v_settings ->> 'enabled')::boolean then raise exception 'mining_disabled'; end if;
  if p_nonce is null or p_nonce < 0 then raise exception 'invalid_nonce'; end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid_hash'; end if;
  if p_difficulty_bits is null or p_difficulty_bits not between 0 and 64 then raise exception 'invalid_difficulty'; end if;

  -- Dieselbe Sperre wie der Ledger: Während der Versiegelung wird nichts angehängt.
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_blockchain'));

  select max(mined_at) into v_my_last from public.blocks where miner_user_id = v_user_id;
  if v_my_last is not null and v_my_last + make_interval(secs => (v_settings ->> 'cooldown_seconds')::integer) > v_now then
    raise exception 'mining_cooldown';
  end if;

  select * into v_tip from public.blocks order by height desc limit 1;
  if p_height <> coalesce(v_tip.height + 1, 0) or p_previous_hash <> coalesce(v_tip.hash, pg_catalog.repeat('0', 64)) then
    raise exception 'stale_block';
  end if;

  -- Zeitstempel: nicht vor dem Vorgänger, nicht älter als 10 Minuten, höchstens 2 Minuten in der Zukunft.
  if p_timestamp is null
     or (v_tip.mined_at is not null and p_timestamp < floor(pg_catalog.date_part('epoch', v_tip.mined_at))::bigint)
     or p_timestamp < floor(pg_catalog.date_part('epoch', v_now))::bigint - 600
     or p_timestamp > floor(pg_catalog.date_part('epoch', v_now))::bigint + 120 then
    raise exception 'invalid_timestamp';
  end if;

  -- Transaktionsmenge: alle unbestätigten bis zum gemeldeten Index (Obergrenze beachten).
  if p_last_chain_index is null or not exists (
    select 1 from public.transactions where block_height is null and chain_index = p_last_chain_index
  ) then
    raise exception 'invalid_transaction_range';
  end if;
  v_hashes := private.pending_transaction_hashes(p_last_chain_index);
  v_count := coalesce(pg_catalog.array_length(v_hashes, 1), 0);
  if v_count = 0 or v_count > (v_settings ->> 'max_tx_per_block')::integer then
    raise exception 'invalid_transaction_range';
  end if;
  select min(chain_index) into v_first from public.transactions where block_height is null and chain_index <= p_last_chain_index;
  v_merkle := private.merkle_root(v_hashes);

  -- Proof of Work: Der Client darf eine höhere, nie eine niedrigere Schwierigkeit verwenden.
  v_required_bits := private.blockchain_difficulty();
  if p_difficulty_bits < v_required_bits then raise exception 'difficulty_too_low'; end if;
  v_hash := private.block_hash(p_height, p_previous_hash, v_merkle, p_timestamp, p_difficulty_bits, v_user_id, p_nonce);
  if v_hash <> p_hash then raise exception 'hash_mismatch'; end if;
  if private.leading_zero_bits(v_hash) < p_difficulty_bits then raise exception 'insufficient_work'; end if;

  select coalesce(nullif(pg_catalog.btrim(p.username), ''), p.display_name, 'Miner') into v_label
  from public.profiles p where p.id = v_user_id;
  v_label := pg_catalog.left(coalesce(v_label, 'Miner'), 100);

  insert into public.blocks (
    height, previous_hash, merkle_root, first_chain_index, last_chain_index, tx_count,
    mined_at, difficulty_bits, nonce, hash, miner_user_id, miner_label, reward
  ) values (
    p_height, p_previous_hash, v_merkle, v_first, p_last_chain_index, v_count,
    pg_catalog.to_timestamp(p_timestamp), p_difficulty_bits, p_nonce, v_hash, v_user_id, v_label, v_reward
  ) returning * into v_block;

  update public.transactions set block_height = p_height
  where block_height is null and chain_index <= p_last_chain_index;

  -- Belohnung: serverautoritativ, als reguläre Ledger-Transaktion (landet im nächsten Block).
  if v_reward > 0 then
    select id into v_wallet_id from public.wallets where user_id = v_user_id for update;
    if v_wallet_id is null then raise exception 'wallet_not_found'; end if;
    update public.wallets set balance = balance + v_reward, updated_at = v_now where id = v_wallet_id;
    v_reward_tx := private.append_transaction(null, v_user_id, v_reward, 'MINING_REWARD',
      'Blockchain · Block #' || p_height || ' gefunden · ' || p_difficulty_bits || ' Bit');
    update public.blocks set reward_transaction_id = v_reward_tx where height = p_height;
    v_block.reward_transaction_id := v_reward_tx;
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'block', pg_catalog.to_jsonb(v_block));
end;
$$;

-- Transaktionen eines Blocks: nur Hashes und Zeitpunkte, keine Beträge oder Beteiligten.
create or replace function public.get_block_transactions(p_height bigint)
returns table (chain_index bigint, hash text, previous_hash text, type text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select t.chain_index, t.hash, t.previous_hash, t.type, t.created_at
  from public.transactions t
  where auth.uid() is not null and t.block_height = p_height
  order by t.chain_index
  limit 2000;
$$;

-- Vollständige Prüfung: Vorgänger-Hashes, Merkle-Roots, Block-Hashes und Proof of Work.
create or replace function public.verify_blockchain()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_block record;
  v_expected_previous text := pg_catalog.repeat('0', 64);
  v_expected_height bigint := 0;
  v_hashes text[];
  v_checked integer := 0;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  for v_block in select * from public.blocks order by height loop
    v_reason := null;
    if v_block.height <> v_expected_height then v_reason := 'height_gap';
    elsif v_block.previous_hash <> v_expected_previous then v_reason := 'previous_hash_mismatch';
    else
      select coalesce(pg_catalog.array_agg(t.hash order by t.chain_index), '{}'::text[]) into v_hashes
      from public.transactions t where t.block_height = v_block.height;
      if coalesce(pg_catalog.array_length(v_hashes, 1), 0) <> v_block.tx_count then v_reason := 'transaction_count_mismatch';
      elsif private.merkle_root(v_hashes) <> v_block.merkle_root then v_reason := 'merkle_root_mismatch';
      elsif private.block_hash(v_block.height, v_block.previous_hash, v_block.merkle_root,
              floor(pg_catalog.date_part('epoch', v_block.mined_at))::bigint, v_block.difficulty_bits,
              v_block.miner_user_id, v_block.nonce) <> v_block.hash then v_reason := 'block_hash_mismatch';
      elsif private.leading_zero_bits(v_block.hash) < v_block.difficulty_bits then v_reason := 'insufficient_work';
      end if;
    end if;
    if v_reason is not null then
      return pg_catalog.jsonb_build_object('valid', false, 'blocks_checked', v_checked, 'invalid_height', v_block.height, 'reason', v_reason);
    end if;
    v_checked := v_checked + 1;
    v_expected_previous := v_block.hash;
    v_expected_height := v_block.height + 1;
  end loop;
  return pg_catalog.jsonb_build_object('valid', true, 'blocks_checked', v_checked, 'checked_at', pg_catalog.now());
end;
$$;

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
    'max_tx_per_block', greatest(1, least(2000, coalesce((p_value ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer)))
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

revoke all on function public.get_blockchain_overview() from public, anon;
revoke all on function public.get_block_template() from public, anon;
revoke all on function public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text) from public, anon;
revoke all on function public.get_block_transactions(bigint) from public, anon;
revoke all on function public.verify_blockchain() from public, anon;
revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.get_blockchain_overview() to authenticated;
grant execute on function public.get_block_template() to authenticated;
grant execute on function public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text) to authenticated;
grant execute on function public.get_block_transactions(bigint) to authenticated;
grant execute on function public.verify_blockchain() to authenticated;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Genesis-Block: versiegelt alle bereits vorhandenen Transaktionen ohne Proof of Work.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hashes text[];
  v_first bigint;
  v_last bigint;
  v_count integer;
  v_merkle text;
  v_timestamp bigint := floor(extract(epoch from now()))::bigint;
  v_zero text := repeat('0', 64);
begin
  if exists (select 1 from public.blocks) then return; end if;
  perform pg_advisory_xact_lock(hashtext('gibb_coin_transfer_chain'));
  select coalesce(array_agg(t.hash order by t.chain_index), '{}'::text[]), min(t.chain_index), max(t.chain_index), count(*)
  into v_hashes, v_first, v_last, v_count
  from public.transactions t where t.block_height is null;
  v_merkle := private.merkle_root(v_hashes);
  insert into public.blocks (
    height, previous_hash, merkle_root, first_chain_index, last_chain_index, tx_count,
    mined_at, difficulty_bits, nonce, hash, miner_user_id, miner_label, reward
  ) values (
    0, v_zero, v_merkle, v_first, v_last, coalesce(v_count, 0),
    to_timestamp(v_timestamp), 0, 0, private.block_hash(0, v_zero, v_merkle, v_timestamp, 0, null, 0), null, 'Genesis', 0
  );
  update public.transactions set block_height = 0 where block_height is null;
end;
$$;
