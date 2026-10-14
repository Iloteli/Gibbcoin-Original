// HTTP-Server für den GIBB-Blockchain-Node: REST-API + Verwaltungs-Website.
// Start:  node blockchain-node/server.mjs   (Port über PORT, Datei über CHAIN_FILE)

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { readFile } from "node:fs/promises";
import { availableParallelism } from "node:os";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Blockchain } from "./chain.mjs";
import { startFallbackMiner } from "./fallback-miner.mjs";
import { createWalletCredit } from "./wallet-credit.mjs";
import { createWebsiteOwnerCheck, createWebsiteUserCheck } from "./website-owner.mjs";
import { startServerMining } from "./server-mining.mjs";
import { createSettingsSync } from "./settings-sync.mjs";
import { createNotifier } from "./notify.mjs";
import { ALL_PERMISSIONS, PERMISSION_CATALOG, normalizePermissions } from "./permissions.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT ?? 8787);
const chain = new Blockchain(process.env.CHAIN_FILE ?? join(here, "data", "chain.json"));

// Der Server mined nicht selbst: Browser oder der lokale Miner-Prozess holen Vorlagen
// und reichen gefundene Nonces ein.
const recentBlocks = [];
const log = [];

// Lokaler Miner (blockchain-node/miner.mjs) als Kindprozess auf diesem Rechner,
// gestartet über die Website. Nutzt standardmässig alle Prozessorkerne.
// Reserve-Miner: dedizierte Server-Wallet sicherstellen und Reserve-Miner starten.
const FALLBACK_ADDRESS = "srv_fallback";
if (!chain.accounts[FALLBACK_ADDRESS]) {
  chain.accounts[FALLBACK_ADDRESS] = { name: "Server (Reserve-Miner)", balance: 0, cash: chain.settings.startingCash, lockedGibb: 0, lockedCash: 0, createdAt: Date.now(), source: "server" };
  chain.save();
}
const walletCredit = createWalletCredit({ note: (kind, msg) => note(kind, msg) });
const settingsSync = createSettingsSync({ chain, note: (kind, msg) => note(kind, msg), onAccountRemoved: (address) => serverMining?.disable(address) });
// Server-Mining für Website-Nutzer (läuft weiter, auch wenn der Browser-Tab zu ist).
const serverMining = startServerMining(chain, {
  file: join(dirname(process.env.CHAIN_FILE ?? join(here, "data", "chain.json")), "server-miners.json"),
  note: (m) => note("block", m),
  onBlock: (block) => {
    recentBlocks.unshift({ height: block.height, hash: block.hash, miner_label: block.miner_label, attempts: block.attempts, ms: block.mining_ms, hashrate: block.hashrate, at: Date.now() });
    recentBlocks.length = Math.min(recentBlocks.length, 12);
    walletCredit.onBlock(block);
  },
});
const websiteUser = createWebsiteUserCheck();
// Push-Benachrichtigungen an den Owner (ntfy): neue Überweisungen, Support-Fälle, Neustart
const notifier = createNotifier({ file: join(dirname(process.env.CHAIN_FILE ?? join(here, "data", "chain.json")), "notify.json"), note: (kind, msg) => note(kind, msg) });
if (settingsSync.enabled) {
  notifier.watch(async () => (await settingsSync.listBankOrders()).filter((o) => o.status === "pending"), {
    kind: "bank",
    format: (o) => ({ title: "💸 Neue Banküberweisung", message: `${o.reference}: ${o.gibb} GIBB · CHF ${(Number(o.rappen) / 100).toFixed(2)}. Prüfe dein Konto und bestätige die Zahlung auf der Chain-Seite.`, priority: 4, tags: ["moneybag"] }),
  });
  notifier.watch(async () => {
    const r = await settingsSync.ownerCall("admin_list_control_center_page", { p_page: 1, p_page_size: 20 });
    const c = Array.isArray(r) ? r[0] : r;
    return (c?.tickets ?? []).filter((t) => !["closed", "resolved", "done"].includes(String(t.status ?? "").toLowerCase()));
  }, {
    kind: "support",
    format: (t) => ({ title: "🎫 Neuer Support-Fall", message: String(t.subject ?? "Ohne Betreff").slice(0, 200), priority: String(t.priority) === "high" ? 4 : 3, tags: ["ticket"] }),
  });
}
const fallbackMiner = startFallbackMiner(chain, { getAddress: () => FALLBACK_ADDRESS, note: (m) => note("block", m) });

