// HTTP-Server für den GIBB-Blockchain-Node: REST-API + Verwaltungs-Website.
// Start:  node blockchain-node/server.mjs   (Port über PORT, Datei über CHAIN_FILE)

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Blockchain } from "./chain.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT ?? 8787);
const chain = new Blockchain(process.env.CHAIN_FILE ?? join(here, "data", "chain.json"));

// Mining-Zustand des Servers (ein Miner gleichzeitig, optional Dauerbetrieb).
const miner = { running: false, auto: false, address: null, progress: null, lastError: null, found: [] };
const log = [];
function note(kind, message) {
  log.unshift({ at: Date.now(), kind, message });
  log.length = Math.min(log.length, 60);
}

async function mineOnce(address) {
  if (miner.running) throw new Error("miner_busy");
  miner.running = true;
  miner.address = address;
  miner.lastError = null;
  try {
    const block = await chain.mine(address, { onProgress: (p) => { miner.progress = p; } });
    miner.found.unshift({ height: block.height, hash: block.hash, attempts: block.attempts, ms: block.mining_ms });
    miner.found.length = Math.min(miner.found.length, 12);
    note("block", `Block #${block.height} von ${block.miner_label} gefunden (${block.attempts} Versuche, ${block.mining_ms} ms, ${block.difficulty_bits} Bit)`);
    return block;
  } catch (error) {
    miner.lastError = error.message;
    note("error", `Mining fehlgeschlagen: ${error.message}`);
    throw error;
  } finally {
    miner.running = false;
    miner.progress = null;
  }
}

async function autoLoop() {
  while (miner.auto) {
    try { await mineOnce(miner.address); } catch { await sleep(1500); }
    await sleep(300);
  }
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------- API ----------
const routes = {
  "GET /api/stats": () => ({ ...chain.stats(), miner: { running: miner.running, auto: miner.auto, address: miner.address, progress: miner.progress, lastError: miner.lastError, found: miner.found }, log }),
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
  "GET /api/accounts": () => Object.entries(chain.accounts).map(([address, a]) => ({ address, ...a, available: chain.availableBalance(address) })).sort((x, y) => y.balance - x.balance),
  "GET /api/verify": () => chain.verify(),
  "POST /api/wallets": (_, body) => chain.createWallet(body.name),
  "POST /api/transactions": (_, body) => {
    const tx = chain.addTransaction(body.from, body.to, body.amount, body.note);
    note("tx", `${chain.accounts[tx.from].name} → ${chain.accounts[tx.to].name}: ${tx.amount} GIBB im Mempool`);
    return tx;
  },
  "POST /api/mine": async (_, body) => {
    const block = await mineOnce(body.address);
    return summarize(block);
  },
  "POST /api/auto-mine": (_, body) => {
    if (body.enabled) {
      if (!chain.accounts[body.address]) throw new Error("unknown_miner");
      if (!miner.auto) { miner.auto = true; miner.address = body.address; note("miner", `Dauer-Mining gestartet für ${chain.accounts[body.address].name}`); void autoLoop(); }
    } else if (miner.auto) { miner.auto = false; note("miner", "Dauer-Mining gestoppt"); }
    return { auto: miner.auto, address: miner.address };
  },
  "POST /api/settings": (_, body) => { const s = chain.updateSettings(body); note("settings", `Einstellungen geändert: Belohnung ${s.reward}, Schwierigkeit ${s.difficultyBits} Bit${s.autoAdjust ? " (auto)" : ""}, Ziel ${s.targetSeconds} s`); return s; },
  "POST /api/tamper": (_, body) => { const r = chain.tamper(body.height); note("tamper", `Demo: Block #${r.height} manipuliert (Transaktion ${r.transaction})`); return r; },
  "POST /api/reset": () => { miner.auto = false; chain.reset(); miner.found = []; log.length = 0; note("reset", "Blockchain zurückgesetzt – neuer Genesis-Block"); return chain.stats(); },
};

function summarize(block) {
  return { ...block, transactions: undefined, tx_count: block.transactions.length };
}

const staticTypes = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml" };

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
  const key = `${req.method} ${url.pathname}`;
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
