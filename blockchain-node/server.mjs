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
// Anmelde-Sitzungen: token -> { address, username, role }. Nur im Speicher.
import { randomBytes as _rnd } from "node:crypto";
const sessions = new Map();
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // Sitzungen laufen nach 12 Stunden ab
const newSession = (u) => {
  const token = _rnd(32).toString("hex");
  sessions.set(token, { address: u.address, username: u.username, role: u.role, expires: Date.now() + SESSION_TTL_MS });
  return token;
};
setInterval(() => { const now = Date.now(); for (const [t, s] of sessions) if (s.expires < now) sessions.delete(t); }, 60_000).unref();

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
  const sess = body && typeof body.token === "string" ? sessions.get(body.token) : null;
  if (sess && sess.expires > Date.now()) return sess;
  if (sess) sessions.delete(body.token);
  return NO_AUTH && body?.__direct === true ? getGuest() : null;
};
const requireSession = (body) => { const sess = sessionOf(body); if (!sess) throw new Error("login_required"); return sess; };
const websiteOwnerSession = createWebsiteOwnerCheck();
// Owner: Node-Login (token) ODER Owner der GibbCoin-Website (supabaseToken, geprüft bei der eigenen Datenbank).
const requireOwner = async (body) => {
  const sess = sessionOf(body);
  if (sess && sess.role === "super_admin") return sess;
  const web = await websiteOwnerSession(body?.supabaseToken);
  if (web) return web;
  throw new Error("not_owner");
};

const routes = {
  "GET /api/stats": () => ({ ...chain.stats(), recentBlocks, log, localMiner: localMinerState(), walletCredit: { enabled: walletCredit.enabled, pending: walletCredit.pendingCount() }, fallbackMiner: fallbackMiner.status() }),
  // ---------- Lokale Anmeldung (kein Cloud-Supabase) ----------
  "POST /api/auth/register": (_, body) => {
    const ipKey = `ip:${body.__ip}`;
    if (loginBlocked(ipKey)) throw new Error("too_many_attempts");
    let u;
    try { u = chain.registerUser(body.username, body.password, { setupCode: body.setupCode }); }
    catch (error) { if (error.message === "owner_name_reserved") loginFailed(ipKey); throw error; }
    const token = newSession(u);
    note("auth", `Neuer Nutzer registriert: ${u.username}${u.role === "super_admin" ? " (Owner)" : ""}`);
    return { token, ...u };
  },
  "POST /api/auth/login": (_, body) => {
    const nameKey = `name:${String(body.username ?? "").trim().toLowerCase()}`;
    const ipKey = `ip:${body.__ip}`;
    if (loginBlocked(nameKey, ipKey)) throw new Error("too_many_attempts");
    let u;
    try { u = chain.verifyUser(body.username, body.password, { setupCode: body.setupCode }); }
    catch (error) { loginFailed(nameKey, ipKey); throw error; }
    loginFailures.delete(nameKey);
    const token = newSession(u);
    return { token, ...u };
  },
  "POST /api/auth/logout": (_, body) => {
    if (typeof body.token === "string") sessions.delete(body.token);
    return { ok: true };
  },
  "POST /api/auth/me": (_, body) => {
    const sess = sessionOf(body);
    if (!sess) return { ok: false };
    const acc = chain.accounts[sess.address] || {};
    return { ok: true, ...sess, balance: acc.balance ?? 0, cash: acc.cash ?? 0 };
  },
  // Miner-Prozess auf diesem Rechner starten/stoppen (alle Kerne, so viele Blöcke wie möglich).
  "POST /api/local-miner": async (_, body) => { await requireOwner(body); return body.enabled ? startLocalMiner(body.address, body.threads) : stopLocalMiner(); },
  // Von der echten Website: aktuelles Konto anmelden, damit es hier erscheint.
  // Nur mit gültigem Website-Login und nur für das eigene Konto. Ein vom Browser geschicktes
  // Guthaben wird NICHT übernommen (sonst könnte sich jeder Coins geben).
  "POST /api/register": async (_, body) => {
    const user = await websiteUser(body?.supabaseToken);
    if (!user) throw new Error("login_required");
    if (body.supabaseId && body.supabaseId !== user.userId) throw new Error("not_your_account");
    const acc = chain.upsertWebsiteAccount(user.userId, user.username, 0);
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
    return { id: t.id, height: t.height, previous_hash: t.previous_hash, merkle_root: t.merkle_root, timestamp: t.timestamp, difficulty_bits: t.difficulty_bits, miner_user_id: t.miner_user_id, tx_count: t.transactions.length, tx_hashes: t.transactions.map((tx) => tx.hash), reward: chain.settings.reward, header_prefix: t.header_prefix };
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
  "POST /api/settings": async (_, body) => { await requireOwner(body); const s = chain.updateSettings(body); note("settings", `Einstellungen geändert: Belohnung ${s.reward}, Schwierigkeit ${s.difficultyBits} Bit${s.autoAdjust ? " (auto)" : ""}, Ziel ${s.targetSeconds} s`); return s; },
  "POST /api/tamper": async (_, body) => { await requireOwner(body); const r = chain.tamper(body.height); note("tamper", `Demo: Block #${r.height} manipuliert (Transaktion ${r.transaction})`); return r; },
  "POST /api/reset": async (_, body) => { await requireOwner(body); stopLocalMiner(); chain.reset(); chain.templates.clear(); recentBlocks.length = 0; log.length = 0; note("reset", "Blockchain zurückgesetzt – neuer Genesis-Block"); return chain.stats(); },
};

function summarize(block) {
  return { ...block, transactions: undefined, tx_count: block.transactions.length };
}

const staticTypes = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml" };

const requestHandler = async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
  const key = `${req.method} ${url.pathname}`;
  // Die echte Website (anderer Port) darf den lokalen Node aufrufen.
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-headers", "content-type");
  res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
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
  console.log(`GIBB Blockchain-Node läuft auf http://localhost:${PORT}  (Blöcke: ${chain.blocks.length}, Konten: ${Object.keys(chain.accounts).length})`);
});

// Optional HTTPS (selbst signiertes oder echtes Zertifikat): HTTPS_PORT + TLS_KEY + TLS_CERT setzen.
if (process.env.HTTPS_PORT && process.env.TLS_KEY && process.env.TLS_CERT) {
  try {
    const tlsServer = createHttpsServer({ key: await readFile(process.env.TLS_KEY), cert: await readFile(process.env.TLS_CERT) }, requestHandler);
    tlsServer.listen(Number(process.env.HTTPS_PORT), () => console.log(`HTTPS läuft auf Port ${process.env.HTTPS_PORT}`));
  } catch (error) { console.error("HTTPS nicht gestartet:", error.message); }
}
