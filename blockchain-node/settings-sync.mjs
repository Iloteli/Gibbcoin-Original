// Übernimmt die Einstellungen der Hauptseite (Supabase) in die Chain-Seite.
// Quelle: public.get_shared_chain_settings() – öffentlich lesbar, enthält nur Einstellungen.
// Die Hauptseite ist führend: übernommene Felder werden auf der Chain-Seite nicht separat gespeichert.
export const SYNCED_KEYS = ["reward", "targetSeconds", "minBits", "maxBits", "maxTxPerBlock", "startPrice", "tradingFeePercent", "marketEnabled"];

export function mapSharedSettings(shared) {
  const chain = shared?.blockchain ?? {};
  const market = shared?.market ?? {};
  const patch = {};
  if (Number.isFinite(Number(chain.reward))) patch.reward = Number(chain.reward);
  if (Number.isFinite(Number(chain.target_seconds))) patch.targetSeconds = Math.min(3600, Number(chain.target_seconds));
  if (Number.isFinite(Number(chain.min_bits))) patch.minBits = Math.min(40, Number(chain.min_bits));
  if (Number.isFinite(Number(chain.max_bits))) patch.maxBits = Math.min(40, Number(chain.max_bits));
  if (Number.isFinite(Number(chain.max_tx_per_block))) patch.maxTxPerBlock = Math.min(1000, Number(chain.max_tx_per_block));
  if (Number.isFinite(Number(market.price))) patch.startPrice = Number(market.price);
  if (Number.isFinite(Number(market.sell_fee))) patch.tradingFeePercent = Math.min(20, Number(market.sell_fee) * 100);
  if (typeof market.enabled === "boolean") patch.marketEnabled = market.enabled;
  return patch;
}

export function createSettingsSync({ chain, note = () => {}, fetchImpl = globalThis.fetch, env = process.env, intervalMs = 60_000 } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const key = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_ANON_KEY || "";
  const enabled = Boolean(url && key) && env.SETTINGS_SYNC !== "0";
  const state = { enabled, lastSync: null, lastError: null };

  async function sync() {
    try {
      const res = await fetchImpl(`${url}/rest/v1/rpc/get_shared_chain_settings`, {
        method: "POST",
        headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: "{}",
      });
      if (!res.ok) throw new Error(`http_${res.status}`);
      const patch = mapSharedSettings(await res.json());
      const changed = Object.keys(patch).filter((k) => chain.settings[k] !== patch[k]);
      if (changed.length) {
        chain.updateSettings(patch);
        note("settings", `Einstellungen der Hauptseite übernommen (${changed.join(", ")})`);
      }
      state.lastSync = Date.now();
      if (state.lastError) note("settings", "Einstellungs-Abgleich mit der Hauptseite läuft wieder");
      state.lastError = null;
    } catch (error) {
      if (!state.lastError) note("error", `Einstellungen der Hauptseite nicht abrufbar: ${error.message}`);
      state.lastError = error.message;
    }
  }

  if (enabled) {
    void sync();
    setInterval(() => { void sync(); }, intervalMs).unref();
  }

  return {
    enabled,
    sync,
    status: () => ({ ...state, keys: enabled ? SYNCED_KEYS : [] }),
    // Felder, die von der Hauptseite kommen, nicht lokal überschreiben.
    filterPatch(patch) {
      if (!enabled) return patch;
      const copy = { ...patch };
      for (const k of SYNCED_KEYS) delete copy[k];
      return copy;
    },
  };
}