const localMiner = {
  process: null, address: null, threads: 0, startedAt: null,
  attempts: 0, hashrate: 0, expected: 0, elapsed: 0, height: null, difficulty_bits: null,
  blocks: 0, reward: 0, lastEvent: null, lastError: null,
};
function localMinerState() {
  const { process: child, ...rest } = localMiner;
  return { ...rest, running: Boolean(child), pid: child?.pid ?? null, cores: availableParallelism() };
}
function startLocalMiner(address, threads) {
  if (localMiner.process) throw new Error("miner_already_running");
  if (!chain.accounts[address]) throw new Error("unknown_miner");
  const count = Math.max(1, Math.min(availableParallelism(), Number(threads) || availableParallelism()));
  const child = spawn(process.execPath, [join(here, "miner.mjs"), "--server", `http://127.0.0.1:${PORT}`, "--wallet", address, "--threads", String(count), "--json"], { stdio: ["ignore", "pipe", "pipe"] });
  Object.assign(localMiner, { process: child, address, threads: count, startedAt: Date.now(), attempts: 0, hashrate: 0, expected: 0, elapsed: 0, height: null, difficulty_bits: null, blocks: 0, reward: 0, lastEvent: null, lastError: null });
  createInterface({ input: child.stdout }).on("line", (line) => {
    let event;
    try { event = JSON.parse(line); } catch { return; }
    localMiner.lastEvent = event.event;
    if (event.event === "progress") Object.assign(localMiner, { attempts: event.attempts, hashrate: event.hashrate, expected: event.expected, elapsed: event.elapsed });
    if (event.event === "template") Object.assign(localMiner, { height: event.height, difficulty_bits: event.difficulty_bits, attempts: 0, elapsed: 0 });
    if (event.event === "block") { localMiner.blocks = event.total_blocks; localMiner.reward = event.total_reward; }
    if (event.event === "rejected" && event.reason !== "stale_block") localMiner.lastError = event.reason;
  });
  createInterface({ input: child.stderr }).on("line", (line) => { localMiner.lastError = line; note("error", `Miner: ${line}`); });
  child.on("exit", (code) => {
    if (localMiner.process === child) localMiner.process = null;
    note("miner", `Lokaler Miner beendet (Code ${code ?? "?"}) – ${localMiner.blocks} Blöcke, ${localMiner.reward} GIBB`);
  });
  note("miner", `Lokaler Miner gestartet für ${chain.accounts[address].name} mit ${count} Thread(s) (PID ${child.pid})`);
  return localMinerState();
}
function stopLocalMiner() {
  const child = localMiner.process;
  if (!child) return localMinerState();
  child.kill("SIGTERM");
  setTimeout(() => { if (!child.killed || child.exitCode === null) child.kill("SIGKILL"); }, 4000).unref();
  localMiner.process = null;
  return localMinerState();
}
process.on("exit", () => { localMiner.process?.kill("SIGKILL"); });
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => { localMiner.process?.kill("SIGKILL"); process.exit(0); });
function note(kind, message) {
  log.unshift({ at: Date.now(), kind, message });
  log.length = Math.min(log.length, 60);
}

// ---------- API ----------
// Anmelde-Sitzungen: sha256(token) -> { address, username, role, expires }.
// Werden in sessions.json gespeichert (nur Hashes), damit ein Neustart/Update niemanden abmeldet.
import { randomBytes as _rnd, createHash as _hash } from "node:crypto";
import { existsSync as _exists, readFileSync as _read, writeFileSync as _write, renameSync as _rename, unlinkSync as _unlink } from "node:fs";
const SESSION_FILE = join(dirname(process.env.CHAIN_FILE ?? join(here, "data", "chain.json")), "sessions.json");
const tokenKey = (token) => _hash("sha256").update(String(token)).digest("hex");
const sessions = new Map();
try { if (_exists(SESSION_FILE)) for (const [k, v] of Object.entries(JSON.parse(_read(SESSION_FILE, "utf8")))) if (v?.expires > Date.now()) sessions.set(k, v); } catch { /* leere Sitzungen */ }
const saveSessions = () => {
  try { const tmp = `${SESSION_FILE}.tmp`; _write(tmp, JSON.stringify(Object.fromEntries(sessions)), { mode: 0o600 }); _rename(tmp, SESSION_FILE); } catch { /* nur im Speicher */ }
};
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // Sitzungen laufen nach 12 Stunden ab
// Alle Sitzungen eines Kontos beenden (nach Löschen oder Passwortwechsel)
const dropSessionsOf = (username) => {
  const name = String(username ?? "").toLowerCase();
  let changed = false;
  for (const [k, sess] of sessions) if (String(sess.username ?? "").toLowerCase() === name) { sessions.delete(k); changed = true; }
  if (changed) saveSessions();
};
const OWNER_IDLE_MS = 30 * 60 * 1000;          // Owner wird nach 30 Minuten ohne Aktivität abgemeldet

// Zweiter Faktor für den Owner: Einmal-Code vom Server ("sudo gibb-code"), 5 Minuten gültig, einmal nutzbar.
const OWNER_2FA = process.env.OWNER_2FA !== "0";
const OWNER_CODE_FILE = process.env.OWNER_CODE_FILE ?? join(dirname(process.env.CHAIN_FILE ?? join(here, "data", "chain.json")), "owner-login-code.json");
const checkOwnerCode = (code) => {
  if (!OWNER_2FA) return true;
  if (typeof code !== "string" || !/^\d{6,8}$/.test(code.trim())) return false;
  let info;
  try { info = JSON.parse(_read(OWNER_CODE_FILE, "utf8")); } catch { return false; }
  if (!info?.hash || !(Number(info.expires) > Date.now())) return false;
  if (_hash("sha256").update(code.trim()).digest("hex") !== info.hash) return false;
  try { _unlink(OWNER_CODE_FILE); } catch { /* Code verfällt sonst nach 5 Minuten */ }
  return true;
};
const newSession = (u) => {
  const token = _rnd(32).toString("hex");
  sessions.set(tokenKey(token), { address: u.address, username: u.username, role: u.role, ...(u.level ? { level: u.level } : {}), expires: Date.now() + SESSION_TTL_MS });
  saveSessions();
  return token;
};
setInterval(() => { const now = Date.now(); let changed = false; for (const [t, s] of sessions) if (s.expires < now) { sessions.delete(t); changed = true; } if (changed) saveSessions(); }, 60_000).unref();

// Schutz gegen Passwort-Raten (Sperre für 15 Minuten nach zu vielen Fehlversuchen).
const loginFailures = new Map(); // key -> { count, until }
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
// Pro Name 5 Versuche; pro IP 30 (in der Schule teilen sich viele dieselbe öffentliche IP).
const loginBlocked = (...keys) => keys.some((k) => { const f = loginFailures.get(k); return f && f.until > Date.now() && f.count >= (k.startsWith("ip:") ? 30 : 5); });
const loginFailed = (...keys) => {
  for (const k of keys) {
    const f = loginFailures.get(k);
    if (!f || f.until < Date.now()) loginFailures.set(k, { count: 1, until: Date.now() + LOGIN_WINDOW_MS });
    else f.count += 1;
  }
  if (loginFailures.size > 5000) loginFailures.clear();
};

