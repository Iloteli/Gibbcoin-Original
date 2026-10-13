// Server-Mining: Nutzer der Website können Mining auf dem Server einschalten. Der Server
// mint dann reihum je einen Block für jedes eingeschaltete Konto – auch wenn der
// Browser-Tab geschlossen ist. Gedrosselt (ein Thread, kurze Pausen), damit echte Miner
// Vorrang haben und der Server ansprechbar bleibt. Die Liste übersteht Neustarts.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { leadingZeroBits } from "../app/lib/blockchain-core.js";

const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

export function startServerMining(chain, { file, onBlock, note, batch = 4000, throttleMs = 15 } = {}) {
  const miners = new Map(); // address -> { name, since, blocks }
  if (file && existsSync(file)) {
    try {
      for (const [address, info] of Object.entries(JSON.parse(readFileSync(file, "utf8")))) miners.set(address, info);
    } catch { /* kaputte Datei: leer starten */ }
  }
  const save = () => { if (file) { try { writeFileSync(file, JSON.stringify(Object.fromEntries(miners))); } catch { /* ignorieren */ } } };
  const state = { active: true, running: false, current: null, turn: 0, hashrate: 0, lastError: null };

  const nextAddress = () => {
    const list = [...miners.keys()].filter((a) => chain.accounts[a]);
    if (!list.length) return null;
    state.turn = (state.turn + 1) % list.length;
    return list[state.turn];
  };

  const mineOne = async (address) => {
    state.running = true;
    state.current = address;
    try {
      const tpl = chain.issueTemplate(address);
      const startHeight = tpl.height;
      const started = Date.now();
      let nonce = 0;
      for (;;) {
        if (!state.active || !miners.has(address)) return;
        if (chain.tip().height + 1 !== startHeight) return; // jemand anderes war schneller
        for (let i = 0; i < batch; i += 1) {
          const hash = sha256(tpl.header_prefix + nonce);
          if (leadingZeroBits(hash) >= tpl.difficulty_bits) {
            const ms = Date.now() - started;
            const block = chain.submit(tpl.id, nonce, hash, { attempts: nonce + 1, ms, hashrate: Math.round((nonce + 1) / Math.max(ms / 1000, 0.001)) });
            const info = miners.get(address);
            if (info) { info.blocks = (info.blocks ?? 0) + 1; info.lastBlockAt = Date.now(); save(); }
            note?.(`Server-Mining: Block #${block.height} für ${block.miner_label}`);
            onBlock?.(block);
            return;
          }
          nonce += 1;
        }
        state.hashrate = Math.round(nonce / Math.max((Date.now() - started) / 1000, 0.001));
        await new Promise((resolve) => setTimeout(resolve, throttleMs));
      }
    } catch (error) {
      // z. B. stale_block: beim nächsten Durchgang erneut
      state.lastError = error?.message ?? String(error);
      return "error";
    } finally {
      state.running = false;
      state.current = null;
    }
  };

  const loop = async () => {
    while (state.active) {
      const address = !state.running && miners.size ? nextAddress() : null;
      const outcome = address ? await mineOne(address) : "idle";
      // Immer kurz abgeben (sonst blockiert eine sofort scheiternde Runde den ganzen Prozess).
      await new Promise((resolve) => setTimeout(resolve, outcome === "idle" ? 2000 : outcome === "error" ? 1000 : throttleMs));
    }
  };
  void loop();

  return {
    enable(address, name) {
      if (!chain.accounts[address]) throw new Error("unknown_miner");
      if (!miners.has(address)) { miners.set(address, { name, since: Date.now(), blocks: 0 }); save(); }
      return this.status(address);
    },
    disable(address) {
      if (miners.delete(address)) save();
      return this.status(address);
    },
    status(address) {
      const info = address ? miners.get(address) : null;
      return {
        enabled: Boolean(info), blocks: info?.blocks ?? 0, since: info?.since ?? null,
        activeMiners: miners.size, miningNow: state.current === address && Boolean(address), hashrate: state.hashrate, lastError: state.lastError ?? null,
      };
    },
    stop() { state.active = false; },
  };
}
