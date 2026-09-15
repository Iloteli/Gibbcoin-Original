"use client";

// Karte auf der echten GibbCoin-Website: meldet das aktuell angemeldete Konto
// beim lokalen Blockchain-Node an (damit es auf der Blockchain-Website erscheint)
// und startet/stoppt für dieses Konto einen lokalen Miner auf dem PC, auf dem
// der Node läuft. Der Node muss dafür lokal laufen (pnpm chain).

import { useEffect, useRef, useState } from "react";

const DEFAULT_NODE = "http://localhost:8787";
const NODE_KEY = "gibb-node-url";

type MinerStatus = {
  running: boolean;
  address: string | null;
  threads: number;
  cores: number;
  hashrate: number;
  blocks: number;
  forThisAccount: boolean;
  price: number;
  account: { address: string; name: string; balance: number; cash: number } | null;
};

function initialNode() {
  try {
    return localStorage.getItem(NODE_KEY) || DEFAULT_NODE;
  } catch {
    return DEFAULT_NODE;
  }
}
function fmt(value: number) {
  return Math.round(value || 0).toLocaleString("de-CH");
}

export function LocalMinerCard({ userId, name, balance }: { userId: string; name: string; balance: number }) {
  const [node, setNode] = useState(initialNode);
  const [online, setOnline] = useState<boolean | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [status, setStatus] = useState<MinerStatus | null>(null);
  const [threads, setThreads] = useState<number | "">("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const registeredRef = useRef(false);
  const threadsTouched = useRef(false);

  useEffect(() => {
    let active = true;
    const call = async (path: string, body?: unknown) => {
      const res = await fetch(node + path, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : undefined);
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error((data as { error?: string }).error || `http_${res.status}`);
      return data;
    };
    const poll = async () => {
      try {
        if (!registeredRef.current) {
          const reg = await call("/api/register", { supabaseId: userId, name, balance }) as { address: string };
          if (!active) return;
          registeredRef.current = true;
          setAddress(reg.address);
        }
        const data = await call(`/api/miner-status?address=${encodeURIComponent(`sb_${userId}`)}`) as MinerStatus;
        if (!active) return;
        setStatus(data);
        setOnline(true);
        if (!threadsTouched.current) setThreads(data.cores);
      } catch {
        if (active) setOnline(false);
      }
    };
    void poll();
    const interval = window.setInterval(poll, 2000);
    return () => { active = false; window.clearInterval(interval); };
  }, [userId, name, balance, node]);

  const call = async (path: string, body?: unknown) => {
    const res = await fetch(node + path, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : undefined);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data as { error?: string }).error || `http_${res.status}`);
    return data;
  };

  const toggle = async () => {
    setBusy(true); setError(""); setMessage("");
    try {
      let addr = address;
      if (!addr) { addr = (await call("/api/register", { supabaseId: userId, name, balance }) as { address: string }).address; setAddress(addr); }
      if (status?.running && status.forThisAccount) {
        await call("/api/local-miner", { enabled: false });
        setMessage("Miner gestoppt.");
      } else {
        await call("/api/local-miner", { enabled: true, address: addr, threads: threads || undefined });
        setMessage(`Miner gestartet – er mint jetzt für dein Konto auf ${threads || status?.cores || "allen"} Kernen.`);
      }
    } catch (e) {
      const code = e instanceof Error ? e.message : "";
      setError(code === "miner_already_running" ? "Auf diesem PC läuft bereits ein Miner (evtl. für ein anderes Konto)." : "Aktion fehlgeschlagen. Läuft der Blockchain-Node? (pnpm chain)");
    } finally {
      setBusy(false);
    }
  };

  const runningForOther = Boolean(status?.running && !status?.forThisAccount);

  return (
    <section className="card card-pad local-miner">
      <div className="card-head"><h2>Lokaler Miner für dein Konto</h2><span>{online === false ? "Node offline" : online ? "Node verbunden" : "verbinde …"}</span></div>

      {online === false ? (
        <div className="local-miner-offline">
          <p>Der lokale Blockchain-Node ist nicht erreichbar. Starte ihn auf diesem PC mit <code>pnpm chain</code>, dann erscheint dein Konto automatisch auf der Blockchain-Website und du kannst hier minen.</p>
          <label className="field">Node-Adresse
            <input className="input" value={node} onChange={(e) => setNode(e.target.value)} onBlur={() => { try { localStorage.setItem(NODE_KEY, node); } catch { /* ignore */ } }} placeholder={DEFAULT_NODE} />
          </label>
        </div>
      ) : (
        <>
          <p className="local-miner-intro">Dein Konto <strong>{name}</strong> ist auf der Blockchain als <code>{address ?? `sb_${userId}`}</code> registriert. Der Miner läuft auf dem PC, auf dem der Node läuft, und nutzt echte Rechenleistung. Gefundene Blöcke bringen GIBB.</p>
          <div className="local-miner-stats">
            <div><span>Status</span><strong>{status?.running ? (status.forThisAccount ? "läuft für dich" : "läuft (anderes Konto)") : "bereit"}</strong></div>
            <div><span>Hashrate</span><strong>{status?.running && status.hashrate ? `${(status.hashrate / 1000).toFixed(0)} kH/s` : "–"}</strong></div>
            <div><span>Kerne</span><strong>{status?.cores ?? "–"}</strong></div>
            <div><span>Blöcke gefunden</span><strong>{status?.running || status?.blocks ? fmt(status?.blocks ?? 0) : "–"}</strong></div>
            <div><span>Kurs</span><strong>{status ? `${(Math.round(status.price * 100) / 100).toLocaleString("de-CH", { minimumFractionDigits: 2 })} Rp` : "–"}</strong></div>
            <div><span>Dein Guthaben (Node)</span><strong>{status?.account ? `${fmt(status.account.balance)} GIBB` : "–"}</strong></div>
          </div>
          <div className="local-miner-actions">
            <label className="field local-miner-threads">Kerne
              <input className="input" type="number" min={1} max={status?.cores ?? 16} value={threads} onChange={(e) => { threadsTouched.current = true; setThreads(e.target.value === "" ? "" : Number(e.target.value)); }} disabled={status?.running} />
            </label>
            <button className={status?.running && status.forThisAccount ? "secondary" : "primary"} type="button" disabled={busy || runningForOther} onClick={() => void toggle()}>
              {status?.running && status.forThisAccount ? "Mining stoppen" : "Lokalen Miner starten"}
            </button>
          </div>
          {runningForOther && <p className="field-hint">Auf diesem PC mint gerade ein anderes Konto. Stoppe es zuerst auf der Blockchain-Website.</p>}
          {message && !error && <div className="message">{message}</div>}
          {error && <div className="message error">{error}</div>}
        </>
      )}
    </section>
  );
}
