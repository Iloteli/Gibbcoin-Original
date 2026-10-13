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

export function createSettingsSync({ chain, note = () => {}, fetchImpl = globalThis.fetch, env = process.env, intervalMs = 10 * 60_000, onAccountRemoved = () => {} } = {}) {
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
      const features = await fetchImpl(`${url}/rest/v1/rpc/node_set_admin_features`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_features: { coin_grants: Boolean(chain.settings.website?.adminCoinGrants) } }),
      });
      if (!features.ok) throw new Error(`admin_features_http_${features.status}`);
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

  // Gelöschte Website-Konten auch hier entfernen.
  async function cleanupAccounts() {
    if (!enabled) return { ok: false, removed: 0 };
    const ids = Object.keys(chain.accounts)
      .filter((a) => a.startsWith("sb_") && chain.accounts[a]?.source === "supabase")
      .map((a) => a.slice(3))
      .filter((id) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id));
    if (!ids.length) return { ok: true, removed: 0 };
    try {
      const res = await fetchImpl(`${url}/rest/v1/rpc/node_existing_users`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_ids: ids }),
      });
      if (!res.ok) throw new Error(`http_${res.status}`);
      const result = await res.json();
      if (!result?.ok || !Array.isArray(result.existing)) throw new Error(result?.error ?? "invalid_response");
      const existing = new Set(result.existing.map((id) => String(id).toLowerCase()));
      let removed = 0;
      for (const id of ids) {
        if (existing.has(id.toLowerCase())) continue;
        const address = `sb_${id}`;
        const name = chain.accounts[address]?.name ?? id;
        if (chain.removeWebsiteAccount(address)) { removed += 1; onAccountRemoved(address); note("wallet", `Gelöschtes Website-Konto entfernt: ${name}`); }
      }
      return { ok: true, removed };
    } catch (error) {
      note("error", `Abgleich gelöschter Konten fehlgeschlagen: ${error.message}`);
      return { ok: false, removed: 0, error: error.message };
    }
  }

  if (enabled) {
    setTimeout(() => { void push(); void cleanupAccounts(); }, 3000).unref();
    setInterval(() => { void push(); void cleanupAccounts(); }, intervalMs).unref();
  }

  // Coins der Website-Benutzer verwalten (nur über die Chain-Seite).
  async function rpc(name, body) {
    if (!enabled) throw new Error(state.lastError === "no_key" ? "no_key" : "not_configured");
    const res = await fetchImpl(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ p_key: secret, ...body }),
    });
    if (!res.ok) throw new Error(`http_${res.status}`);
    const result = await res.json();
    if (!result?.ok) throw new Error(result?.error ?? "failed");
    return result;
  }
  const listWebsiteUsers = async () => (await rpc("node_list_users", {})).users ?? [];
  const adjustWebsiteBalance = async (userId, amount, reason) => rpc("node_adjust_balance", { p_user: userId, p_amount: amount, p_reason: reason });

  return { enabled, push, cleanupAccounts, listWebsiteUsers, adjustWebsiteBalance, status: () => ({ ...state }) };
}
