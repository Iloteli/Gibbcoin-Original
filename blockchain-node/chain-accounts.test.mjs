import { test } from "node:test";
import assert from "node:assert/strict";
import { Blockchain } from "./chain.mjs";

test("chain accounts: note, expiry, rename and login statistics", () => {
  const c = new Blockchain(null);
  c.registerUser("lea", "passwort123");
  c.verifyUser("lea", "passwort123");
  let lea = c.listUsers().find((u) => u.key === "lea");
  assert.equal(lea.loginCount, 1);
  assert.ok(lea.lastLogin > 0);

  c.setUserMeta("lea", { note: "Klasse\n3b", expiresAt: Date.now() - 1000 });
  lea = c.listUsers().find((u) => u.key === "lea");
  assert.equal(lea.note, "Klasse 3b");
  assert.equal(lea.expired, true);
  assert.throws(() => c.verifyUser("lea", "passwort123"), /account_expired/);
  assert.throws(() => c.setUserMeta("lea", { expiresAt: "quatsch" }), /invalid_expiry/);

  c.setUserMeta("lea", { expiresAt: null });
  assert.equal(c.verifyUser("lea", "passwort123").username, "lea");

  c.registerUser("tim", "passwort123");
  assert.throws(() => c.renameUser("lea", "tim"), /username_taken/);
  assert.throws(() => c.renameUser("lea", "A B"), /invalid_username/);
  const { address } = c.users.lea;
  c.renameUser("lea", "lea.m");
  assert.equal(c.users.lea, undefined);
  assert.equal(c.users["lea.m"].address, address);
  assert.equal(c.users["lea.m"].note, "Klasse 3b");
  assert.equal(c.verifyUser("lea.m", "passwort123").address, address);
});
