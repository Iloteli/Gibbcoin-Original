import assert from "node:assert/strict";
import test from "node:test";
import { Blockchain } from "./chain.mjs";

function chainWithMiner() {
  const c = new Blockchain(null);
  c.updateSettings({ reward: 8, minBits: 1, maxBits: 4, difficultyBits: 1, autoAdjust: false, website: { cooldownSeconds: 0, requireRealTx: false } });
  const miner = c.createWallet("Robyn").address;
  return { c, miner };
}
const mine = (c, address) => {
  const t = c.issueTemplate(address);
  for (let nonce = 0; ; nonce += 1) {
    const prefix = t.header_prefix + nonce;
    try { return c.submit(t.id, nonce, sha(prefix)); } catch (e) { if (e.message !== "insufficient_work") throw e; }
  }
};
import { createHash } from "node:crypto";
const sha = (s) => createHash("sha256").update(s).digest("hex");

test("mining switched off on the chain page stops every miner", () => {
  const { c, miner } = chainWithMiner();
  c.updateSettings({ website: { miningEnabled: false } });
  assert.throws(() => c.issueTemplate(miner), /mining_disabled/);
});

test("no blocks from rewards alone when real transactions are required", () => {
  const { c, miner } = chainWithMiner();
  c.updateSettings({ website: { requireRealTx: true } });
  assert.throws(() => c.issueTemplate(miner), /no_pending_transactions/);
});

test("cooldown, daily limit and halving apply to chain mining", () => {
  const { c, miner } = chainWithMiner();
  c.updateSettings({ website: { halvingBlocks: 2, maxBlocksPerDay: 3 } });
  assert.equal(mine(c, miner).reward, 8);   // Block 1
  assert.equal(mine(c, miner).reward, 4);   // Block 2 -> halbiert
  assert.equal(mine(c, miner).reward, 4);   // Block 3
  assert.throws(() => c.issueTemplate(miner), /mining_daily_limit/);
  c.updateSettings({ website: { maxBlocksPerDay: 0, cooldownSeconds: 600 } });
  assert.throws(() => c.issueTemplate(miner), /mining_cooldown/);
  assert.equal(c.verify().valid, true);
});
