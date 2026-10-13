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
    if (req.url.includes("node_list_users")) return send(200, { ok: true, users: Object.entries(users).map(([e, x]) => ({ id: x.id, username: x.username, display_name: x.username, role: x.role, balance: 10 })) });
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

test("website owners get a basic chain login; full needs an upgrade and the server code", async () => {
  assert.equal((await post("/api/auth/login", { username: "lea@x.ch", password: "lea-pass" })).data.error, "not_owner_account");
  assert.equal((await post("/api/auth/login", { username: "robyn@x.ch", password: "falsch" })).data.error, "invalid_login");

  const basic = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data;
  assert.equal(basic.role, "owner_basic");
  // Basic: Mining-Einstellungen ja, Server-/Bank-Einstellungen nein, Admin nein
  const s = (await post("/api/settings", { token: basic.token, reward: 7, fallbackMinerEnabled: false, website: { bankIban: "CH9300762011623852957", maxTrade: 50 } })).data;
  assert.equal(s.reward, 7);
  assert.equal(s.fallbackMinerEnabled, true);
  assert.equal(s.website.bankIban, "");
  assert.equal(s.website.maxTrade, 50);
  assert.equal((await post("/api/admin/node-users", { token: basic.token })).data.error, "not_owner");

  // Ilja (lokales Owner-Konto) upgradet robyn auf Full
  await post("/api/auth/register", { username: "ilja", password: "passwort123", setupCode: "geheim-1234" });
  serverCode("111222");
  const ilja = (await post("/api/auth/login", { username: "ilja", password: "passwort123", code: "111222" })).data;
  assert.equal((await post("/api/admin/owner-level", { token: ilja.token, userId: ROBYN, level: "full" })).data.level, "full");
  assert.equal((await post("/api/auth/me", { token: basic.token })).data.ok, false, "alte Basic-Sitzung beendet");

  assert.equal((await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data.error, "second_factor_required");
  serverCode("333444");
  const full = (await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass", code: "333444" })).data;
  assert.equal(full.role, "super_admin");
  assert.ok(Array.isArray((await post("/api/admin/node-users", { token: full.token })).data.users));

  // Zurückstufen
  await post("/api/admin/owner-level", { token: ilja.token, userId: ROBYN, level: "basic" });
  assert.equal((await post("/api/auth/login", { username: "robyn@x.ch", password: "robyn-pass" })).data.role, "owner_basic");
});