// NO_AUTH=1: keine Anmeldung nötig – jeder Aufruf läuft als lokaler "Gast" mit Owner-Rechten.
// Nur für direkte Aufrufe am Rechner selbst (nicht über Tunnel/Gateway von aussen).
const NO_AUTH = process.env.NO_AUTH === "1";
let guestSession = null;
const getGuest = () => {
  if (!guestSession) {
    const existing = Object.entries(chain.accounts).find(([, a]) => a.name === "Gast");
    const address = existing ? existing[0] : chain.createWallet("Gast").address;
    guestSession = { address, username: "Gast", role: "super_admin" };
  }
  return guestSession;
};
const sessionOf = (body) => {
  const sess = body && typeof body.token === "string" ? sessions.get(tokenKey(body.token)) : null;
  const blocked = sess && sess.role !== "super_admin" && sess.role !== "owner_basic" && (chain.settings.chainLoginsEnabled === false || chain.users[String(sess.username ?? "").toLowerCase()]?.disabled);
  if (sess && !blocked && sess.expires > Date.now() && !((sess.role === "super_admin" || sess.role === "owner_basic") && Date.now() - (sess.lastSeen ?? Date.now()) > OWNER_IDLE_MS)) {
    sess.lastSeen = Date.now();
    return sess;
  }
  if (sess) { sessions.delete(tokenKey(body.token)); saveSessions(); }
  return NO_AUTH && body?.__direct === true ? getGuest() : null;
};
const requireSession = (body) => { const sess = sessionOf(body); if (!sess) throw new Error("login_required"); return sess; };
const websiteOwnerSession = createWebsiteOwnerCheck();
// Owner: Node-Login (token) ODER Owner der GibbCoin-Website (supabaseToken, geprüft bei der eigenen Datenbank).
const requireOwner = async (body) => {
  const sess = sessionOf(body);
  if (sess && sess.role === "super_admin") return sess;
  const web = OWNER_2FA ? null : await websiteOwnerSession(body?.supabaseToken);
  if (web) return web;
  throw new Error("not_owner");
};

