// Schreibt Mining-Belohnungen von Website-Konten (Adresse sb_<uuid>) auf das Website-Wallet gut.
// Läuft nur, wenn SUPABASE_URL und SUPABASE_SERVICE_ROLE_KEY gesetzt sind (eigene Instanz auf dem Server).
// Die Datenbankfunktion ist idempotent pro Block-Hash; fehlgeschlagene Gutschriften werden erneut versucht.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function createWalletCredit({ note = () => {}, fetchImpl = globalThis.fetch, env = process.env } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const key = env.SUPABASE_SERVICE_ROLE_KEY ?? "";
  // Cloud: öffentlicher Schlüssel + Schlüssel der Chain-Seite (sudo gibb-chain-key)
  const anonKey = env.SUPABASE_ANON_KEY ?? "";
  const nodeKey = env.NODE_SETTINGS_KEY ?? "";
  const keyMode = !key && Boolean(anonKey && nodeKey);
  const enabled = Boolean(url && (key || keyMode));
  const pending = new Map(); // hash -> { userId, amount, height, tries }

  async function send(hash, item) {
    const res = keyMode
      ? await fetchImpl(`${url}/rest/v1/rpc/node_mining_reward`, {
        method: "POST",
        headers: { apikey: anonKey, authorization: `Bearer ${anonKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: nodeKey, p_user: item.userId, p_amount: item.amount, p_block_hash: hash, p_height: item.height }),
      })
      : await fetchImpl(`${url}/rest/v1/rpc/node_credit_mining_reward`, {
        method: "POST",
        headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify({ p_user_id: item.userId, p_amount: item.amount, p_block_hash: hash, p_height: item.height }),
      });
    if (!res.ok) throw new Error(`http_${res.status} ${(await res.text()).slice(0, 200)}`);
    if (keyMode) {
      const result = await res.json();
      if (!result?.ok) throw new Error(result?.error ?? "failed");
    }
  }

  async function flush() {
    for (const [hash, item] of pending) {
      try {
        await send(hash, item);
        pending.delete(hash);
        note("wallet", `Belohnung ${item.amount} GIBB für Block #${item.height} aufs Website-Wallet gebucht`);
      } catch (error) {
        item.tries += 1;
        if (item.tries === 1 || item.tries % 20 === 0) note("error", `Wallet-Gutschrift Block #${item.height}: ${error.message}`);
      }
    }
  }

  if (enabled) setInterval(() => { void flush(); }, 30_000).unref();

  return {
    enabled,
    pendingCount: () => pending.size,
    onBlock(block) {
      const address = String(block?.miner ?? "");
      if (!enabled || !address.startsWith("sb_")) return;
      const userId = address.slice(3);
      const amount = Math.round(Number(block.reward));
      if (!UUID.test(userId) || !(amount > 0)) return;
      pending.set(block.hash, { userId, amount, height: block.height, tries: 0 });
      void flush();
    },
  };
}
