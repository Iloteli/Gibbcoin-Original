"use client";

// Browser-Miner für die Hauptseite (echte GibbCoin-Website): mint für das aktuell
// angemeldete Konto direkt im Browser-Tab – OHNE Installation auf dem PC. Ein Web
// Worker sucht die Nonce, der Blockchain-Node prüft den Block und schreibt die
// Belohnung gut. Erreichbar sein muss nur ein Node (lokal oder gehostet); auf dem
// Gerät des Nutzers wird nichts installiert.

import { useCallback, useEffect, useRef, useState } from "react";
import { blockHash, meetsDifficulty, merkleRoot, minerWorkerSource } from "../lib/blockchain-core";

// Standard-Node-Adresse: gleiche Domain wie die Website, Port 8787. So funktioniert
// es lokal (localhost) und auf einem echten Server automatisch für alle Besucher.
const DEFAULT_NODE = typeof window !== "undefined" && window.location?.hostname
  ? `${window.location.protocol}//${window.location.hostname}:8787`
  : "http://localhost:8787";
const NODE_KEY = "gibb-node-url";
const TEMPLATE_REFRESH_MS = 45_000;

type Template = {
  id: string; height: number; previous_hash: string; merkle_root: string; timestamp: number;
  difficulty_bits: number; miner_user_id: string; tx_count: number; tx_hashes: string[]; reward: number; header_prefix: string;
};

const retryable = new Set(["stale_block", "unknown_template", "difficulty_too_low", "insufficient_work", "no_pending_transactions", "mining_cooldown"]);

function initialNode() {
  try { return localStorage.getItem(NODE_KEY) || DEFAULT_NODE; } catch { return DEFAULT_NODE; }
}
function fmt(v: number) { return Math.round(v || 0).toLocaleString("de-CH"); }

