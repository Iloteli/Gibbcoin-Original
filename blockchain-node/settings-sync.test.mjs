import test from "node:test";
import assert from "node:assert/strict";
import { createSettingsSync, mapSharedSettings } from "./settings-sync.mjs";

test("maps main-site settings onto the chain page", () => {
  const patch = mapSharedSettings({
    blockchain: { reward: 5, target_seconds: 120, min_bits: 16, max_bits: 44, max_tx_per_block: 1500 },
    market: { price: 2.5, sell_fee: 0.02, enabled: false },
  });
  assert.deepEqual(patch, { reward: 5, targetSeconds: 120, minBits: 16, maxBits: 40, maxTxPerBlock: 1000, startPrice: 2.5, tradingFeePercent: 2, marketEnabled: false });
});

test("applies fetched settings and keeps synced fields read-only", async () => {
  const applied = [];
  const chain = { settings: { reward: 10 }, updateSettings(p) { applied.push(p); Object.assign(this.settings, p); } };
  const fetchImpl = async () => ({ ok: true, json: async () => ({ blockchain: { reward: 7 }, market: {} }) });
  const sync = createSettingsSync({ chain, fetchImpl, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k" }, intervalMs: 1e9 });
  await sync.sync();
  assert.equal(chain.settings.reward, 7);
  assert.deepEqual(sync.filterPatch({ reward: 1, startingCash: 5 }), { startingCash: 5 });
  assert.equal(createSettingsSync({ chain, env: {} }).enabled, false);
});
