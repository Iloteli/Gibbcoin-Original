import { test } from "node:test";
import assert from "node:assert/strict";
import { createWalletCredit } from "./wallet-credit.mjs";
import { createWebsiteOwnerCheck } from "./website-owner.mjs";

const env = { SUPABASE_URL: "http://sb.local", SUPABASE_SERVICE_ROLE_KEY: "service-key" };
const userId = "22222222-2222-4222-8222-222222222222";

test("credits mining rewards of website accounts to the wallet once per block", async () => {
  const calls = [];
  const credit = createWalletCredit({ env, fetchImpl: async (url, init) => { calls.push({ url, body: JSON.parse(init.body), auth: init.headers.authorization }); return { ok: true, text: async () => "" }; } });
  credit.onBlock({ miner: `sb_${userId}`, reward: 10, hash: "h1", height: 4 });
  credit.onBlock({ miner: "srv_fallback", reward: 10, hash: "h2", height: 5 });
  credit.onBlock({ miner: "Gabc123", reward: 10, hash: "h3", height: 6 });
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://sb.local/rest/v1/rpc/node_credit_mining_reward");
  assert.deepEqual(calls[0].body, { p_user_id: userId, p_amount: 10, p_block_hash: "h1", p_height: 4 });
  assert.equal(calls[0].auth, "Bearer service-key");
  assert.equal(credit.pendingCount(), 0);
});

test("keeps failed credits pending and is disabled without configuration", async () => {
  const credit = createWalletCredit({ env, fetchImpl: async () => ({ ok: false, status: 500, text: async () => "down" }) });
  credit.onBlock({ miner: `sb_${userId}`, reward: 10, hash: "h9", height: 9 });
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(credit.pendingCount(), 1);
  assert.equal(createWalletCredit({ env: {} }).enabled, false);
});

test("accepts only website owners verified by the own database", async () => {
  const fetchImpl = async (url, init) => {
    if (url.endsWith("/auth/v1/user")) {
      const token = init.headers.authorization.replace("Bearer ", "");
      if (token === "valid-owner-token-xxxxxxxx") return { ok: true, json: async () => ({ id: "owner-id" }) };
      if (token === "valid-user-token-xxxxxxxxx") return { ok: true, json: async () => ({ id: "user-id" }) };
      return { ok: false, json: async () => ({}) };
    }
    const role = url.includes("owner-id") ? "super_admin" : "user";
    return { ok: true, json: async () => [{ role, username: "ilja" }] };
  };
  const check = createWebsiteOwnerCheck({ env, fetchImpl });
  assert.deepEqual(await check("valid-owner-token-xxxxxxxx"), { address: "sb_owner-id", username: "ilja", role: "super_admin" });
  assert.equal(await check("valid-user-token-xxxxxxxxx"), null);
  assert.equal(await check("invalid-token-xxxxxxxxxxxx"), null);
  assert.equal(await check(undefined), null);
  assert.equal(await createWebsiteOwnerCheck({ env: {}, fetchImpl })("valid-owner-token-xxxxxxxx"), null);
});
