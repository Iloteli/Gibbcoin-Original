// HTTP-Server für den GIBB-Blockchain-Node: REST-API + Verwaltungs-Website.
// Start:  node blockchain-node/server.mjs   (Port über PORT, Datei über CHAIN_FILE)

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { availableParallelism } from "node:os";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Blockchain } from "./chain.mjs";
import { loadSupabaseConfig, syncSupabaseAccounts } from "./supabase-sync.mjs";
import { startFallbackMiner } from "./fallback-miner.mjs";

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
const fallbackMiner = startFallbackMiner(chain, { getAddress: () => FALLBACK_ADDRESS, note: (m) => note("block", m) });

// Automatische Spiegelung der Supabase-Konten.
const supabaseSync = { configured: loadSupabaseConfig().configured, lastRun: null, lastResult: null, lastError: null, running: false };
async function runSupabaseSync() {
  if (supabaseSync.running) return supabaseSync.lastResult;
  supabaseSync.running = true;
  try {
    const result = await syncSupabaseAccounts(chain);
    supabaseSync.lastResult = result; supabaseSync.lastRun = Date.now(); supabaseSync.lastError = null;
    if (result.added || result.updated) note("sync", `Supabase-Konten synchronisiert: ${result.added} neu, ${result.updated} aktualisiert (${result.total} gesamt)`);
    return result;
  } catch (error) {
    supabaseSync.lastError = error.message;
    if (error.message !== "supabase_not_configured") note("error", `Supabase-Sync: ${error.message}`);
    throw error;
  } finally {
    supabaseSync.running = false;
  }
}
// Beim Start und danach alle 60 s automatisch spiegeln, sofern konfiguriert.
if (supabaseSync.configured) {
  runSupabaseSync().catch(() => {});
  setInterval(() => { if (loadSupabaseConfig().configured) runSupabaseSync().catch(() => {}); }, 60_000).unref();
}

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
const sessionOf = (body) => (body && body.token && sessions.get(body.token)) || null;
const requireOwner = (body) => { const sess = sessionOf(body); if (!sess || sess.role !== "super_admin") throw new Error("not_owner"); return sess; };

const routes = {
  "GET /api/stats": () => ({ ...chain.stats(), recentBlocks, log, localMiner: localMinerState(), supabaseSync: { ...supabaseSync, configured: loadSupabaseConfig().configured }, fallbackMiner: fallbackMiner.status() }),
  // ---------- Lokale Anmeldung (kein Cloud-Supabase) ----------
  "POST /api/auth/register": (_, body) => {
    const u = chain.registerUser(body.username, body.password);
    const token = _rnd(24).toString("hex");
    sessions.set(token, { address: u.address, username: u.username, role: u.role });
    note("auth", `Neuer Nutzer registriert: ${u.username}${u.role === "super_admin" ? " (Owner)" : ""}`);
    return { token, ...u };
  },
  "POST /api/auth/login": (_, body) => {
    const u = chain.verifyUser(body.username, body.password);
    const token = _rnd(24).toString("hex");
    sessions.set(token, { address: u.address, username: u.username, role: u.role });
    return { token, ...u };
  },
  "POST /api/auth/me": (_, body) => {
    const sess = sessionOf(body);
    if (!sess) return { ok: false };
    const acc = chain.accounts[sess.address] || {};
    return { ok: true, ...sess, balance: acc.balance ?? 0, cash: acc.cash ?? 0 };
  },
  "POST /api/sync-supabase": async (_, body) => {
    try { requireOwner(body); } catch { return { ok: false, error: "not_owner" }; }
    try { return { ok: true, ...(await runSupabaseSync()) }; }
    catch (error) { return { ok: false, error: error.message }; }
  },
  // Miner-Prozess auf diesem Rechner starten/stoppen (alle Kerne, so viele Blöcke wie möglich).
  "POST /api/local-miner": (_, body) => { requireOwner(body); return body.enabled ? startLocalMiner(body.address, body.threads) : stopLocalMiner(); },
  // Von der echten Website: aktuelles Konto anmelden, damit es hier erscheint.
  "POST /api/register": (_, body) => {
    const acc = chain.upsertWebsiteAccount(body.supabaseId, body.name, Number(body.balance));
    note("sync", `Konto von der Website angemeldet: ${acc.name} (${acc.address})`);
    return { address: acc.address, name: acc.name, balance: acc.balance, cash: acc.cash };
  },
  // Von einem Admin der Website: alle Nutzer auf einmal übernehmen.
  "POST /api/register-many": (_, body) => {
    requireOwner(body);
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
  "GET /api/accounts": () => Object.entries(chain.accounts).map(([address, a]) => ({ address, ...a, available: chain.availableBalance(address), availableCash: chain.availableCash(address) })).sort((x, y) => y.balance - x.balance),
  "GET /api/market": (url) => chain.market(url.searchParams.get("address")),
  "POST /api/order": (_, body) => {
    const r = chain.placeOrder(body.address, body.side, body.price, body.amount);
    note("market", `${chain.accounts[body.address]?.name ?? body.address}: ${body.side === "buy" ? "Kauf" : "Verkauf"} ${body.amount} GIBB zu ${body.price} Rp${r.fills.length ? ` – ${r.fills.length} Handel, Kurs ${r.price} Rp` : " (im Buch)"}`);
    return r;
  },
  "POST /api/order-cancel": (_, body) => chain.cancelOrder(body.address, body.order_id),
  "GET /api/verify": () => chain.verify(),
  "POST /api/wallets": (_, body) => chain.createWallet(body.name),
  "POST /api/transactions": (_, body) => {
    const sess = sessionOf(body);
    const from = sess ? sess.address : body.from; // eingeloggt: nur vom eigenen Konto senden
    if (sess && body.from && body.from !== sess.address) throw new Error("not_your_account");
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
      note("block", `Block #${block.height} von ${block.miner_label} gefunden (${block.attempts ?? "?"} Versuche, ${block.mining_ms ?? "?"} ms, ${block.difficulty_bits} Bit)`);
      return summarize(block);
    } catch (error) {
      if (error.message !== "stale_block") note("error", `Block abgelehnt: ${error.message}`);
      throw error;
    }
  },
  "POST /api/settings": (_, body) => { requireOwner(body); const s = chain.updateSettings(body); note("settings", `Einstellungen geändert: Belohnung ${s.reward}, Schwierigkeit ${s.difficultyBits} Bit${s.autoAdjust ? " (auto)" : ""}, Ziel ${s.targetSeconds} s`); return s; },
  "POST /api/tamper": (_, body) => { requireOwner(body); const r = chain.tamper(body.height); note("tamper", `Demo: Block #${r.height} manipuliert (Transaktion ${r.transaction})`); return r; },
  "POST /api/reset": (_, body) => { requireOwner(body); stopLocalMiner(); chain.reset(); chain.templates.clear(); recentBlocks.length = 0; log.length = 0; note("reset", "Blockchain zurückgesetzt – neuer Genesis-Block"); return chain.stats(); },
};

function summarize(block) {
  return { ...block, transactions: undefined, tx_count: block.transactions.length };
}

const staticTypes = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml" };

const server = createServer(async (req, res) => {
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
        for await (const chunk of req) chunks.push(chunk);
        const raw = Buffer.concat(chunks).toString("utf8");
        body = raw ? JSON.parse(raw) : {};
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
});

function json(res, status, data) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(data));
}

server.listen(PORT, () => {
  console.log(`GIBB Blockchain-Node läuft auf http://localhost:${PORT}  (Blöcke: ${chain.blocks.length}, Konten: ${Object.keys(chain.accounts).length})`);
});