// ---------- Owner der Hauptseite: Anmeldung mit E-Mail/Passwort der Website ----------
// Jeder Website-Owner hat automatisch ein Basic-Konto; Ilja kann es auf Full upgraden. Den Server-Code braucht nur Ilja.
const SB_URL = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const SB_KEY = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const PRIMARY_OWNER_EMAIL = String(process.env.NODE_OWNER_EMAIL ?? "ilja.podorieszach@icloud.com").toLowerCase();
const ownerLevelOf = (userId, email) => (String(email ?? "").toLowerCase() === PRIMARY_OWNER_EMAIL ? "full" : chain.ownerLevels[userId] === "full" ? "full" : "basic");
async function loginWebsiteOwner(body, nameKey, ipKey) {
  if (!SB_URL || !SB_KEY) throw new Error("website_login_unavailable");
  const res = await fetch(`${SB_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: SB_KEY, "content-type": "application/json" },
    body: JSON.stringify({ email: String(body.username).trim(), password: String(body.password ?? "") }),
  });
  const auth = await res.json().catch(() => ({}));
  if (!res.ok || !auth?.access_token) { loginFailed(nameKey, ipKey); throw new Error("invalid_login"); }
  const user = await websiteUser(auth.access_token);
  if (!user || user.role !== "super_admin") { loginFailed(nameKey, ipKey); throw new Error("not_owner_account"); }
  const level = ownerLevelOf(user.userId, user.email);
  if (String(user.email ?? "").toLowerCase() === PRIMARY_OWNER_EMAIL && OWNER_2FA) {
    if (!body.code) throw new Error("second_factor_required");
    if (!checkOwnerCode(String(body.code))) { loginFailed(nameKey, ipKey); throw new Error("invalid_second_factor"); }
  }
  loginFailures.delete(nameKey);
  const address = `sb_${user.userId}`;
  if (!chain.accounts[address]) chain.upsertWebsiteAccount(user.userId, user.username, 0);
  const u = { address, username: user.username, role: level === "full" ? "super_admin" : "owner_basic", level, supabaseId: user.userId };
  const token = newSession(u);
  note("auth", `Owner ${user.username} (${level === "full" ? "Full" : "Basic"}) angemeldet`);
  return { token, ...u };
}
// Einstellungen: Full darf alles, Basic nur Mining, Mining-Regeln, Markt & Coinwert, Tabs und Zahlarten
// Rechte für Basic-Konten (Full stellt ein, was Basic sehen darf)
// Rechte: s:<Einstellung>, w:<Einstellung der Hauptseite>, a:<Aktion> (siehe permissions.mjs)
const permissionsOf = (sess) => (sess?.role === "super_admin" ? [...ALL_PERMISSIONS] : sess?.role === "owner_basic" ? normalizePermissions(chain.settings.basicPermissions) : []);
// Basic-Konten dürfen keine Coins bewegen (senden, Aufträge, Coins verwalten)
const forbidBasicTransfers = (sess) => { if (sess?.role === "owner_basic") throw new Error("basic_no_transfers"); };
const requirePermission = (body, perm) => {
  const sess = sessionOf(body);
  if (sess && (sess.role === "super_admin" || (sess.role === "owner_basic" && permissionsOf(sess).includes(perm)))) return sess;
  throw new Error("not_owner");
};
// Admin der Hauptseite: Full darf alles, Basic nur, was freigegeben ist
const requireAdminPermission = async (body, perm) => {
  const sess = sessionOf(body);
  if (perm && sess?.role === "owner_basic" && permissionsOf(sess).includes(perm)) return sess;
  return requireOwner(body);
};
const ADMIN_FN_PERMS = {
  admin_list_users: "a:accounts", admin_list_visual_roles: "a:accounts", admin_list_account_locks: "a:accounts", admin_set_visual_role: "a:accounts",
  get_game_center_state: "a:games", get_dino_admin_state: "a:games", get_global_game_limits: "a:games",
  admin_set_game_enabled: "a:games", admin_set_dino_game_settings: "a:games", admin_set_global_game_limits: "a:games",
  admin_run_health_check: "a:tools", admin_list_operations: "a:tools", admin_update_operation: "a:tools", admin_list_control_center_page: "a:tools",
  admin_update_case: "a:tools", admin_set_transfer_threshold: "a:tools", admin_list_transfer_approvals: "a:tools",
  admin_list_audit_logs: "a:audit", admin_visitor_stats: "a:visitors",
};
// PIN prüfen darf, wer Konten, Spiele oder Tools verwalten darf (Rollen ändern und PIN setzen bleibt Full)
const ADMIN_PIN_FNS = new Set(["admin_verify_pin", "admin_pin_status"]);
const PIN_PERMS = ["a:accounts", "a:accountsDelete", "a:games", "a:tools"];
const requireSettingsAccess = (body) => {
  const sess = sessionOf(body);
  if (sess && (sess.role === "super_admin" || sess.role === "owner_basic")) return sess;
  throw new Error("not_owner");
};
const limitSettingsPatch = (sess, body) => {
  if (sess.role === "super_admin") return body;
  const perms = new Set(permissionsOf(sess));
  const patch = {};
  const website = {};
  for (const [k, v] of Object.entries(body)) if (perms.has(`s:${k}`)) patch[k] = v;
  for (const [k, v] of Object.entries(body.website ?? {})) if (perms.has(`w:${k}`)) website[k] = v;
  if (Object.keys(website).length) patch.website = website;
  return patch;
};
const dropSessionsOfAddress = (address) => {
  let changed = false;
  for (const [k, sess] of sessions) if (sess.address === address) { sessions.delete(k); changed = true; }
  if (changed) saveSessions();
};

const routes = {
  "GET /api/permissions": () => ({ catalog: PERMISSION_CATALOG }),
  "GET /api/stats": () => ({ ...chain.stats(), recentBlocks, log, localMiner: localMinerState(), walletCredit: { enabled: walletCredit.enabled, pending: walletCredit.pendingCount() }, settingsSync: settingsSync.status(), fallbackMiner: fallbackMiner.status() }),
  // ---------- Lokale Anmeldung (kein Cloud-Supabase) ----------
  "POST /api/auth/register": (_, body) => {
    if (process.env.NODE_REGISTRATION !== "1") throw new Error("registration_disabled");
    const ipKey = `ip:${body.__ip}`;
    if (loginBlocked(ipKey)) throw new Error("too_many_attempts");
    let u;
    try { u = chain.registerUser(body.username, body.password, { setupCode: body.setupCode }); }
    catch (error) { if (error.message === "owner_name_reserved") loginFailed(ipKey); throw error; }
    const token = newSession(u);
    note("auth", `Neuer Nutzer registriert: ${u.username}${u.role === "super_admin" ? " (Owner)" : ""}`);
    return { token, ...u };
  },
  "POST /api/auth/login": async (_, body) => {
    const nameKey = `name:${String(body.username ?? "").trim().toLowerCase()}`;
    const ipKey = `ip:${body.__ip}`;
    if (loginBlocked(nameKey, ipKey)) throw new Error("too_many_attempts");
    if (String(body.username ?? "").includes("@")) return loginWebsiteOwner(body, nameKey, ipKey);
    let u;
    try { u = chain.verifyUser(body.username, body.password, { setupCode: body.setupCode }); }
    catch (error) { loginFailed(nameKey, ipKey); throw error; }
    // Nur Ilja (das geschützte Owner-Konto) braucht den Server-Code
    const isPrimaryOwner = u.role === "super_admin";
    // Stufe: Full = alle Rechte (wie der Owner), Basic = eingeschränkte Owner-Rechte
    if (u.role !== "super_admin" && u.level === "full") u.role = "super_admin";
    else if (u.role !== "super_admin" && u.level === "basic") u.role = "owner_basic";
    if (isPrimaryOwner && OWNER_2FA) {
      if (!body.code) throw new Error("second_factor_required");
      if (!checkOwnerCode(String(body.code))) { loginFailed(nameKey, ipKey); throw new Error("invalid_second_factor"); }
      note("auth", `Owner ${u.username} mit Server-Code angemeldet`);
    }
    loginFailures.delete(nameKey);
    const token = newSession(u);
    return { token, ...u };
  },
  "POST /api/auth/logout": (_, body) => {
    if (typeof body.token === "string") { sessions.delete(tokenKey(body.token)); saveSessions(); }
    return { ok: true };
  },
  "POST /api/auth/me": (_, body) => {
    const sess = sessionOf(body);
    if (!sess) return { ok: false };
    const acc = chain.accounts[sess.address] || {};
    return { ok: true, ...sess, permissions: permissionsOf(sess), balance: acc.balance ?? 0, cash: acc.cash ?? 0 };
  },
  // Miner-Prozess auf diesem Rechner starten/stoppen (alle Kerne, so viele Blöcke wie möglich).
  "POST /api/local-miner": async (_, body) => { requirePermission(body, "a:miner"); return body.enabled ? startLocalMiner(body.address, body.threads) : stopLocalMiner(); },
  // Von der echten Website: aktuelles Konto anmelden, damit es hier erscheint.
  // Nur mit gültigem Website-Login und nur für das eigene Konto. Ein vom Browser geschicktes
  // Guthaben wird NICHT übernommen (sonst könnte sich jeder Coins geben).
  "POST /api/register": async (_, body) => {
    const user = await websiteUser(body?.supabaseToken);
    if (!user && websiteUser.enabled) throw new Error("login_required");
    if (user && body.supabaseId && body.supabaseId !== user.userId) throw new Error("not_your_account");
    let acc;
    if (user) {
      acc = chain.upsertWebsiteAccount(user.userId, user.username, 0);
    } else {
      // Node ohne Supabase-Verbindung: nur ein LEERES Konto anlegen (Guthaben 0), nichts umbenennen.
      const id = String(body.supabaseId ?? "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error("invalid_supabase_id");
      const existing = chain.accounts[`sb_${id}`];
      acc = existing ? { address: `sb_${id}`, ...existing } : chain.upsertWebsiteAccount(id, String(body.name ?? "Nutzer").slice(0, 40), 0);
    }
    note("sync", `Konto von der Website angemeldet: ${acc.name} (${acc.address})`);
    return { address: acc.address, name: acc.name, balance: acc.balance, cash: acc.cash };
  },
  // Von einem Admin der Website: alle Nutzer auf einmal übernehmen.
  "POST /api/register-many": async (_, body) => {
    await requireOwner(body);
    const list = Array.isArray(body.users) ? body.users : [];
    let added = 0;
    let updated = 0;
    for (const u of list) {
      if (!u || !u.supabaseId) continue;
      const before = Boolean(chain.accounts[`sb_${u.supabaseId}`]);
      chain.upsertWebsiteAccount(u.supabaseId, u.name, Number(u.balance), { overwriteBalance: true });
      if (before) updated += 1; else added += 1;
    }
    note("sync", `Alle Website-Nutzer übernommen: ${added} neu, ${updated} aktualisiert (${list.length} gesamt)`);
    return { ok: true, added, updated, total: list.length };
  },
  // Miner-Status bezogen auf eine bestimmte Adresse (für den Button auf der Website).
  "GET /api/miner-status": (url) => {
    const address = url.searchParams.get("address");
    const m = localMinerState();
    const acc = address ? chain.accounts[address] : null;
    return { ...m, forThisAccount: m.running && m.address === address, account: acc ? { address, name: acc.name, balance: acc.balance, cash: acc.cash } : null, cores: m.cores, price: chain.marketPrice() };
  },
  "GET /api/blocks": (url) => {
    const limit = Math.min(200, Number(url.searchParams.get("limit") ?? 30));
    const before = url.searchParams.get("before");
    let list = chain.blocks.slice().reverse();
    if (before !== null) list = list.filter((b) => b.height < Number(before));
    return list.slice(0, limit).map(summarize);
  },
  "GET /api/block": (url) => {
    const block = chain.blocks.find((b) => b.height === Number(url.searchParams.get("height")));
    if (!block) throw new Error("unknown_block");
    return block;
  },
  "GET /api/mempool": () => chain.mempool,
  "GET /api/accounts": () => Object.entries(chain.accounts).map(([address, { supabaseId: _sid, ...a }]) => ({ address, ...a, available: chain.availableBalance(address), availableCash: chain.availableCash(address) })).sort((x, y) => y.balance - x.balance),
  "GET /api/market": (url) => chain.market(url.searchParams.get("address")),
  "POST /api/order": (_, body) => {
    const sess = requireSession(body);
    forbidBasicTransfers(sess);
    if (body.address && body.address !== sess.address) throw new Error("not_your_account");
    body.address = sess.address;
    const r = chain.placeOrder(body.address, body.side, body.price, body.amount);
    note("market", `${chain.accounts[body.address]?.name ?? body.address}: ${body.side === "buy" ? "Kauf" : "Verkauf"} ${body.amount} GIBB zu ${body.price} Rp${r.fills.length ? ` – ${r.fills.length} Handel, Kurs ${r.price} Rp` : " (im Buch)"}`);
    return r;
  },
  "POST /api/order-cancel": (_, body) => {
    const sess = requireSession(body);
    if (body.address && body.address !== sess.address) throw new Error("not_your_account");
    return chain.cancelOrder(sess.address, body.order_id);
  },
  "GET /api/verify": () => chain.verify(),
  "POST /api/wallets": async (_, body) => { await requireOwner(body); return chain.createWallet(body.name); },
  "POST /api/transactions": (_, body) => {
    const sess = requireSession(body); // Senden nur angemeldet und nur vom eigenen Konto
    forbidBasicTransfers(sess);
    const from = sess.address;
    if (body.from && body.from !== sess.address) throw new Error("not_your_account");
    // Empfänger darf Adresse ODER Benutzername sein.
    let to = body.to;
    if (to && !chain.accounts[to]) { const u = chain.users[String(to).trim().toLowerCase()]; if (u) to = u.address; }
    const tx = chain.addTransaction(from, to, body.amount, body.note);
    note("tx", `${chain.accounts[tx.from]?.name || tx.from} → ${chain.accounts[tx.to]?.name || tx.to}: ${tx.amount} GIBB im Mempool`);
    return tx;
  },
  // Vorlage für den Browser-Miner (Transaktionen nur als Hashes, der Header-Präfix ist fertig zusammengesetzt).
  "POST /api/template": (_, body) => {
    const t = chain.issueTemplate(body.address);
    return { id: t.id, height: t.height, previous_hash: t.previous_hash, merkle_root: t.merkle_root, timestamp: t.timestamp, difficulty_bits: t.difficulty_bits, miner_user_id: t.miner_user_id, tx_count: t.transactions.length, tx_hashes: t.transactions.map((tx) => tx.hash), reward: t.transactions[0]?.amount ?? 0, header_prefix: t.header_prefix };
  },
  // Gefundene Nonce einreichen – der Server prüft Hash, Merkle-Root, Schwierigkeit und Proof of Work komplett nach.
  "POST /api/submit": (_, body) => {
    try {
      const block = chain.submit(body.template_id, body.nonce, body.hash, { attempts: Number(body.attempts), ms: Number(body.ms), hashrate: Number(body.hashrate) });
      recentBlocks.unshift({ height: block.height, hash: block.hash, miner_label: block.miner_label, attempts: block.attempts, ms: block.mining_ms, hashrate: block.hashrate, at: Date.now() });
      recentBlocks.length = Math.min(recentBlocks.length, 12);
      walletCredit.onBlock(block);
      note("block", `Block #${block.height} von ${block.miner_label} gefunden (${block.attempts ?? "?"} Versuche, ${block.mining_ms ?? "?"} ms, ${block.difficulty_bits} Bit)`);
      return summarize(block);
    } catch (error) {
      if (error.message !== "stale_block") note("error", `Block abgelehnt: ${error.message}`);
      throw error;
    }
  },
  // Server-Mining: Status lesen (öffentlich) und für das eigene Website-Konto ein-/ausschalten.
  "GET /api/server-mining": (url) => serverMining.status(url.searchParams.get("address")),
  "POST /api/server-mining": async (_, body) => {
    const user = await websiteUser(body?.supabaseToken);
    if (!user) throw new Error("login_required");
    const address = `sb_${user.userId}`;
    if (!chain.accounts[address]) chain.upsertWebsiteAccount(user.userId, user.username, 0);
    if (body.enabled) {
      const s = serverMining.enable(address, user.username);
      note("mining", `Server-Mining eingeschaltet für ${user.username}`);
      return s;
    }
    note("mining", `Server-Mining ausgeschaltet für ${user.username}`);
    return serverMining.disable(address);
  },
  "POST /api/settings": async (_, body) => { const who = requireSettingsAccess(body); body = limitSettingsPatch(who, body); const s = chain.updateSettings(body); note("settings", `Einstellungen geändert: Belohnung ${s.reward}, Schwierigkeit ${s.difficultyBits} Bit${s.autoAdjust ? " (auto)" : ""}, Ziel ${s.targetSeconds} s`); const website = await settingsSync.push({ price: body.websitePrice }); return { ...s, websitePush: website }; },
  // Coins der Website-Benutzer geben/abziehen (nur Owner der Chain-Seite)
  // Admin-Bereich der Hauptseite (nur Owner der Chain-Seite)
  "POST /api/admin/call": async (_, body) => {
    const fn = String(body.fn ?? "");
    const sess = sessionOf(body);
    const pinOk = ADMIN_PIN_FNS.has(fn) && sess?.role === "owner_basic" && PIN_PERMS.some((p) => permissionsOf(sess).includes(p));
    if (!pinOk) await requireAdminPermission(body, ADMIN_FN_PERMS[fn]);
    const args = body.args && typeof body.args === "object" && !Array.isArray(body.args) ? body.args : {};
    return { data: await settingsSync.ownerCall(fn, args) };
  },
  "POST /api/admin/status": async (_, body) => {
    await requireAdminPermission(body, "a:accounts");
    const minutes = body.minutes == null || body.minutes === "" ? null : Number(body.minutes);
    const r = await settingsSync.setAccountStatus(String(body.userId ?? ""), body.status === "locked" ? "locked" : "active", minutes, String(body.reason ?? ""));
    note("auth", `Konto ${String(body.name ?? body.userId).slice(0, 40)} ${body.status === "locked" ? "gebannt" : "entbannt"}`);
    void settingsSync.syncAccounts();
    return r;
  },
  "POST /api/admin/delete": async (_, body) => {
    await requireAdminPermission(body, "a:accountsDelete");
    const r = await settingsSync.deleteAccount(String(body.userId ?? ""), String(body.pin ?? ""));
    note("auth", `Konto ${String(body.name ?? body.userId).slice(0, 40)} gelöscht`);
    void settingsSync.syncAccounts();
    return r;
  },
  // Anmeldungen für die Chain-Seite selbst (nur Owner)
  "POST /api/admin/owner-levels": async (_, body) => {
    await requireOwner(body);
    const users = await settingsSync.listWebsiteUsers();
    return { owners: users.filter((u) => u.role === "super_admin").map((u) => ({ id: u.id, username: u.username, display_name: u.display_name, primary: u.is_primary === true, level: u.is_primary === true || chain.ownerLevels[u.id] === "full" ? "full" : "basic" })) };
  },
  "POST /api/admin/owner-level": async (_, body) => {
    await requireOwner(body);
    const id = String(body.userId ?? "").toLowerCase();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw new Error("invalid_request");
    const level = body.level === "full" ? "full" : "basic";
    const target = (await settingsSync.listWebsiteUsers()).find((u) => String(u.id).toLowerCase() === id);
    if (target?.is_primary === true && level !== "full") throw new Error("account_is_protected");
    if (level === "full") chain.ownerLevels[id] = "full"; else delete chain.ownerLevels[id];
    chain.save();
    dropSessionsOfAddress(`sb_${id}`); // neu anmelden, damit die neue Stufe gilt
    void settingsSync.push(); // Hauptseite: Support bearbeiten nur für Full
    note("auth", `Owner ${String(body.name ?? id).slice(0, 40)} ist jetzt ${level === "full" ? "Full" : "Basic"}`);
    return { ok: true, level };
  },
  // Benachrichtigungen (nur Full)
  "POST /api/notify/get": async (_, body) => { await requireOwner(body); return notifier.get(); },
  "POST /api/notify/set": async (_, body) => {
    await requireOwner(body);
    const r = notifier.set({ enabled: body.enabled, bank: body.bank, support: body.support, start: body.start, server: body.server, topic: body.topic, newTopic: body.newTopic === true });
    note("settings", `Benachrichtigungen ${r.enabled ? "an" : "aus"}`);
    return r;
  },
  "POST /api/notify/test": async (_, body) => {
    await requireOwner(body);
    return notifier.send("test", "🔔 Test von GIBB Coin", "Wenn du das liest, kommen die Benachrichtigungen an.", { tags: ["bell"] });
  },
  "POST /api/admin/node-users": async (_, body) => { await requireOwner(body); return { users: chain.listUsers() }; },
  "POST /api/admin/node-users/create": async (_, body) => {
    await requireOwner(body);
    const u = chain.registerUser(String(body.username ?? ""), String(body.password ?? ""));
    note("auth", `Chain-Konto ${u.username} angelegt`);
    return u;
  },
  "POST /api/admin/node-users/password": async (_, body) => {
    await requireOwner(body);
    const r = chain.setUserPassword(String(body.username ?? ""), String(body.password ?? ""));
    dropSessionsOf(r.username);
    note("auth", `Neues Passwort für Chain-Konto ${r.username}`);
    return r;
  },
  "POST /api/admin/node-users/level": async (_, body) => {
    await requireOwner(body);
    const r = chain.setUserLevel(String(body.username ?? ""), String(body.level ?? "user"));
    dropSessionsOf(r.username);
    note("auth", `Chain-Konto ${r.username}: Stufe ${r.level}`);
    return r;
  },
  "POST /api/admin/node-users/disable": async (_, body) => {
    await requireOwner(body);
    const r = chain.setUserDisabled(String(body.username ?? ""), body.disabled === true);
    if (r.disabled) dropSessionsOf(r.username);
    note("auth", `Chain-Konto ${r.username} ${r.disabled ? "deaktiviert" : "aktiviert"}`);
    return r;
  },
  "POST /api/admin/node-users/delete": async (_, body) => {
    await requireOwner(body);
    const r = chain.deleteUser(String(body.username ?? ""));
    dropSessionsOf(r.username);
    note("auth", `Chain-Konto ${r.username} gelöscht`);
    return r;
  },
  "POST /api/admin/create-account": async (_, body) => {
    await requireAdminPermission(body, "a:accountsCreate");
    const password = String(body.password ?? "");
    if (password.length < 8) throw new Error("weak_password");
    const r = await settingsSync.createWebsiteAccount(String(body.email ?? ""), String(body.username ?? ""), password);
    note("auth", `Neues Website-Konto angelegt: ${r.username}`);
    return r;
  },
  // QR-Rechnung: Käufer verifizieren (nur Full)
  "POST /api/admin/verified-buyers": async (_, body) => { await requireAdminPermission(body, "a:accounts"); return { ids: await settingsSync.listVerifiedBuyers() }; },
  "POST /api/admin/verify-buyer": async (_, body) => {
    await requireOwner(body);
    const r = await settingsSync.setBuyerVerified(String(body.userId ?? ""), body.verified === true);
    note("auth", `${String(body.name ?? body.userId).slice(0, 40)}: QR-Rechnung ${body.verified === true ? "freigeschaltet" : "gesperrt"}`);
    return r;
  },
  "POST /api/admin/password-reset": async (_, body) => { await requireAdminPermission(body, "a:accounts"); return settingsSync.sendPasswordReset(String(body.userId ?? "")); },
  // Banküberweisungen der Hauptseite (nur Owner)
  "POST /api/bank/orders": async (_, body) => { requirePermission(body, "a:bank"); return { orders: await settingsSync.listBankOrders() }; },
  "POST /api/bank/delete": async (_, body) => {
    requirePermission(body, "a:bank");
    const r = await settingsSync.deleteBankOrders(body.id ? String(body.id) : null);
    note("wallet", body.id ? `Abgelehnte Überweisung ${String(body.reference ?? body.id).slice(0, 20)} gelöscht` : `${r.deleted ?? 0} abgelehnte/stornierte Überweisungen gelöscht`);
    return r;
  },
  "POST /api/bank/decide": async (_, body) => {
    requirePermission(body, "a:bank");
    const result = await settingsSync.decideBankOrder(String(body.id ?? ""), body.paid === true);
    note("wallet", `Überweisung ${String(body.reference ?? body.id).slice(0, 20)}: ${body.paid === true ? "Zahlung bestätigt, GIBB gutgeschrieben" : "abgelehnt"}`);
    void settingsSync.syncAccounts();
    return result;
  },
  "POST /api/website/users": async (_, body) => { requirePermission(body, "a:coins"); return { users: await settingsSync.listWebsiteUsers() }; },
  "POST /api/website/adjust": async (_, body) => {
    requirePermission(body, "a:coins");
    const amount = Math.trunc(Number(body.amount));
    if (!Number.isFinite(amount) || amount === 0) throw new Error("invalid_amount");
    const reason = String(body.reason ?? "").trim().slice(0, 120);
    if (reason.length < 3) throw new Error("reason_required");
    const result = await settingsSync.adjustWebsiteBalance(String(body.userId ?? ""), amount, reason);
    void settingsSync.syncAccounts();
    note("wallet", `${amount > 0 ? "Gutschrift" : "Abzug"} ${Math.abs(amount)} GIBB auf der Hauptseite (${String(body.name ?? body.userId).slice(0, 40)}): ${reason}`);
    return result;
  },
  // Statistik, Bonus für alle und Ankündigung (Full oder Basic mit Recht)
  "POST /api/owner/stats": async (_, body) => {
    await requireAdminPermission(body, "a:stats");
    const days = [7, 30, 90, 365].includes(Number(body.days)) ? Number(body.days) : 30;
    return settingsSync.ownerStats(days);
  },
  "POST /api/website/bulk": async (_, body) => {
    await requireAdminPermission(body, "a:bulk");
    const amount = Math.trunc(Number(body.amount));
    if (!Number.isFinite(amount) || amount < 1 || amount > 10000) throw new Error("invalid_amount");
    const reason = String(body.reason ?? "").trim().slice(0, 120);
    if (reason.length < 3) throw new Error("reason_required");
    const r = await settingsSync.bulkAdjust(amount, reason);
    void settingsSync.syncAccounts();
    note("wallet", `Bonus für alle: ${amount} GIBB an ${r.users ?? 0} Konten (${reason})`);
    return r;
  },
  "POST /api/announcement/get": async (_, body) => { await requireAdminPermission(body, "a:announce"); return { announcement: await settingsSync.getAnnouncement() }; },
  "POST /api/announcement/set": async (_, body) => {
    await requireAdminPermission(body, "a:announce");
    const hours = Number(body.hours);
    const until = Number.isFinite(hours) && hours > 0 ? new Date(Date.now() + Math.min(hours, 24 * 90) * 3600_000).toISOString() : null;
    const r = await settingsSync.setAnnouncement({ enabled: body.enabled === true, title: String(body.title ?? ""), message: String(body.message ?? ""), until, tone: String(body.tone ?? "info") });
    note("settings", body.enabled === true ? `Ankündigung veröffentlicht: ${String(body.title || body.message || "").slice(0, 40)}` : "Ankündigung entfernt");
    return r;
  },
  "POST /api/market/reset-prices": async (_, body) => { await requireOwner(body); const r = chain.resetPrices(1); const website = await settingsSync.push({ price: 1 }); note("settings", "Kurse zurückgesetzt (1 Rp)"); return { ...r, websitePush: website }; },
  "POST /api/reset": async (_, body) => { await requireOwner(body); stopLocalMiner(); chain.reset(); chain.templates.clear(); recentBlocks.length = 0; log.length = 0; note("reset", "Blockchain zurückgesetzt – neuer Genesis-Block"); return chain.stats(); },
};

