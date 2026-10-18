import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// Website-Owner melden sich mit E-Mail/Passwort der Hauptseite an: Basic automatisch, Full nach Upgrade.
const here = dirname(fileURLToPath(import.meta.url));
const PORT = 19100 + Math.floor(Math.random() * 80);
const SB_PORT = PORT + 100;
const base = `http://127.0.0.1:${PORT}`;
const ROBYN = "d465d88f-0acb-4bff-ad55-945761acaeea";
let child, sb, dir;

const post = async (path, body) => {
  const res = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return { status: res.status, data: await res.json().catch(() => ({})) };
};

before(async () => {
  // Nachgestellte Supabase-Hauptseite: robyn ist Owner, lea normale Nutzerin
  const users = { "robyn@x.ch": { id: ROBYN, password: "robyn-pass", role: "super_admin", username: "robyn" }, "lea@x.ch": { id: "11111111-1111-4111-8111-111111111111", password: "lea-pass", role: "user", username: "lea" } };
  sb = createServer(async (req, res) => {
    let raw = ""; for await (const c of req) raw += c;
    const send = (code, data) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(data)); };
    if (req.url.startsWith("/auth/v1/token")) {
      const { email, password } = JSON.parse(raw || "{}");
      const u = users[email];
      return u && u.password === password ? send(200, { access_token: `tok-${email}-xxxxxxxxxxxxxxxx` }) : send(400, { error: "invalid_grant" });
    }
    const email = String(req.headers.authorization ?? "").replace("Bearer tok-", "").replace(/-x+$/, "");
    const u = users[email];
    if (req.url.startsWith("/auth/v1/user")) return u ? send(200, { id: u.id, email }) : send(401, {});
    if (req.url.startsWith("/rest/v1/profiles")) return send(200, u ? [{ role: u.role, username: u.username, display_name: u.username }] : []);
    if (req.url.includes("node_list_users")) return send(200, { ok: true, users: Object.entries(users).map(([, x]) => ({ id: x.id, username: x.username, display_name: x.username, role: x.role, balance: 10 })) });
    return send(200, { ok: true });
  }).listen(SB_PORT);
  dir = mkdtempSync(join(tmpdir(), "gibb-lvl-"));
  child = spawn(process.execPath, [join(here, "server.mjs")], {
    env: { ...process.env, PORT: String(PORT), CHAIN_FILE: join(dir, "chain.json"), GIBB_OWNER_SETUP_CODE: "geheim-1234", NODE_REGISTRATION: "1", NO_AUTH: "", FALLBACK_MINER: "0", SUPABASE_URL: `http://127.0.0.1:${SB_PORT}`, SUPABASE_ANON_KEY: "anon", NODE_SETTINGS_KEY: "k", SUPABASE_SERVICE_ROLE_KEY: "" },
    stdio: "ignore",
  });
  for (let i = 0; i < 50; i += 1) {
    try { await fetch(`${base}/api/stats`); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
});
after(() => { child?.kill(); sb?.close(); });

const serverCode = (code) => writeFileSync(join(dir, "owner-login-code.json"), JSON.stringify({ hash: createHash("sha256").update(code).digest("hex"), expires: Date.now() + 300000 }));

