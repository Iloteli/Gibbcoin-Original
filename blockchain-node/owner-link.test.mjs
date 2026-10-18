import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// Das Owner-Konto der Chain-Seite nutzt das Website-Wallet des Owners (ein Wallet für beides).
const here = dirname(fileURLToPath(import.meta.url));
const PORT = 19300 + Math.floor(Math.random() * 80);
const SB_PORT = PORT + 100;
const base = `http://127.0.0.1:${PORT}`;
const ILJA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
let child, sb, dir;
const adjustments = [];

const post = async (path, body) => {
  const res = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return res.json().catch(() => ({}));
};

before(async () => {
  sb = createServer(async (req, res) => {
    let raw = ""; for await (const c of req) raw += c;
    const send = (data) => { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify(data)); };
    if (req.url.includes("node_list_users")) return send({ ok: true, users: [{ id: ILJA, username: "iloteli", display_name: "Ilja", role: "super_admin", balance: 50, is_primary: true }] });
    if (req.url.includes("node_adjust_balance")) { adjustments.push(JSON.parse(raw)); return send({ ok: true }); }
    return send({ ok: true });
  }).listen(SB_PORT);
  dir = mkdtempSync(join(tmpdir(), "gibb-link-"));
  // Chain-Datei mit Owner "ilja" und eigenem Chain-Wallet (7 GIBB)
  writeFileSync(join(dir, "chain.json"), JSON.stringify({ blocks: [], mempool: [], accounts: { Gold: { name: "ilja", balance: 7, cash: 100, lockedGibb: 0, lockedCash: 0 } }, users: {}, settings: {}, orders: [], trades: [] }));
  child = spawn(process.execPath, [join(here, "server.mjs")], {
    env: { ...process.env, PORT: String(PORT), CHAIN_FILE: join(dir, "chain.json"), GIBB_OWNER_SETUP_CODE: "geheim-1234", NODE_REGISTRATION: "1", OWNER_2FA: "0", FALLBACK_MINER: "0", SUPABASE_URL: `http://127.0.0.1:${SB_PORT}`, SUPABASE_ANON_KEY: "anon", NODE_SETTINGS_KEY: "k", SUPABASE_SERVICE_ROLE_KEY: "", OWNER_LINK_DELAY_MS: "600000" },
    stdio: "ignore",
  });
  for (let i = 0; i < 50; i += 1) {
    try { await fetch(`${base}/api/stats`); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
});
after(() => { child?.kill(); sb?.close(); });

test("owner chain login uses the website wallet after linking", async () => {
  const reg = await post("/api/auth/register", { username: "ilja", password: "passwort123", setupCode: "geheim-1234" });
  assert.equal(reg.role, "super_admin");
  assert.match(reg.address, /^G/);
  // Verbindung manuell auslösen (sonst nach 15 s automatisch)
  const r = await post("/api/admin/link-owner-wallet", { token: reg.token });
  assert.equal(r.address, `sb_${ILJA}`);
  const login = await post("/api/auth/login", { username: "ilja", password: "passwort123" });
  assert.equal(login.address, `sb_${ILJA}`);
  const accounts = await (await fetch(`${base}/api/accounts`)).json();
  assert.equal(accounts.some((a) => a.address === reg.address), false, "altes Chain-Wallet entfernt");
  assert.ok(accounts.some((a) => a.address === `sb_${ILJA}`));
});
