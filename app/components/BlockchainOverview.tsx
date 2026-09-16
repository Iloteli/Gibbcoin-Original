"use client";

// Live-Übersicht des Blockchain-Tabs: zieht Kennzahlen und die neuesten Blöcke
// direkt vom lokalen Node (kein Supabase) und zeigt sie als animiertes Dashboard.

import { useEffect, useRef, useState } from "react";

// Standard-Node-Adresse: gleiche Domain wie die Website, Port 8787. So funktioniert
// es lokal (localhost) und auf einem echten Server automatisch für alle Besucher.
const DEFAULT_NODE = typeof window !== "undefined" && window.location?.hostname
  ? `${window.location.protocol}//${window.location.hostname}:8787`
  : "http://localhost:8787";
const NODE_KEY = "gibb-node-url";

type Stats = {
  height: number; blocks: number; difficultyBits: number; price: number; supply: number;
  transactions: number; accounts: number; volume24h: number; averageBlockSeconds: number | null;
  settings: { reward: number; fallbackMinerEnabled: boolean };
};
type Block = { height: number; hash: string; miner_label: string; tx_count: number; difficulty_bits: number; reward: number; mined_at?: string; timestamp?: number; attempts?: number | null };

function initialNode() {
  try { return localStorage.getItem(NODE_KEY) || DEFAULT_NODE; } catch { return DEFAULT_NODE; }
}
function fmt(v: number) { return Math.round(v || 0).toLocaleString("de-CH"); }
function short(h: string, n = 14) { return h ? `${h.slice(0, n)}…${h.slice(-4)}` : "–"; }
function blockTime(b: Block) {
  const t = b.timestamp ? b.timestamp * 1000 : b.mined_at ? new Date(b.mined_at).getTime() : Date.now();
  return new Date(t).toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export function BlockchainOverview({ userId }: { userId: string }) {
  const [node] = useState(initialNode);
  const [online, setOnline] = useState<boolean | null>(null);
  const [stats, setStats] = useState<Stats | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [balance, setBalance] = useState<number | null>(null);
  const topHeight = useRef<number>(-1);
  const [freshHeight, setFreshHeight] = useState<number>(-1);

  useEffect(() => {
    let active = true;
    const get = async (path: string) => {
      const res = await fetch(node + path);
      if (!res.ok) throw new Error(`http_${res.status}`);
      return res.json();
    };
    const poll = async () => {
      try {
        const [s, bl, ms] = await Promise.all([
          get("/api/stats") as Promise<Stats>,
          get("/api/blocks?limit=8") as Promise<Block[]>,
          get(`/api/miner-status?address=${encodeURIComponent(`sb_${userId}`)}`).catch(() => null) as Promise<{ account: { balance: number } | null } | null>,
        ]);
        if (!active) return;
        setOnline(true);
        setStats(s);
        setBlocks(bl);
        setBalance(ms?.account?.balance ?? null);
        if (bl[0] && bl[0].height !== topHeight.current) {
          topHeight.current = bl[0].height;
          setFreshHeight(bl[0].height);
          window.setTimeout(() => { if (active) setFreshHeight(-1); }, 1200);
        }
      } catch {
        if (active) setOnline(false);
      }
    };
    void poll();
    const interval = window.setInterval(poll, 2500);
    return () => { active = false; window.clearInterval(interval); };
  }, [node, userId]);

  if (online === false) {
    return (
      <section className="card card-pad chain-overview-offline">
        <div className="chain-dot bad" aria-hidden="true" />
        <div><strong>Blockchain-Node offline</strong><p>Sobald der Node läuft, siehst du hier die Live-Kette. Deine Miner-Karte bleibt darunter nutzbar, sobald er verbunden ist.</p></div>
      </section>
    );
  }

  const tiles: Array<[string, string, string?]> = [
    ["Blockhöhe", stats ? fmt(stats.height) : "–"],
    ["Blöcke", stats ? fmt(stats.blocks) : "–"],
    ["Schwierigkeit", stats ? `${stats.difficultyBits} Bit` : "–"],
    ["Kurs", stats ? `${(Math.round(stats.price * 100) / 100).toLocaleString("de-CH", { minimumFractionDigits: 2 })} Rp` : "–"],
    ["Umlauf", stats ? `${fmt(stats.supply)} GIBB` : "–"],
    ["Dein Guthaben", balance === null ? "–" : `${fmt(balance)} GIBB`, "accent"],
  ];

  return (
    <section className="card card-pad chain-overview">
      <div className="card-head">
        <h2>Live-Blockchain</h2>
        <span className="chain-live"><i className={online ? "on" : ""} />{online ? "verbunden" : "…"}{stats?.settings.fallbackMinerEnabled ? " · Reserve-Miner an" : ""}</span>
      </div>
      <div className="chain-tiles">
        {tiles.map(([label, value, kind]) => (
          <div key={label} className={`chain-tile ${kind ?? ""}`}><span>{label}</span><strong>{value}</strong></div>
        ))}
      </div>

      <h3 className="chain-blocks-title">Neueste Blöcke</h3>
      <div className="chain-blocks">
        {blocks.length === 0 && <div className="chain-empty">Noch keine Blöcke – starte unten das Minen.</div>}
        {blocks.map((b) => (
          <article className={`chain-block ${b.height === freshHeight ? "fresh" : ""}`} key={b.height}>
            <span className="chain-block-h">#{b.height}</span>
            <div className="chain-block-main">
              <code>{short(b.hash, 16)}</code>
              <small>{b.height === 0 ? "Genesis" : `von ${b.miner_label}`} · {b.tx_count} Tx · {b.difficulty_bits} Bit</small>
            </div>
            <div className="chain-block-meta">
              <strong>{b.reward ? `+${b.reward}` : "–"}</strong>
              <small>{blockTime(b)}</small>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}
