import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Blockchain } from "./chain.mjs";
import { DEFAULT_BASIC_PERMISSIONS, VIEW_PERMISSIONS } from "./permissions.mjs";

test("Basic sieht standardmässig Miner, Wallets und Mempool, darf aber nicht senden/handeln", () => {
  for (const p of VIEW_PERMISSIONS) assert.ok(DEFAULT_BASIC_PERMISSIONS.includes(p), p);
  assert.ok(!DEFAULT_BASIC_PERMISSIONS.includes("a:send"));
  assert.ok(!DEFAULT_BASIC_PERMISSIONS.includes("a:trade"));
});

test("bestehende Rechte-Listen bekommen die Übersichts-Karten einmal dazu", () => {
  const file = join(mkdtempSync(join(tmpdir(), "gibb-views-")), "chain.json");
  writeFileSync(file, JSON.stringify({ settings: { basicPermissions: ["a:verify"] }, userPermissions: { Gabc: ["a:miner"] } }));
  const c = new Blockchain(file);
  assert.ok(c.settings.basicPermissions.includes("a:wallets"));
  assert.deepEqual(new Set(c.userPermissions.Gabc), new Set(["a:miner", ...VIEW_PERMISSIONS]));
  // Danach gilt, was der Owner ausschaltet (nicht erneut ergänzen)
  c.userPermissions.Gabc = ["a:miner"];
  c.save();
  const again = new Blockchain(file);
  assert.deepEqual(again.userPermissions.Gabc, ["a:miner"]);
});
