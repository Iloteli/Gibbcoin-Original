-- Chain-Seite und Hauptseite synchron halten:
-- Findet ein Website-Konto (sb_<uuid>) auf der Chain-Seite einen Block, wird die Belohnung mit dem
-- Schlüssel der Chain-Seite auf das Website-Wallet gebucht (einmal pro Block-Hash).
-- Die Guthaben der Chain-Seite werden danach regelmässig von der Hauptseite übernommen.

create table if not exists private.node_mining_credits (
  block_hash text primary key,
  user_id uuid,
  amount bigint not null,
  height bigint,
  transaction_id uuid,
  created_at timestamptz not null default now()
);
revoke all on table private.node_mining_credits from public, anon, authenticated;

create or replace function public.node_mining_reward(p_key text, p_user uuid, p_amount bigint, p_block_hash text, p_height bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_user is null or p_block_hash is null or pg_catalog.char_length(p_block_hash) < 16 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 10000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  if exists (select 1 from private.node_mining_credits c where c.block_hash = p_block_hash) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where user_id = p_user;
  if not found then
    -- Konto gibt es nicht mehr: als erledigt merken, damit es nicht ewig erneut versucht wird
    insert into private.node_mining_credits (block_hash, user_id, amount, height) values (p_block_hash, null, p_amount, p_height);
    return pg_catalog.jsonb_build_object('ok', true, 'skipped', 'wallet_not_found');
  end if;
  v_tx := private.append_transaction(null, p_user, p_amount, 'MINING_REWARD',
    'Chain-Seite · Block #' || coalesce(p_height::text, '?') || ' gefunden');
  insert into private.node_mining_credits (block_hash, user_id, amount, height, transaction_id)
  values (p_block_hash, p_user, p_amount, p_height, v_tx);
  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_mining_reward(text, uuid, bigint, text, bigint) from public;
grant execute on function public.node_mining_reward(text, uuid, bigint, text, bigint) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
