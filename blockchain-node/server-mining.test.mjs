import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Blockchain } from "./chain.mjs";
import { startServerMining } from "./server-mining.mjs";

test("server mining keeps mining for enabled website accounts in turn and survives a restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "gibb-sm-"));
  const chain = new Blockchain(join(dir, "chain.json"));
  chain.updateSettings({ difficultyBits: 4, minBits: 1, maxBits: 6, website: { requireRealTx: false, cooldownSeconds: 0 } });
  const a = chain.upsertWebsiteAccount("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "Lea", 0).address;
  const b = chain.upsertWebsiteAccount("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "Tim", 0).address;
  const file = join(dir, "server-miners.json");
  const found = [];
  const miner = startServerMining(chain, { file, onBlock: (block) => found.push(block.miner), throttleMs: 1 });
  assert.throws(() => miner.enable("sb_unknown", "x"), /unknown_miner/);
  miner.enable(a, "Lea");
  miner.enable(b, "Tim");
  for (let i = 0; i < 100 && found.length < 4; i += 1) await new Promise((r) => setTimeout(r, 50));
  miner.stop();
  assert.ok(found.length >= 4, `nur ${found.length} Blöcke, Fehler: ${miner.status(a).lastError}`);
  assert.ok(found.includes(a) && found.includes(b), "beide Konten bekommen Blöcke");
  assert.ok(chain.accounts[a].balance > 0 && chain.accounts[b].balance > 0);
  assert.equal(miner.status(a).enabled, true);

  const restarted = startServerMining(chain, { file, throttleMs: 1 });
  assert.equal(restarted.status(a).enabled, true, "Einstellung übersteht Neustart");
  restarted.disable(a);
  assert.equal(restarted.status(a).enabled, false);
  assert.equal(restarted.status(b).activeMiners, 1);
  restarted.stop();
});
