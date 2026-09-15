// Reserve-Miner: läuft im Node-Prozess (z. B. auf dem Server, der beide Websites
// hostet) und produziert nur dann Blöcke, wenn die Kette stillsteht – also kein
// anderer Miner im Netzwerk aktiv ist. Er ist bewusst gedrosselt (ein Thread,
// Pausen zwischen den Versuchen), damit echte Miner immer Vorrang haben und die
// CPU (gerade auf kleinen Gratis-Servern) nicht dauerhaft ausgelastet wird.

import { createHash } from "node:crypto";
import { leadingZeroBits } from "../app/lib/blockchain-core.js";

const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

export function startFallbackMiner(chain, { getAddress, note, batch = 8000, throttleMs = 6 } = {}) {
  const state = { running: false, minedByFallback: 0, lastBlock: null, active: true };

  const idleSeconds = () => Date.now() / 1000 - chain.tip().timestamp;

  const mineOne = async () => {
    if (state.running) return;
    const address = getAddress();
    if (!chain.accounts[address]) return;
    state.running = true;
    try {
      const tpl = chain.issueTemplate(address);
      const prefix = tpl.header_prefix; // alles vor der Nonce
      const startHeight = tpl.height;
      let nonce = 0;
      let hash = "";
      for (;;) {
        if (!state.active) return;
        // Ein anderer Miner war schneller -> abbrechen, echten Minern den Vortritt lassen.
        if (chain.tip().height + 1 !== startHeight) return;
        for (let i = 0; i < batch; i += 1) {
          hash = sha256(prefix + nonce);
          if (leadingZeroBits(hash) >= tpl.difficulty_bits) {
            const block = chain.submit(tpl.id, nonce, hash, { attempts: nonce + 1 });
            state.minedByFallback += 1;
            state.lastBlock = { height: block.height, at: Date.now() };
            note?.(`Reserve-Miner: Block #${block.height} erzeugt (kein anderer Miner aktiv)`);
            return;
          }
          nonce += 1;
        }
        // Drosseln: CPU freigeben, damit der Server ansprechbar bleibt.
        await new Promise((resolve) => setTimeout(resolve, throttleMs));
      }
    } catch {
      // z. B. no_pending_transactions oder stale_block: einfach beim nächsten Tick erneut prüfen.
    } finally {
      state.running = false;
    }
  };

  const tick = async () => {
    if (!state.active) return;
    const s = chain.settings;
    const enabled = s.fallbackMinerEnabled || process.env.FALLBACK_MINER === "1";
    const hasPending = chain.mempool.length > 0;
    if (enabled && hasPending && !state.running && idleSeconds() >= (s.fallbackDelaySeconds ?? 60)) {
      await mineOne();
    }
  };

  const interval = setInterval(() => { void tick(); }, 3000);
  interval.unref?.();

  return {
    status: () => ({ running: state.running, minedByFallback: state.minedByFallback, lastBlock: state.lastBlock, idleSeconds: Math.round(idleSeconds()) }),
    stop: () => { state.active = false; clearInterval(interval); },
  };
}
