// Lokaler GIBB-Miner: läuft auf deinem PC, nutzt alle Prozessorkerne und
// redet mit einem Blockchain-Node über /api/template und /api/submit.
//
//   node blockchain-node/miner.mjs --wallet Gxxxxxxxxxxxx [--server http://localhost:8787] [--threads 4] [--name Lea]
//
// Ohne --wallet wird ein neues Wallet auf dem Server angelegt (Name über --name).
// Mit --json schreibt der Miner eine JSON-Zeile pro Ereignis (für die Website, die ihn startet).

import { createHash } from "node:crypto";
import { availableParallelism } from "node:os";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { blockHeaderString, leadingZeroBits, merkleRoot } from "../app/lib/blockchain-core.js";

// ---------- Worker: sucht in seinem Nonce-Bereich ----------
if (!isMainThread) {
  const { prefix, difficultyBits, start, step } = workerData;
  let nonce = start;
  let count = 0;
  const tick = () => {
    for (let i = 0; i < 50_000; i += 1) {
      const hash = createHash("sha256").update(prefix + nonce, "utf8").digest("hex");
      count += 1;
      if (leadingZeroBits(hash) >= difficultyBits) {
        parentPort.postMessage({ type: "found", nonce, hash, count });
        return;
      }
      nonce += step;
    }
    parentPort.postMessage({ type: "progress", count });
    count = 0;
    setImmediate(tick);
  };
  tick();
}

// ---------- Hauptprogramm ----------
if (isMainThread) {
  const args = parseArgs(process.argv.slice(2));
  const server = (args.server ?? "http://localhost:8787").replace(/\/$/, "");
  const threads = Math.max(1, Number(args.threads ?? availableParallelism()));
  let wallet = args.wallet;
  const jsonMode = args.json === "true";
  const emit = (event) => { if (jsonMode) console.log(JSON.stringify(event)); };
  const out = (text) => { if (!jsonMode) process.stdout.write(text); };

  const api = async (path, body) => {
    const res = await fetch(server + path, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : undefined);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error ?? `http_${res.status}`);
    return data;
  };

  out(`GIBB-Miner · Server ${server} · ${threads} Thread(s)\n`);
  emit({ event: "start", server, threads });
  try { await api("/api/stats"); } catch { console.error("Server nicht erreichbar. Läuft der Node? (pnpm chain)"); process.exit(1); }

  if (!wallet) {
    const created = await api("/api/wallets", { name: args.name ?? `Miner ${process.env.COMPUTERNAME ?? process.env.HOSTNAME ?? "PC"}` });
    wallet = created.address;
    out(`Neues Wallet angelegt: ${created.name} → ${wallet}  (beim nächsten Start mit --wallet ${wallet} weiterverwenden)\n`);
    emit({ event: "wallet", address: wallet, name: created.name });
  }

  let stop = false;
  process.on("SIGINT", () => { stop = true; out("\nStoppe …\n"); });
  process.on("SIGTERM", () => { stop = true; });
  let blocksFound = 0;
  let earned = 0;

  while (!stop) {
    let template;
    try { template = await api("/api/template", { address: wallet }); }
    catch (error) {
      console.error(`Vorlage fehlgeschlagen: ${error.message}`);
      emit({ event: "waiting", reason: error.message });
      if (error.message === "unknown_miner") process.exit(1);
      await sleep(3000); continue;
    }
    const prefix = `${template.height}|${template.previous_hash}|${template.merkle_root}|${template.timestamp}|${template.difficulty_bits}|${template.miner_user_id}|`;
    if (merkleRoot(template.tx_hashes) !== template.merkle_root || prefix !== template.header_prefix) {
      console.error("Server-Vorlage stimmt nicht mit der lokalen Berechnung überein – Abbruch."); process.exit(1);
    }
    const expected = 2 ** template.difficulty_bits;
    out(`Block #${template.height} · ${template.difficulty_bits} Bit (~${expected.toLocaleString("de-CH")} Versuche) · ${template.tx_count} Tx · Belohnung ${template.reward} GIBB\n`);
    emit({ event: "template", height: template.height, difficulty_bits: template.difficulty_bits, tx_count: template.tx_count, reward: template.reward });

    const result = await mineTemplate(prefix, template.difficulty_bits, threads, () => stop, template, api, { out, emit });
    if (!result) continue; // gestoppt oder Vorlage veraltet
    const { nonce, hash, attempts, ms } = result;
    const hashrate = attempts / Math.max(1, ms) * 1000;
    const header = { ...template, nonce };
    if (createHash("sha256").update(blockHeaderString(header), "utf8").digest("hex") !== hash) { console.error("Lokale Gegenprüfung fehlgeschlagen."); continue; }
    try {
      const block = await api("/api/submit", { template_id: template.id, nonce, hash, attempts, ms, hashrate });
      blocksFound += 1; earned += block.reward;
      out(`  ✔ Block #${block.height} gefunden: ${hash.slice(0, 20)}… · Nonce ${nonce.toLocaleString("de-CH")} · ${attempts.toLocaleString("de-CH")} Versuche in ${(ms / 1000).toFixed(1)} s (${(hashrate / 1000).toFixed(0)} kH/s) · +${block.reward} GIBB  [gesamt ${blocksFound} Blöcke, ${earned} GIBB]\n`);
      emit({ event: "block", height: block.height, hash, attempts, ms, hashrate, reward: block.reward, total_blocks: blocksFound, total_reward: earned });
    } catch (error) {
      out(`  ✖ Block abgelehnt: ${error.message}${error.message === "stale_block" ? " (jemand war schneller)" : ""}\n`);
      emit({ event: "rejected", reason: error.message });
    }
  }
  out(`Fertig: ${blocksFound} Blöcke, ${earned} GIBB verdient.\n`);
  emit({ event: "stop", total_blocks: blocksFound, total_reward: earned });
}

