// Überträgt die Einstellungen der Chain-Seite auf die Hauptseite (Supabase).
// Nur die Chain-Seite hat Einstellungen; die Hauptseite übernimmt sie über
// public.node_push_settings(key, blockchain, market). Der Schlüssel (NODE_SETTINGS_KEY) wird mit
// "sudo gibb-chain-key" erzeugt und einmal in Supabase hinterlegt.

// Chain-Einstellungen -> Format der Hauptseite. Der Kurs wird nur mitgeschickt, wenn er gesetzt werden soll.
export function buildPushPayload(settings, { price } = {}) {
  const w = settings.website ?? {};
  const blockchain = {
    enabled: w.miningEnabled ?? true,
    reward: settings.reward,
    target_seconds: settings.targetSeconds,
    min_bits: settings.minBits,
    max_bits: settings.maxBits,
    max_tx_per_block: settings.maxTxPerBlock,
    cooldown_seconds: w.cooldownSeconds,
    halving_blocks: w.halvingBlocks,
    max_blocks_per_day: w.maxBlocksPerDay,
    require_real_tx: w.requireRealTx,
  };
  const market = {
    enabled: settings.marketEnabled,
    sell_fee: Number(settings.tradingFeePercent) / 100,
    step: Number(w.marketStepPercent) / 100,
    min_price: w.minPrice,
    max_price: w.maxPrice,
    max_trade: w.maxTrade,
    buy_enabled: w.buyEnabled,
    sell_enabled: w.sellEnabled,
    daily_sell_limit: w.dailySellLimit,
  };
  if (price !== undefined && price !== null && price !== "" && Number.isFinite(Number(price))) market.price = Number(price);
  return { blockchain, market };
}

export function createSettingsSync({ chain, note = () => {}, fetchImpl = globalThis.fetch, env = process.env, intervalMs = 10 * 60_000 } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const apiKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_ANON_KEY || "";
  const secret = env.NODE_SETTINGS_KEY ?? "";
  const enabled = Boolean(url && apiKey && secret);
  const state = { enabled, configured: Boolean(url && apiKey), lastPush: null, lastError: enabled ? null : (url && apiKey ? "no_key" : null) };

  async function push(options = {}) {
    if (!enabled) return { ok: false, error: state.lastError ?? "not_configured" };
    try {
      const payload = buildPushPayload(chain.settings, options);
      const res = await fetchImpl(`${url}/rest/v1/rpc/node_push_settings`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_blockchain: payload.blockchain, p_market: payload.market }),
      });
      if (!res.ok) throw new Error(`http_${res.status}`);
      const result = await res.json();
      if (!result?.ok) throw new Error(result?.error ?? "push_failed");
      if (state.lastError) note("settings", "Einstellungen werden wieder an die Hauptseite übertragen");
      state.lastPush = Date.now();
      state.lastError = null;
      return { ok: true };
    } catch (error) {
      if (state.lastError !== error.message) note("error", `Einstellungen konnten nicht an die Hauptseite übertragen werden: ${error.message}`);
      state.lastError = error.message;
      return { ok: false, error: error.message };
    }
  }

  if (enabled) {
    setTimeout(() => { void push(); }, 3000).unref();
    setInterval(() => { void push(); }, intervalMs).unref();
  }

  return { enabled, push, status: () => ({ ...state }) };
}
