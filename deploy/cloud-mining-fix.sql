-- Mining-Fix für die Supabase-Cloud (einmal im SQL Editor ausführen).
-- 1) Nur Ilja darf Blockchain-Einstellungen ändern.
-- 2) Mining braucht echte Coin-Bewegungen (kein endloses Selbst-Minen über Belohnungen).
-- 3) Einstellungen zurück auf Iljas Werte (16–48 Bit, 90 s Pause, 200 s Ziel, Belohnung 1).
begin;
-- Blockchain-Einstellungen darf nur noch Ilja ändern (ilja.podorieszach@icloud.com).
-- Andere Admins und Owner bekommen 'owner_required'. Admin-PIN wird weiterhin geprüft.

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
  if pg_catalog.lower(coalesce((select u.email from auth.users u where u.id = v_admin), '')) <> 'ilja.podorieszach@icloud.com' then
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

revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

notify pgrst, 'reload schema';

-- Mining-Fehler beheben: Die Belohnung eines Blocks ist selbst eine unbestätigte Transaktion
-- (MINING_REWARD). Bisher reichte genau diese für den nächsten Block – Mining hielt sich so
-- endlos selbst am Laufen und erzeugte Coins ohne echte Coin-Bewegungen.
-- Neu: Ein Block braucht mindestens eine unbestätigte Transaktion, die KEINE Mining-Belohnung ist.
-- Belohnungen werden weiterhin mit in den nächsten echten Block aufgenommen.

do $migration$
declare
  v_def text;
  v_anchor text;
begin
  -- 1) Vorlage: ohne echte Transaktion keine Vorlage
  v_def := pg_catalog.pg_get_functiondef('public.get_block_template()'::pg_catalog.regprocedure);
  if pg_catalog.strpos(v_def, 'mining_needs_real_tx') = 0 then
    v_anchor := $a$if coalesce(v_count, 0) = 0 then raise exception 'no_pending_transactions'; end if;$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then
      raise exception 'get_block_template: Stelle für die Ergänzung nicht gefunden';
    end if;
    v_def := pg_catalog.replace(v_def, v_anchor, v_anchor || $b$
  -- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if not exists (
    select 1 from public.transactions t
    where t.block_height is null and t.chain_index <= v_last and t.type <> 'MINING_REWARD'
  ) then raise exception 'no_pending_transactions'; end if;$b$);
    execute v_def;
  end if;

  -- 2) Einreichen: dieselbe Regel serverseitig erzwingen
  v_def := pg_catalog.pg_get_functiondef('public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text)'::pg_catalog.regprocedure);
  if pg_catalog.strpos(v_def, 'mining_needs_real_tx') = 0 then
    v_anchor := '  v_merkle := private.merkle_root(v_hashes);';
    if pg_catalog.strpos(v_def, v_anchor) = 0 then
      raise exception 'submit_mined_block: Stelle für die Ergänzung nicht gefunden';
    end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $c$  -- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if not exists (
    select 1 from public.transactions t
    where t.block_height is null and t.chain_index <= p_last_chain_index and t.type <> 'MINING_REWARD'
  ) then raise exception 'no_pending_transactions'; end if;
$c$ || v_anchor);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';

insert into private.admin_control_settings (key, value, updated_at)
values ('blockchain', '{"enabled": true, "reward": 1, "target_seconds": 200, "min_bits": 16, "max_bits": 48, "cooldown_seconds": 90, "max_tx_per_block": 500}'::jsonb, pg_catalog.clock_timestamp())
on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
commit;
