import assert from "node:assert/strict";
import test from "node:test";
import { Blockchain } from "./chain.mjs";
import { startFallbackMiner } from "./fallback-miner.mjs";

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fastChain() {
  const c = new Blockchain(null);
  c.settings.minBits = 8;      // Test braucht niedrige Schwierigkeit, um schnell zu laufen
  c.settings.maxBits = 20;
  c.settings.difficultyBits = 10;
  c.settings.autoAdjust = false;
  c.settings.fallbackMinerEnabled = true;
  c.settings.fallbackDelaySeconds = 1;
  c.settings.website = { ...c.settings.website, requireRealTx: false, cooldownSeconds: 0 };
  c.accounts.srv_fallback = { name: "Server", balance: 0, cash: 100, lockedGibb: 0, lockedCash: 0, createdAt: Date.now(), source: "server" };
  return c;
}

test("Reserve-Miner bleibt untätig, wenn kein Mempool wartet", async () => {
  const c = fastChain();
  const fm = startFallbackMiner(c, { getAddress: () => "srv_fallback", batch: 20000, throttleMs: 0 });
  await wait(3500);
  fm.stop();
  assert.equal(c.tip().height, 0);
  assert.equal(fm.status().minedByFallback, 0);
});

test("Reserve-Miner versiegelt wartende Transaktionen und erzeugt gültige Blöcke", async () => {
  const c = fastChain();
  const anna = c.createWallet("Anna").address;
  // Anna bekommt GIBB echt über einen Mining-Block (Coinbase an Anna).
  const tpl = c.issueTemplate(anna);
  const { createHash } = await import("node:crypto");
  const { leadingZeroBits } = await import("../app/lib/blockchain-core.js");
  let nonce = 0; let hash = "";
  for (; nonce < 10_000_000; nonce += 1) { hash = createHash("sha256").update(tpl.header_prefix + nonce, "utf8").digest("hex"); if (leadingZeroBits(hash) >= tpl.difficulty_bits) break; }
  c.submit(tpl.id, nonce, hash, {});
  assert.ok(c.accounts[anna].balance > 0);

  const ben = c.createWallet("Ben").address;
  c.addTransaction(anna, ben, 3, "reserve-test");
  const fm = startFallbackMiner(c, { getAddress: () => "srv_fallback", batch: 20000, throttleMs: 0 });
  const startHeight = c.tip().height;
  await wait(6000);
  fm.stop();
  assert.ok(c.tip().height > startHeight, "Reserve-Miner sollte einen Block erzeugt haben");
  assert.ok(fm.status().minedByFallback >= 1);
  assert.equal(c.mempool.length, 0);
  assert.equal(c.accounts[ben].balance, 3);
  assert.deepEqual(c.verify().valid, true);
});
