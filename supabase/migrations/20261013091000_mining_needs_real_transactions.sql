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