function summarize(block) {
  return { ...block, transactions: undefined, tx_count: block.transactions.length };
}

// Eigene Website(s), die den Node per Skript aufrufen dürfen (z. B. lokale Entwicklung auf Port 3000).
const ALLOWED_ORIGINS = String(process.env.ALLOWED_ORIGINS ?? "https://gibbcoin-original.duckdns.org,http://localhost:3000,http://127.0.0.1:3000").split(",").map((o) => o.trim()).filter(Boolean);
const staticTypes = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml" };

const requestHandler = async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
  const key = `${req.method} ${url.pathname}`;
  // Fremde Seiten dürfen den Node nicht per Skript aufrufen – nur die eigene Website.
  const origin = String(req.headers.origin ?? "");
  if (origin && ALLOWED_ORIGINS.some((o) => o === origin)) {
    res.setHeader("access-control-allow-origin", origin);
    res.setHeader("vary", "origin");
    res.setHeader("access-control-allow-headers", "content-type");
    res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
  }
  // Schutz-Header: kein Einbetten in fremde Seiten, keine fremden Skripte, keine Weitergabe der Adresse.
  res.setHeader("x-frame-options", "DENY");
  res.setHeader("x-content-type-options", "nosniff");
  res.setHeader("referrer-policy", "no-referrer");
  res.setHeader("permissions-policy", "camera=(), microphone=(), geolocation=(), payment=()");
  res.setHeader("cross-origin-opener-policy", "same-origin");
  res.setHeader("content-security-policy", "default-src 'self'; script-src 'self' 'unsafe-inline' blob:; worker-src 'self' blob:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
  if (req.headers["x-forwarded-proto"] === "https") res.setHeader("strict-transport-security", "max-age=31536000");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  try {
    if (routes[key]) {
      let body = {};
      if (req.method === "POST") {
        const chunks = [];
        let size = 0;
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 1_000_000) return json(res, 413, { error: "request_too_large" });
          chunks.push(chunk);
        }
        const raw = Buffer.concat(chunks).toString("utf8");
        body = raw ? JSON.parse(raw) : {};
        if (!body || typeof body !== "object" || Array.isArray(body)) body = {};
        // Interne Felder setzt nur der Server (nie vom Client übernehmen).
        const forwarded = req.headers["cf-connecting-ip"] || req.headers["x-forwarded-for"];
        const remote = req.socket.remoteAddress ?? "";
        body.__ip = String(forwarded || remote).split(",")[0].trim();
        body.__direct = !forwarded && /^(::1|127\.|::ffff:127\.)/.test(remote);
      }
      const data = await routes[key](url, body);
      return json(res, 200, data);
    }
    if (url.pathname.startsWith("/api/")) return json(res, 404, { error: "not_found" });
    if (url.pathname === "/blockchain-core.js") {
      res.writeHead(200, { "content-type": "text/javascript; charset=utf-8" });
      return res.end(await readFile(join(here, "..", "app", "lib", "blockchain-core.js")));
    }
    const file = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\/+/, "").replace(/\.\./g, "");
    const content = await readFile(join(here, "public", file));
    const ext = file.slice(file.lastIndexOf("."));
    res.writeHead(200, { "content-type": staticTypes[ext] ?? "application/octet-stream" });
    res.end(content);
  } catch (error) {
    if (error.code === "ENOENT") return json(res, 404, { error: "not_found" });
    return json(res, 400, { error: error.message });
  }
};
const server = createServer(requestHandler);

function json(res, status, data) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(data));
}

server.listen(PORT, () => {
  void notifier.send("start", "🟢 Chain-Server gestartet", `Der GIBB-Chain-Server läuft wieder (Blöcke: ${chain.blocks.length}). Das passiert nach einem Update oder Neustart.`, { tags: ["white_check_mark"] });
  console.log(`GIBB Blockchain-Node läuft auf http://localhost:${PORT}  (Blöcke: ${chain.blocks.length}, Konten: ${Object.keys(chain.accounts).length})`);
});

// Optional HTTPS (selbst signiertes oder echtes Zertifikat): HTTPS_PORT + TLS_KEY + TLS_CERT setzen.
if (process.env.HTTPS_PORT && process.env.TLS_KEY && process.env.TLS_CERT) {
  try {
    const tlsServer = createHttpsServer({ key: await readFile(process.env.TLS_KEY), cert: await readFile(process.env.TLS_CERT) }, requestHandler);
    tlsServer.listen(Number(process.env.HTTPS_PORT), () => console.log(`HTTPS läuft auf Port ${process.env.HTTPS_PORT}`));
  } catch (error) { console.error("HTTPS nicht gestartet:", error.message); }
}
