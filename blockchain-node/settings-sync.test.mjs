import test from "node:test";
import assert from "node:assert/strict";
import { Blockchain } from "./chain.mjs";
import { buildPushPayload, createSettingsSync } from "./settings-sync.mjs";

test("builds the main-site payload from chain page settings", () => {
  const chain = new Blockchain(null);
  chain.updateSettings({ reward: 5, tradingFeePercent: 3, website: { halvingBlocks: 100, marketStepPercent: 0.1, buyEnabled: false } });
  const { blockchain, market } = buildPushPayload(chain.settings);
  assert.equal(blockchain.reward, 5);
  assert.equal(blockchain.halving_blocks, 100);
  assert.equal(market.sell_fee, 0.03);
  assert.equal(market.step, 0.001);
  assert.equal(market.buy_enabled, false);
  assert.equal("price" in market, false);
  assert.equal(buildPushPayload(chain.settings, { price: "2.5" }).market.price, 2.5);
  assert.throws(() => chain.updateSettings({ website: { minPrice: 10, maxPrice: 1 } }), /invalid_price_range/);
});

test("pushes with the secret key and reports missing configuration", async () => {
  const chain = new Blockchain(null);
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push({ url, body: JSON.parse(init.body) }); return { ok: true, json: async () => ({ ok: true }) }; };
  const sync = createSettingsSync({ chain, fetchImpl, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k", NODE_SETTINGS_KEY: "s3cret" }, intervalMs: 1e9 });
  assert.deepEqual(await sync.push(), { ok: true });
  assert.match(calls[0].url, /node_push_settings$/);
  assert.match(calls[1].url, /node_set_admin_features$/);
  assert.equal(calls[1].body.p_features.coin_grants, false);
  assert.equal(calls[0].body.p_key, "s3cret");
  const noKey = createSettingsSync({ chain, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k" } });
  assert.equal(noKey.enabled, false);
  assert.equal(noKey.status().lastError, "no_key");
});

test("removes website accounts that were deleted on the main site", async () => {
  const chain = new Blockchain(null);
  const keep = "11111111-1111-4111-8111-111111111111", gone = "22222222-2222-4222-8222-222222222222";
  chain.upsertWebsiteAccount(keep, "Ilja", 0);
  chain.upsertWebsiteAccount(gone, "Weg", 0);
  const local = chain.createWallet("Lokal").address;
  const removed = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    assert.deepEqual(body.p_ids.sort(), [keep, gone].sort());
    return { ok: true, json: async () => ({ ok: true, existing: [keep] }) };
  };
  const sync = createSettingsSync({ chain, fetchImpl, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k", NODE_SETTINGS_KEY: "s" }, intervalMs: 1e9, onAccountRemoved: (a) => removed.push(a) });
  assert.deepEqual(await sync.cleanupAccounts(), { ok: true, removed: 1 });
  assert.ok(chain.accounts[`sb_${keep}`]);
  assert.equal(chain.accounts[`sb_${gone}`], undefined);
  assert.ok(chain.accounts[local]);
  assert.deepEqual(removed, [`sb_${gone}`]);
  assert.equal(chain.verify().valid, true);
});

test("keeps all accounts when the main site cannot be asked", async () => {
  const chain = new Blockchain(null);
  chain.upsertWebsiteAccount("33333333-3333-4333-8333-333333333333", "X", 0);
  const fetchImpl = async () => ({ ok: true, json: async () => ({ ok: false, error: "invalid_key" }) });
  const sync = createSettingsSync({ chain, fetchImpl, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k", NODE_SETTINGS_KEY: "s" }, intervalMs: 1e9 });
  assert.equal((await sync.cleanupAccounts()).removed, 0);
  assert.equal(Object.keys(chain.accounts).filter((a) => a.startsWith("sb_")).length, 1);
});

test("mirrors website accounts: names, balances, new and deleted accounts", async () => {
  const chain = new Blockchain(null);
  const a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222", c = "33333333-3333-4333-8333-333333333333";
  chain.upsertWebsiteAccount(a, "alt", 2_399_793_771);
  chain.upsertWebsiteAccount(b, "geloescht", 500);
  const local = chain.createWallet("Lokal").address;
  const fetchImpl = async (url) => {
    assert.match(url, /node_list_users$/);
    return { ok: true, json: async () => ({ ok: true, users: [{ id: a, username: "ilja", balance: 10 }, { id: c, username: "neu", balance: 7 }] }) };
  };
  const sync = createSettingsSync({ chain, fetchImpl, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k", NODE_SETTINGS_KEY: "s" }, intervalMs: 1e9, accountSyncMs: 1e9 });
  const r = await sync.syncAccounts();
  assert.equal(r.ok, true);
  assert.equal(chain.accounts[`sb_${a}`].balance, 10);
  assert.equal(chain.accounts[`sb_${a}`].name, "ilja");
  assert.equal(chain.accounts[`sb_${b}`], undefined);
  assert.equal(chain.accounts[`sb_${c}`].balance, 7);
  assert.ok(chain.accounts[local]);
  assert.equal(chain.verify().valid, true);
});

test("new empty main-site database: old accounts are kept as orphans, not deleted", async () => {
  const chain = new Blockchain(null);
  const ids = ["44444444-4444-4444-8444-444444444441", "44444444-4444-4444-8444-444444444442", "44444444-4444-4444-8444-444444444443", "44444444-4444-4444-8444-444444444444"];
  ids.forEach((id, i) => chain.upsertWebsiteAccount(id, `alt${i}`, 100 * (i + 1)));
  const fresh = "55555555-5555-4555-8555-555555555555";
  const fetchImpl = async (url) => {
    if (url.endsWith("/node_list_users")) return { ok: true, json: async () => ({ ok: true, users: [{ id: fresh, username: "neu", balance: 0 }] }) };
    return { ok: true, json: async () => ({ ok: true }) };
  };
  const removed = [];
  const sync = createSettingsSync({ chain, fetchImpl, env: { SUPABASE_URL: "https://x", SUPABASE_ANON_KEY: "k", NODE_SETTINGS_KEY: "s" }, intervalMs: 1e9, onAccountRemoved: (a) => removed.push(a) });
  const r = await sync.syncAccounts();
  assert.equal(r.removed, 0);
  assert.deepEqual(removed, []);
  for (const id of ids) assert.equal(chain.accounts[`sb_${id}`].orphan, true);
  assert.equal(chain.accounts[`sb_${ids[3]}`].balance, 400);
  assert.ok(chain.accounts[`sb_${fresh}`]);
});
