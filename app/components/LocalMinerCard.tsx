"use client";

// Karte auf der echten GibbCoin-Website: meldet das aktuell angemeldete Konto
// beim lokalen Blockchain-Node an (damit es auf der Blockchain-Website erscheint)
// und startet/stoppt für dieses Konto einen lokalen Miner auf dem PC, auf dem
// der Node läuft. Der Node muss dafür lokal laufen (pnpm chain).

import { useEffect, useRef, useState } from "react";
import { getSupabase } from "../lib/supabase";

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

type NodeSettings = {
  reward: number; difficultyBits: number; minBits: number; maxBits: number; targetSeconds: number; autoAdjust: boolean;
  marketEnabled: boolean; startPrice: number; startingCash: number; tradingFeePercent: number; minOrderAmount: number;
  fallbackMinerEnabled: boolean; fallbackDelaySeconds: number;
};
const numberFields: Array<[keyof NodeSettings, string]> = [
  ["reward", "Belohnung pro Block (GIBB)"], ["difficultyBits", "Schwierigkeit (Bit)"], ["minBits", "Min. Bit"], ["maxBits", "Max. Bit"],
  ["targetSeconds", "Ziel-Blockzeit (s)"], ["startPrice", "Startpreis (Rappen)"], ["startingCash", "Startguthaben (Rappen)"],
  ["tradingFeePercent", "Handelsgebühr (%)"], ["minOrderAmount", "Min. Ordermenge"], ["fallbackDelaySeconds", "Reserve-Miner ab Stillstand (s)"],
];

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

export function LocalMinerCard({ userId, name, balance, isAdmin }: { userId: string; name: string; balance: number; isAdmin: boolean }) {
  const [node, setNode] = useState(initialNode);
  const [syncMsg, setSyncMsg] = useState("");
  const [syncing, setSyncing] = useState(false);
  const [online, setOnline] = useState<boolean | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [status, setStatus] = useState<MinerStatus | null>(null);
  const [threads, setThreads] = useState<number | "">("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const [settings, setSettings] = useState<NodeSettings | null>(null);
  const [savingSettings, setSavingSettings] = useState(false);
  const [settingsMsg, setSettingsMsg] = useState("");

  const registeredRef = useRef(false);
  const threadsTouched = useRef(false);
  const settingsDirty = useRef(false);

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
        const stats = await call("/api/stats") as { settings: NodeSettings };
        if (active && !settingsDirty.current) setSettings(stats.settings);
      } catch {
        if (active) setOnline(false);
      }
    };
    void poll();
    const interval = window.setInterval(poll, 2000);
    return () => { active = false; window.clearInterval(interval); };
  }, [userId, name, balance, node]);

  const saveSettings = async () => {
    if (!settings) return;
    setSavingSettings(true); setSettingsMsg("");
    try {
      await call("/api/settings", settings);
      settingsDirty.current = false;
      setSettingsMsg("✔ Blockchain-Einstellungen gespeichert.");
    } catch {
      setSettingsMsg("Einstellungen konnten nicht gespeichert werden (Node erreichbar?).");
    } finally {
      setSavingSettings(false);
    }
  };
  const editSetting = (key: keyof NodeSettings, value: number | boolean) => {
    settingsDirty.current = true;
    setSettings((s) => (s ? { ...s, [key]: value } : s));
  };

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

  // Admin: alle Website-Nutzer über admin_list_users holen und gesammelt an den Node übergeben.
  const syncAllUsers = async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    setSyncing(true); setSyncMsg("");
    try {
      const { data, error: rpcError } = await supabase.rpc("admin_list_users", { p_query: "" });
      if (rpcError) throw new Error(rpcError.message);
      const users = ((data ?? []) as Array<{ user_id: string; username?: string | null; display_name?: string | null; balance?: number | null }>)
        .map((u) => ({ supabaseId: u.user_id, name: u.username || u.display_name || "Konto", balance: Number(u.balance ?? 0) }));
      const res = await call("/api/register-many", { users }) as { added: number; updated: number; total: number };
      setSyncMsg(`✔ ${res.total} Nutzer auf der Blockchain-Website: ${res.added} neu, ${res.updated} aktualisiert.`);
    } catch (e) {
      const code = e instanceof Error ? e.message : "";
      setSyncMsg(code.includes("mfa") ? "Für diese Aktion ist eine bestätigte MFA-Sitzung nötig." : code.includes("http_") || code.includes("Failed to fetch") ? "Node nicht erreichbar. Läuft er? (pnpm chain)" : "Nutzerliste konnte nicht geladen werden (nur für Admins).");
    } finally {
      setSyncing(false);
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
          {isAdmin && (
            <div className="local-miner-adminsync">
              <div><strong>Admin: alle Nutzer übernehmen</strong><span>Überträgt alle Konten der Website auf die Blockchain-Website.</span></div>
              <button className="secondary" type="button" disabled={syncing} onClick={() => void syncAllUsers()}>{syncing ? "Übertrage …" : "Alle Website-Nutzer übernehmen"}</button>
              {syncMsg && <div className={`message ${syncMsg.startsWith("✔") ? "" : "error"}`}>{syncMsg}</div>}
            </div>
          )}
          {isAdmin && settings && (
            <div className="node-settings">
              <div className="node-settings-head"><strong>Blockchain-Einstellungen</strong><span>Steuere den Node direkt von hier.</span></div>
              <div className="node-settings-grid">
                {numberFields.map(([key, label]) => (
                  <label className="field" key={key}><span>{label}</span>
                    <input className="input" type="number" value={String(settings[key])} onChange={(e) => editSetting(key, Number(e.target.value))} />
                  </label>
                ))}
              </div>
              <div className="node-settings-toggles">
                <label className="check"><input type="checkbox" checked={settings.autoAdjust} onChange={(e) => editSetting("autoAdjust", e.target.checked)} /> Schwierigkeit automatisch anpassen</label>
                <label className="check"><input type="checkbox" checked={settings.marketEnabled} onChange={(e) => editSetting("marketEnabled", e.target.checked)} /> Markt aktiv</label>
                <label className="check"><input type="checkbox" checked={settings.fallbackMinerEnabled} onChange={(e) => editSetting("fallbackMinerEnabled", e.target.checked)} /> Reserve-Miner aktiv (langsam, nur bei Stillstand)</label>
              </div>
              <div className="local-miner-actions">
                <button className="primary" type="button" disabled={savingSettings} onClick={() => void saveSettings()}>{savingSettings ? "Speichert …" : "Einstellungen speichern"}</button>
                {settingsMsg && <span className={`message ${settingsMsg.startsWith("✔") ? "" : "error"}`}>{settingsMsg}</span>}
              </div>
            </div>
          )}
        </>
      )}
    </section>
  );
}