test("website owners get a basic chain login; full needs an upgrade, only ilja needs the server code", async () => {
  assert.equal((await post("/api/auth/login", { username: "lea@x.ch", password: "lea-pass" })).data.error, "not_owner_account");
  assert.equal((await post("/api/auth/login", { username: "robyn@x.ch", password: "falsch" })).data.error, "invalid_login");

  const basic = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  assert.equal(basic.role, "owner_basic");
  // Basic: Mining-Einstellungen ja, Server-/Bank-Einstellungen nein, Admin nein
  const s = (await post("/api/settings", { token: basic.token, reward: 7, chainLoginsEnabled: false, website: { bankIban: "CH9300762011623852957", maxTrade: 50 } })).data;
  assert.equal(s.reward, 7);
  assert.equal(s.chainLoginsEnabled, true, "nur Full");
  assert.equal(s.website.bankIban, "");
  assert.equal(s.website.maxTrade, 50);
  assert.equal((await post("/api/admin/node-users", { token: basic.token })).data.error, "not_owner");

  // Ilja (lokales Owner-Konto) upgradet robyn auf Full
  await post("/api/auth/register", { username: "ilja", password: "passwort123", setupCode: "geheim-1234" });
  serverCode("111222");
  const ilja = (await post("/api/auth/login", { username: "ilja", password: "passwort123", code: "111222" })).data;
  assert.equal((await post("/api/admin/owner-level", { token: ilja.token, userId: ROBYN, level: "full" })).data.level, "full");
  assert.equal((await post("/api/auth/me", { token: basic.token })).data.ok, false, "alte Basic-Sitzung beendet");

  // Nur Ilja braucht den Server-Code, Full-Konten von anderen nicht
  const full = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  assert.equal(full.role, "super_admin");
  assert.ok(Array.isArray((await post("/api/admin/node-users", { token: full.token })).data.users));

  // Zurückstufen
  await post("/api/admin/owner-level", { token: ilja.token, userId: ROBYN, level: "basic" });
  assert.equal((await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data.role, "owner_basic");
});

test("full accounts decide what basic may change; local chain accounts can be basic or full", async () => {
  serverCode("555666");
  const ilja = (await post("/api/auth/login", { username: "ilja", password: "passwort123", code: "555666" })).data;
  // Basic darf standardmässig keine Coins verwalten
  const basic = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  assert.equal((await post("/api/website/users", { token: basic.token })).data.error, "not_owner");
  assert.ok(!(await post("/api/auth/me", { token: basic.token })).data.permissions.includes("coins"));
  // Full erlaubt Basic "Coins verwalten" und nimmt "Mining" weg
  await post("/api/settings", { token: ilja.token, basicPermissions: ["coins", "market", "server"] });
  // Coins verwalten gibt es für Basic nie, auch wenn es versucht wird freizugeben
  assert.equal((await post("/api/website/users", { token: basic.token })).data.error, "not_owner");
  // Basic darf keine Coins senden und keine Aufträge erstellen
  assert.equal((await post("/api/transactions", { token: basic.token, to: "ilja", amount: 1 })).data.error, "basic_no_transfers");
  assert.equal((await post("/api/order", { token: basic.token, side: "buy", price: 1, amount: 1 })).data.error, "basic_no_transfers");
  // Mehr Blockchain-Einstellungen: Server-Einstellungen mit Recht "server"
  assert.equal((await post("/api/settings", { token: basic.token, fallbackDelaySeconds: 42 })).data.fallbackDelaySeconds, 42);
  const before = (await post("/api/stats", undefined)).data;
  const s = (await post("/api/settings", { token: basic.token, reward: 99, tradingFeePercent: 4 })).data;
  assert.notEqual(s.reward, 99, "Mining nicht mehr erlaubt");
  assert.equal(s.tradingFeePercent, 4);
  assert.equal((await post("/api/settings", { token: basic.token, basicPermissions: ["mining"] })).data.basicPermissions.includes("mining"), false, "Basic darf Rechte nicht ändern");
  void before;
  // Lokales Chain-Konto als Basic
  await post("/api/admin/node-users/create", { token: ilja.token, username: "ghg", password: "passwort123" });
  await post("/api/admin/node-users/level", { token: ilja.token, username: "ghg", level: "basic" });
  assert.equal((await post("/api/auth/login", { username: "ghg", password: "passwort123" })).data.role, "owner_basic");
  await post("/api/admin/node-users/level", { token: ilja.token, username: "ghg", level: "full" });
  assert.equal((await post("/api/auth/login", { username: "ghg", password: "passwort123" })).data.role, "super_admin");
  assert.equal((await post("/api/auth/login", { username: "ilja", password: "passwort123" })).data.error, "second_factor_required");
  assert.equal((await post("/api/admin/node-users/level", { token: ilja.token, username: "ilja", level: "user" })).data.error, "account_is_protected");
  await post("/api/settings", { token: ilja.token, basicPermissions: ["mining", "rules", "market", "tabs", "payments"] });
});

test("each basic permission can be switched on its own", async () => {
  serverCode("777888");
  const ilja = (await post("/api/auth/login", { username: "ilja", password: "passwort123", code: "777888" })).data;
  await post("/api/settings", { token: ilja.token, basicPermissions: ["s:reward", "w:buyEnabled"] });
  const basic = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  const s = (await post("/api/settings", { token: basic.token, reward: 13, targetSeconds: 999, website: { buyEnabled: true, sellEnabled: true } })).data;
  assert.equal(s.reward, 13);
  assert.notEqual(s.targetSeconds, 999);
  assert.equal(s.website.buyEnabled, true);
  assert.notEqual(s.website.sellEnabled, true);
  assert.deepEqual((await post("/api/auth/me", { token: basic.token })).data.permissions.sort(), ["s:reward", "w:buyEnabled"]);
  assert.ok((await (await fetch(base + "/api/permissions")).json()).catalog.length >= 5);
});

test("basic can get admin rights one by one (accounts, games, coins); roles stay full-only", async () => {
  serverCode("121212");
  const ilja = (await post("/api/auth/login", { username: "ilja", password: "passwort123", code: "121212" })).data;
  await post("/api/settings", { token: ilja.token, basicPermissions: [] });
  let basic = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  assert.equal((await post("/api/admin/call", { token: basic.token, fn: "get_game_center_state" })).data.error, "not_owner");
  assert.equal((await post("/api/admin/status", { token: basic.token, userId: ROBYN, status: "locked" })).data.error, "not_owner");
  assert.equal((await post("/api/website/adjust", { token: basic.token, userId: ROBYN, amount: 5, reason: "Test" })).data.error, "not_owner");

  await post("/api/settings", { token: ilja.token, basicPermissions: ["a:games", "a:accounts", "a:coins"] });
  const perms = (await post("/api/auth/me", { token: basic.token })).data.permissions;
  assert.ok(perms.includes("a:games") && perms.includes("a:accounts") && perms.includes("a:coins"));
  assert.notEqual((await post("/api/admin/call", { token: basic.token, fn: "get_game_center_state" })).data.error, "not_owner");
  assert.notEqual((await post("/api/admin/call", { token: basic.token, fn: "admin_verify_pin", args: { p_pin: "1234" } })).data.error, "not_owner");
  assert.notEqual((await post("/api/website/users", { token: basic.token })).data.error, "not_owner");
  // Rollen ändern, PIN setzen, Konten löschen/erstellen und Tools bleiben gesperrt
  assert.equal((await post("/api/admin/call", { token: basic.token, fn: "admin_set_role", args: {} })).data.error, "not_owner");
  assert.equal((await post("/api/admin/call", { token: basic.token, fn: "owner_reset_admin_pin", args: {} })).data.error, "not_owner");
  assert.equal((await post("/api/admin/call", { token: basic.token, fn: "admin_run_health_check" })).data.error, "not_owner");
  assert.equal((await post("/api/admin/delete", { token: basic.token, userId: ROBYN, pin: "1234" })).data.error, "not_owner");
  assert.equal((await post("/api/admin/create-account", { token: basic.token, email: "a@b.ch", username: "abc", password: "passwort123" })).data.error, "not_owner");
  assert.equal((await post("/api/admin/node-users", { token: basic.token })).data.error, "not_owner");
  // Statistik, Ankündigung und Bonus für alle: nur mit eigenem Recht
  assert.equal((await post("/api/owner/stats", { token: basic.token, days: 30 })).data.error, "not_owner");
  assert.equal((await post("/api/announcement/set", { token: basic.token, enabled: true, message: "Hallo" })).data.error, "not_owner");
  assert.equal((await post("/api/website/bulk", { token: basic.token, amount: 5, reason: "Bonus" })).data.error, "not_owner");
  assert.notEqual((await post("/api/owner/stats", { token: ilja.token, days: 30 })).data.error, "not_owner");
  assert.equal((await post("/api/website/bulk", { token: ilja.token, amount: 0, reason: "Bonus" })).data.error, "invalid_amount");
  assert.equal((await post("/api/website/bulk", { token: ilja.token, amount: 5, reason: "" })).data.error, "reason_required");
  // Chain-Coins senden bleibt für Basic gesperrt
  assert.equal((await post("/api/transactions", { token: basic.token, to: "ilja", amount: 1 })).data.error, "basic_no_transfers");
  await post("/api/settings", { token: ilja.token, basicPermissions: ["mining", "rules", "market", "tabs", "payments"] });
  void basic;
});

test("each basic account can get its own permissions", async () => {
  serverCode("343434");
  const ilja = (await post("/api/auth/login", { username: "ilja", password: "passwort123", code: "343434" })).data;
  await post("/api/settings", { token: ilja.token, basicPermissions: ["s:reward"] });
  await post("/api/admin/node-users/create", { token: ilja.token, username: "eigen", password: "passwort123" });
  await post("/api/admin/node-users/level", { token: ilja.token, username: "eigen", level: "basic" });
  const users = (await post("/api/admin/node-users", { token: ilja.token })).data.users;
  const addr = users.find((u) => u.username === "eigen").address;
  const robyn = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  // Basic darf das nicht
  assert.equal((await post("/api/admin/user-permissions/set", { token: robyn.token, address: addr, permissions: ["a:bank"] })).data.error, "not_owner");
  const set = (await post("/api/admin/user-permissions/set", { token: ilja.token, address: addr, permissions: ["a:games", "nicht-echt"] })).data;
  assert.deepEqual([set.custom, set.permissions], [true, ["a:games", "a:infos"]]);
  const eigen = (await post("/api/auth/login", { username: "eigen", password: "passwort123" })).data;
  assert.deepEqual((await post("/api/auth/me", { token: eigen.token })).data.permissions, ["a:games", "a:infos"]);
  assert.deepEqual((await post("/api/auth/me", { token: robyn.token })).data.permissions, ["s:reward"], "andere behalten Standard");
  // Zurück auf Standard
  assert.equal((await post("/api/admin/user-permissions/set", { token: ilja.token, address: addr, permissions: null })).data.custom, false);
  assert.deepEqual((await post("/api/auth/me", { token: eigen.token })).data.permissions, ["s:reward"]);
});