export function BrowserMinerCard({ userId, name, balance }: { userId: string; name: string; balance: number }) {
  const [node] = useState(initialNode);
  const [online, setOnline] = useState<boolean | null>(null);
  const [running, setRunning] = useState(false);
  const [hashrate, setHashrate] = useState(0);
  const [hashes, setHashes] = useState(0);
  const [blocks, setBlocks] = useState(0);
  const [nodeBalance, setNodeBalance] = useState<number | null>(null);
  const [difficulty, setDifficulty] = useState<number | null>(null);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [flash, setFlash] = useState(false);
  const [cores, setCores] = useState(0);

  const m = useRef({ want: false, workers: [] as Worker[], workerUrl: null as string | null, template: null as Template | null, startedAt: 0, hashes: 0, timer: 0 as number });
  const coresRef = useRef(0); // 0 = alle Kerne des Geräts
  const startRoundRef = useRef<() => Promise<void>>(async () => {});

  // Wie viele Kerne der Browser-Miner nutzt: Node-Einstellung (0 = alle) begrenzt auf das Gerät.
  const threadCount = () => {
    const hw = typeof navigator !== "undefined" && navigator.hardwareConcurrency ? navigator.hardwareConcurrency : 4;
    const wanted = coresRef.current > 0 ? coresRef.current : hw;
    return Math.max(1, Math.min(hw, wanted));
  };

  const call = useCallback(async (path: string, body?: unknown) => {
    const res = await fetch(node + path, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : undefined);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data as { error?: string }).error || `http_${res.status}`);
    return data;
  }, [node]);

  // Konto anmelden (erscheint dadurch auch auf der Blockchain-Website) + Status pollen.
  useEffect(() => {
    let active = true;
    let registered = false;
    const poll = async () => {
      try {
        if (!registered) { await call("/api/register", { supabaseId: userId, name, balance }); registered = true; }
        const s = await call(`/api/miner-status?address=${encodeURIComponent(`sb_${userId}`)}`) as { account: { balance: number } | null };
        if (!active) return;
        setOnline(true);
        setNodeBalance(s.account?.balance ?? null);
        try {
          const stats = await call("/api/stats") as { settings?: { browserMinerThreads?: number } };
          coresRef.current = Number(stats.settings?.browserMinerThreads) || 0;
          setCores(threadCount());
        } catch { /* Standardwert behalten */ }
      } catch { if (active) setOnline(false); }
    };
    void poll();
    const interval = window.setInterval(poll, 2500);
    return () => { active = false; window.clearInterval(interval); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId, name, balance, node]);

  const stopWorker = useCallback(() => {
    for (const w of m.current.workers) { w.postMessage({ type: "stop" }); w.terminate(); }
    m.current.workers = [];
    if (m.current.workerUrl) { URL.revokeObjectURL(m.current.workerUrl); m.current.workerUrl = null; }
    if (m.current.timer) { window.clearTimeout(m.current.timer); m.current.timer = 0; }
  }, []);

  const stop = useCallback((text?: string) => {
    m.current.want = false;
    stopWorker();
    m.current.template = null;
    setRunning(false);
    setHashrate(0);
    if (text) setMessage(text);
  }, [stopWorker]);

  const startRound = useCallback(async () => {
    if (!m.current.want) return;
    stopWorker();
    setError("");
    let t: Template;
    try { t = await call("/api/template", { address: `sb_${userId}` }) as Template; }
    catch (e) {
      const code = e instanceof Error ? e.message : "";
      if (retryable.has(code) && m.current.want) { setMessage(code === "no_pending_transactions" ? "Warte auf Transaktionen, die in einen Block kommen …" : "Kette hat sich geändert – neue Vorlage …"); m.current.timer = window.setTimeout(() => void startRoundRef.current(), 4000); return; }
      stop(); setError("Node nicht erreichbar. Läuft ein Blockchain-Node?"); return;
    }
    if (!m.current.want) return;
    // Lokale Gegenprüfung: Merkle-Root und Header müssen mit dem Server übereinstimmen.
    const prefix = `${t.height}|${t.previous_hash}|${t.merkle_root}|${t.timestamp}|${t.difficulty_bits}|${t.miner_user_id}|`;
    if (merkleRoot(t.tx_hashes) !== t.merkle_root || prefix !== t.header_prefix) { stop(); setError("Lokale Berechnung weicht vom Server ab."); return; }
    m.current.template = t;
    m.current.startedAt = Date.now();
    m.current.hashes = 0;
    setDifficulty(t.difficulty_bits);
    setRunning(true);

    const count = threadCount();
    setCores(count);
    m.current.workerUrl = URL.createObjectURL(new Blob([minerWorkerSource()], { type: "text/javascript" }));
    const onMessage = async (event: MessageEvent<{ type: string; nonce: number; hashes?: number; hash?: string }>) => {
      const msg = event.data;
      if (m.current.template !== t) return;
      if (msg.type === "progress") {
        m.current.hashes += msg.hashes ?? 0;
        setHashes(m.current.hashes);
        const elapsed = (Date.now() - m.current.startedAt) / 1000;
        if (elapsed > 0.5) setHashrate(m.current.hashes / elapsed);
        return;
      }
      if (msg.type === "found" && msg.hash) {
        stopWorker();
        const header = { height: t.height, previous_hash: t.previous_hash, merkle_root: t.merkle_root, timestamp: t.timestamp, difficulty_bits: t.difficulty_bits, miner_user_id: t.miner_user_id, nonce: msg.nonce };
        if (blockHash(header) !== msg.hash || !meetsDifficulty(msg.hash, t.difficulty_bits)) { stop("Gefundener Block hat die lokale Prüfung nicht bestanden."); return; }
        try {
          const block = await call("/api/submit", { template_id: t.id, nonce: msg.nonce, hash: msg.hash, attempts: msg.nonce + 1, ms: Date.now() - m.current.startedAt }) as { height: number; reward: number };
          setBlocks((b) => b + 1);
          setFlash(true);
          window.setTimeout(() => setFlash(false), 1400);
          setMessage(`✔ Block #${block.height} gefunden – +${block.reward} GIBB auf dein Konto.`);
          if (m.current.want) void startRoundRef.current();
        } catch (e) {
          const code = e instanceof Error ? e.message : "";
          if (retryable.has(code) && m.current.want) { setMessage("Jemand war schneller – neue Vorlage …"); void startRoundRef.current(); }
          else { stop(); setError("Block konnte nicht eingereicht werden."); }
        }
      }
    };
    // Ein Worker pro Kern, jeder durchsucht einen versetzten Nonce-Bereich (Schrittweite = Kernzahl).
    for (let i = 0; i < count; i += 1) {
      const worker = new Worker(m.current.workerUrl);
      worker.onmessage = onMessage;
      worker.onerror = () => stop("Der Mining-Worker ist abgestürzt.");
      worker.postMessage({ type: "start", prefix, difficultyBits: t.difficulty_bits, startNonce: i, nonceStep: count });
      m.current.workers.push(worker);
    }
    m.current.timer = window.setTimeout(() => { if (m.current.template === t) void startRoundRef.current(); }, TEMPLATE_REFRESH_MS);
  }, [call, stop, stopWorker, userId]);

  useEffect(() => { startRoundRef.current = startRound; }, [startRound]);

  const startMining = useCallback(() => {
    if (typeof Worker === "undefined") { setError("Dieser Browser unterstützt kein Mining (keine Web Worker)."); return; }
    m.current.want = true; setMessage(""); setBlocks(0);
    void startRound();
  }, [startRound]);

  // Beim Verlassen der Seite alle Worker sauber beenden (ohne State-Updates).
  useEffect(() => {
    const state = m.current;
    return () => {
      state.want = false;
      for (const w of state.workers) { w.postMessage({ type: "stop" }); w.terminate(); }
      state.workers = [];
      if (state.workerUrl) { URL.revokeObjectURL(state.workerUrl); state.workerUrl = null; }
      if (state.timer) { window.clearTimeout(state.timer); state.timer = 0; }
    };
  }, []);

  const expected = difficulty ? 2 ** difficulty : 0;

  const progress = expected ? Math.min(100, Math.round(hashes / expected * 100)) : 0;

  return (
    <section className={`card card-pad browser-miner${running ? " is-mining" : ""}${flash ? " is-flash" : ""}`}>
      <div className="card-head"><h2>Coins minen</h2><span className="miner-badge">{online === false ? "Node offline" : online ? "bereit – keine Installation" : "verbinde …"}</span></div>
      <p className="local-miner-intro">Mint GIBB für <strong>{name}</strong> direkt im Browser – <strong>ohne Installation</strong>. Dein Rechner löst echte Blöcke, der Node prüft sie und schreibt die Belohnung gut.</p>

      {online === false ? (
        <div className="local-miner-offline"><p>Es ist gerade kein Blockchain-Node erreichbar. Sobald einer läuft (lokal mit <code>pnpm chain</code> oder gehostet), kannst du hier ohne Installation minen.</p></div>
      ) : (
        <>
          <div className="browser-miner-stage">
            <div className="mining-orb" aria-hidden="true">
              <span className="mining-orb-ring" />
              <span className="mining-orb-ring" />
              <span className="mining-orb-core">◆</span>
            </div>
            <div className="browser-miner-live">
              <div className="browser-miner-rate"><strong>{running && hashrate ? (hashrate / 1000).toFixed(0) : "0"}</strong><span>kH/s</span></div>
              <div className="browser-miner-meter"><i style={{ width: `${progress}%` }} /></div>
              <small>{running ? `${fmt(hashes)} Versuche · ${cores} ${cores === 1 ? "Kern" : "Kerne"} · ${progress}% des Erwartungswerts` : `bereit zum Minen${cores ? ` · ${cores} ${cores === 1 ? "Kern" : "Kerne"}` : ""}`}</small>
            </div>
          </div>

          <div className="local-miner-stats browser-miner-tiles">
            <div><span>Schwierigkeit</span><strong>{difficulty ? `${difficulty} Bit` : "–"}</strong></div>
            <div className={flash ? "pop" : ""}><span>Blöcke gefunden</span><strong>{fmt(blocks)}</strong></div>
            <div><span>Dein Guthaben</span><strong>{nodeBalance === null ? "–" : `${fmt(nodeBalance)} GIBB`}</strong></div>
          </div>
          <div className="local-miner-actions">
            <button className={`browser-miner-btn ${running ? "secondary" : "primary"}`} type="button" onClick={() => (running ? stop("Mining gestoppt.") : startMining())}>
              <span aria-hidden="true">{running ? "⏹" : "⛏"}</span>{running ? "Mining stoppen" : "Minen"}
            </button>
          </div>
          <small className="field-hint">Ein Browser-Kern schafft rund 100–300 kH/s. Läuft nur, solange dieser Tab offen ist.</small>
          {message && !error && <div className="message">{message}</div>}
          {error && <div className="message error">{error}</div>}
        </>
      )}
    </section>
  );
}
