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

// Der Server mined nicht: Browser holen Vorlagen und reichen gefundene Nonces ein.
const recentBlocks = [];
const log = [];
function note(kind, message) {
  log.unshift({ at: Date.now(), kind, message });
  log.length = Math.min(log.length, 60);
}

// ---------- API ----------
const routes = {
  "GET /api/stats": () => ({ ...chain.stats(), recentBlocks, log }),
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
  "POST /api/settings": (_, body) => { const s = chain.updateSettings(body); note("settings", `Einstellungen geändert: Belohnung ${s.reward}, Schwierigkeit ${s.difficultyBits} Bit${s.autoAdjust ? " (auto)" : ""}, Ziel ${s.targetSeconds} s`); return s; },
  "POST /api/tamper": (_, body) => { const r = chain.tamper(body.height); note("tamper", `Demo: Block #${r.height} manipuliert (Transaktion ${r.transaction})`); return r; },
  "POST /api/reset": () => { chain.reset(); chain.templates.clear(); recentBlocks.length = 0; log.length = 0; note("reset", "Blockchain zurückgesetzt – neuer Genesis-Block"); return chain.stats(); },
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
