"use client";

// Owner-Bereich im Blockchain-Tab der GibbCoin-Website: hält alle Website-Konten
// mit der Blockchain-Website synchron (automatisch + Knopf) und lässt den Owner
// alle Node-Einstellungen von hier steuern. Das Minen selbst passiert in der
// BrowserMinerCard darüber – hier gibt es bewusst KEINEN zweiten Miner-Button.

import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabase } from "../lib/supabase";

// Standard-Node-Adresse: gleiche Domain wie die Website, Port 8787. So funktioniert
// es lokal (localhost) und auf einem echten Server automatisch für alle Besucher.
const DEFAULT_NODE = typeof window !== "undefined" && window.location?.hostname
  ? `${window.location.protocol}//${window.location.hostname}:8787`
  : "http://localhost:8787";
const NODE_KEY = "gibb-node-url";

type NodeSettings = {
  reward: number; difficultyBits: number; minBits: number; maxBits: number; targetSeconds: number; autoAdjust: boolean;
  marketEnabled: boolean; startPrice: number; startingCash: number; tradingFeePercent: number; minOrderAmount: number;
  fallbackMinerEnabled: boolean; fallbackDelaySeconds: number; browserMinerThreads: number;
};
const numberFields: Array<[keyof NodeSettings, string]> = [
  ["reward", "Belohnung pro Block (GIBB)"], ["difficultyBits", "Schwierigkeit (Bit)"], ["minBits", "Min. Bit"], ["maxBits", "Max. Bit"],
  ["targetSeconds", "Ziel-Blockzeit (s)"], ["startPrice", "Startpreis (Rappen)"], ["startingCash", "Startguthaben (Rappen)"],
  ["tradingFeePercent", "Handelsgebühr (%)"], ["minOrderAmount", "Min. Ordermenge"], ["fallbackDelaySeconds", "Reserve-Miner ab Stillstand (s)"], ["browserMinerThreads", "Browser-Miner Kerne (0 = alle)"],
];

function initialNode() {
  try { return localStorage.getItem(NODE_KEY) || DEFAULT_NODE; } catch { return DEFAULT_NODE; }
}

export function LocalMinerCard({ userId, name, balance }: { userId: string; name: string; balance: number; isAdmin: boolean }) {
  const [node, setNode] = useState(initialNode);
  const [online, setOnline] = useState<boolean | null>(null);
  const [settings, setSettings] = useState<NodeSettings | null>(null);
  const [savingSettings, setSavingSettings] = useState(false);
  const [settingsMsg, setSettingsMsg] = useState("");
  const [syncMsg, setSyncMsg] = useState("");
  const [syncing, setSyncing] = useState(false);
  const [syncedCount, setSyncedCount] = useState<number | null>(null);

  const settingsDirty = useRef(false);
  const registeredRef = useRef(false);
  const autoSyncedRef = useRef(false);

  const call = useCallback(async (path: string, body?: unknown) => {
    const res = await fetch(node + path, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : undefined);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data as { error?: string }).error || `http_${res.status}`);
    return data;
  }, [node]);

  // Alle Website-Nutzer über admin_list_users holen und gesammelt an den Node übergeben.
  const syncAllUsers = useCallback(async (silent = false) => {
    const supabase = getSupabase();
    if (!supabase) return;
    if (!silent) { setSyncing(true); setSyncMsg(""); }
    try {
      const { data, error: rpcError } = await supabase.rpc("admin_list_users", { p_query: "" });
      if (rpcError) throw new Error(rpcError.message);
      const users = ((data ?? []) as Array<{ user_id: string; username?: string | null; display_name?: string | null; balance?: number | null }>)
        .map((u) => ({ supabaseId: u.user_id, name: u.username || u.display_name || "Konto", balance: Number(u.balance ?? 0) }));
      const res = await call("/api/register-many", { users }) as { added: number; updated: number; total: number };
      setSyncedCount(res.total);
      if (!silent) setSyncMsg(`✔ ${res.total} Nutzer synchronisiert: ${res.added} neu, ${res.updated} aktualisiert.`);
    } catch (e) {
      const code = e instanceof Error ? e.message : "";
      if (!silent) setSyncMsg(code.includes("mfa") ? "Für diese Aktion ist eine bestätigte MFA-Sitzung nötig." : code.includes("http_") || code.includes("Failed to fetch") ? "Node nicht erreichbar. Läuft er? (pnpm chain)" : "Nutzerliste konnte nicht geladen werden (nur für Admins).");
    } finally {
      if (!silent) setSyncing(false);
    }
  }, [call]);

  // Node-Status + Einstellungen laden; beim ersten erfolgreichen Kontakt alle Nutzer automatisch übernehmen.
  useEffect(() => {
    let active = true;
    const poll = async () => {
      try {
        if (!registeredRef.current) { await call("/api/register", { supabaseId: userId, name, balance }); registeredRef.current = true; }
        const stats = await call("/api/stats") as { settings: NodeSettings };
        if (!active) return;
        setOnline(true);
        if (!settingsDirty.current) setSettings(stats.settings);
        if (!autoSyncedRef.current) { autoSyncedRef.current = true; void syncAllUsers(true); }
      } catch {
        if (active) setOnline(false);
      }
    };
    void poll();
    const interval = window.setInterval(poll, 5000);
    return () => { active = false; window.clearInterval(interval); };
  }, [userId, name, balance, node, call, syncAllUsers]);

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

  return (
    <section className="card card-pad owner-panel">
      <div className="card-head"><h2>Owner-Bereich</h2><span>{online === false ? "Node offline" : online ? "Node verbunden" : "verbinde …"}</span></div>

      {online === false ? (
        <div className="local-miner-offline">
          <p>Der Blockchain-Node ist nicht erreichbar. Starte ihn mit <code>pnpm chain</code>, dann synchronisieren sich die Konten und du kannst die Blockchain hier steuern.</p>
          <label className="field">Node-Adresse
            <input className="input" value={node} onChange={(e) => setNode(e.target.value)} onBlur={() => { try { localStorage.setItem(NODE_KEY, node); } catch { /* ignore */ } }} placeholder={DEFAULT_NODE} />
          </label>
        </div>
      ) : (
        <>
          <div className="local-miner-adminsync">
            <div><strong>Nutzer-Synchronisation</strong><span>{syncedCount === null ? "Alle Website-Konten werden automatisch übernommen." : `${syncedCount} Konten synchron · automatisch aktuell gehalten.`}</span></div>
            <button className="secondary" type="button" disabled={syncing} onClick={() => void syncAllUsers()}>{syncing ? "Übertrage …" : "Jetzt alle synchronisieren"}</button>
            {syncMsg && <div className={`message ${syncMsg.startsWith("✔") ? "" : "error"}`}>{syncMsg}</div>}
          </div>

          {settings && (
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
