import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = 18900 + Math.floor(Math.random() * 90);
const base = `http://127.0.0.1:${PORT}`;
let child;

const post = async (path, body) => {
  const res = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return { status: res.status, data: await res.json().catch(() => ({})) };
};

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), "gibb-sec-"));
  child = spawn(process.execPath, [join(here, "server.mjs")], {
    env: { ...process.env, PORT: String(PORT), CHAIN_FILE: join(dir, "chain.json"), GIBB_OWNER_SETUP_CODE: "geheim-1234", NO_AUTH: "", FALLBACK_MINER: "0", SUPABASE_URL: "", SUPABASE_ANON_KEY: "", SUPABASE_SERVICE_ROLE_KEY: "" },
    stdio: "ignore",
  });
  for (let i = 0; i < 50; i += 1) {
    try { await fetch(`${base}/api/stats`); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
});
after(() => child?.kill());

test("owner name is reserved without the setup code", async () => {
  assert.equal((await post("/api/auth/register", { username: "ilja", password: "passwort123" })).data.error, "owner_name_reserved");
  const ok = await post("/api/auth/register", { username: "ilja", password: "passwort123", setupCode: "geheim-1234" });
  assert.equal(ok.data.role, "super_admin");
});

test("short passwords are rejected", async () => {
  assert.equal((await post("/api/auth/register", { username: "kurz", password: "1234567" })).data.error, "weak_password");
});

test("sending and trading need a login and only work for the own account", async () => {
  const lea = (await post("/api/auth/register", { username: "lea", password: "passwort123" })).data;
  const tim = (await post("/api/auth/register", { username: "tim", password: "passwort123" })).data;
  assert.equal((await post("/api/transactions", { from: lea.address, to: tim.address, amount: 1 })).data.error, "login_required");
  assert.equal((await post("/api/transactions", { token: tim.token, from: lea.address, to: tim.address, amount: 1 })).data.error, "not_your_account");
  assert.equal((await post("/api/order", { address: lea.address, side: "sell", price: 1, amount: 1 })).data.error, "login_required");
  assert.equal((await post("/api/order", { token: tim.token, address: lea.address, side: "sell", price: 1, amount: 1 })).data.error, "not_your_account");
  assert.equal((await post("/api/order-cancel", { address: lea.address, order_id: "x" })).data.error, "login_required");
});

test("no free coins: wallets and website accounts need authorization", async () => {
  assert.equal((await post("/api/wallets", { name: "Spam" })).data.error, "not_owner");
  // Ohne Supabase-Verbindung entsteht höchstens ein leeres Konto – nie das gewünschte Guthaben.
  const reg = (await post("/api/register", { supabaseId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "x", balance: 999999 })).data;
  assert.equal(reg.balance, 0);
  const again = (await post("/api/register", { supabaseId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "umbenannt", balance: 5 })).data;
  assert.equal(again.name, "x", "bestehendes Konto wird nicht umbenannt");
  assert.equal(again.balance, 0);
  assert.equal((await post("/api/register", { supabaseId: "kein-uuid", name: "x" })).data.error, "invalid_supabase_id");
});

test("brute force is blocked after 5 wrong passwords", async () => {
  await post("/api/auth/register", { username: "opfer", password: "richtig123" });
  for (let i = 0; i < 5; i += 1) assert.equal((await post("/api/auth/login", { username: "opfer", password: "falsch" + i })).data.error, "invalid_login");
  assert.equal((await post("/api/auth/login", { username: "opfer", password: "richtig123" })).data.error, "too_many_attempts");
});

test("logout ends the session and huge requests are refused", async () => {
  const u = (await post("/api/auth/register", { username: "ausloggen", password: "passwort123" })).data;
  assert.equal((await post("/api/auth/me", { token: u.token })).data.ok, true);
  await post("/api/auth/logout", { token: u.token });
  assert.equal((await post("/api/auth/me", { token: u.token })).data.ok, false);
  const res = await fetch(`${base}/api/auth/login`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ x: "a".repeat(1_100_000) }) });
  assert.equal(res.status, 413);
});