// Startet die Worker, bricht ab, wenn ein neuer Block auftaucht oder die Vorlage alt wird.
function mineTemplate(prefix, difficultyBits, threads, shouldStop, template, api, { out, emit }) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let attempts = 0;
    let done = false;
    const workers = [];
    const finish = (value) => {
      if (done) return;
      done = true;
      clearInterval(watch);
      for (const w of workers) w.terminate();
      resolve(value);
    };
    for (let i = 0; i < threads; i += 1) {
      const worker = new Worker(fileURLToPath(import.meta.url), { workerData: { prefix, difficultyBits, start: i, step: threads } });
      worker.on("message", (m) => {
        if (m.type === "progress") { attempts += m.count; return; }
        if (m.type === "found") { attempts += m.count; finish({ nonce: m.nonce, hash: m.hash, attempts, ms: Date.now() - startedAt }); }
      });
      worker.on("error", (error) => { console.error("Worker-Fehler:", error.message); finish(null); });
      workers.push(worker);
    }
    // Alle 2 s: Fortschritt zeigen, Stopp/Kettenänderung/Vorlagenalter prüfen.
    const watch = setInterval(async () => {
      if (shouldStop()) return finish(null);
      const elapsed = (Date.now() - startedAt) / 1000;
      const rate = attempts / Math.max(0.5, elapsed);
      out(`  ${attempts.toLocaleString("de-CH")} Versuche · ${(rate / 1000).toFixed(0)} kH/s · ${elapsed.toFixed(0)} s · ${Math.min(999, Math.round(attempts / 2 ** difficultyBits * 100))} % des Erwartungswerts\r`);
      emit({ event: "progress", attempts, hashrate: rate, elapsed, expected: 2 ** difficultyBits });
      if (elapsed > 540) { out("\n  Vorlage zu alt, hole eine neue.\n"); return finish(null); }
      try {
        const stats = await api("/api/stats");
        if (stats.height + 1 !== template.height) { out(`\n  Block #${stats.height} wurde von jemand anderem gefunden – neue Vorlage.\n`); finish(null); }
      } catch { /* Server kurz nicht erreichbar: weiterrechnen */ }
    }, 2000);
  });
}

function parseArgs(list) {
  const out = {};
  for (let i = 0; i < list.length; i += 1) {
    if (list[i].startsWith("--")) { const key = list[i].slice(2); const value = list[i + 1] && !list[i + 1].startsWith("--") ? list[++i] : "true"; out[key] = value; }
  }
  return out;
}
// Als Funktion (nicht const): wird schon in der Hauptschleife oben gebraucht.
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
