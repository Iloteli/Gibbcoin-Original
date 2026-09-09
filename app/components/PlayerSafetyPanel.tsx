"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Safety = { max_wager: number | null; daily_loss_limit: number | null; cooldown_seconds: number; global_max_wager: number | null; global_daily_loss_limit: number | null; global_cooldown_seconds: number; break_until: string | null; loss_today: number };

function safetyError(message?: string) {
  if (message?.includes("player_break_active") || message?.includes("game_break_active")) return "Deine Spielpause ist noch aktiv.";
  if (message?.includes("player_wager_limit")) return "Dieser Einsatz überschreitet dein persönliches Limit.";
  if (message?.includes("player_daily_loss_limit")) return "Dein persönliches Tagesverlust-Limit ist erreicht.";
  if (message?.includes("player_cooldown")) return "Deine Pause zwischen zwei Runden ist noch nicht vorbei.";
  if (message?.includes("invalid_")) return "Bitte prüfe deine persönlichen Limits.";
  return "Die Spielschutz-Einstellungen konnten nicht gespeichert werden.";
}

export function PlayerSafetyPanel() {
  const [safety, setSafety] = useState<Safety | null>(null);
  const [maxWager, setMaxWager] = useState("");
  const [dailyLoss, setDailyLoss] = useState("");
  const [cooldown, setCooldown] = useState("0");
  const [busy, setBusy] = useState(false);
  const [checkedAt, setCheckedAt] = useState(0);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    const supabase = getSupabase(); if (!supabase) return;
    const { data, error: rpcError } = await supabase.rpc("get_my_player_safety");
    if (rpcError) { setError("Der Spielschutz konnte nicht geladen werden."); return; }
    const next = data as Safety;
    setSafety(next); setCheckedAt(Date.now()); setMaxWager(next.max_wager?.toString() ?? ""); setDailyLoss(next.daily_loss_limit?.toString() ?? ""); setCooldown(String(next.cooldown_seconds ?? 0));
  }, []);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function save(event: React.FormEvent) {
    event.preventDefault(); const supabase = getSupabase(); if (!supabase) return;
    setBusy(true); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("update_my_player_safety", {
      p_max_wager: maxWager ? Number(maxWager) : null,
      p_daily_loss_limit: dailyLoss ? Number(dailyLoss) : null,
      p_cooldown_seconds: Number(cooldown),
    });
    setBusy(false); if (rpcError) { setError(safetyError(rpcError.message)); return; }
    setMessage("Deine Limits sind serverseitig gespeichert."); await load();
  }

  async function startBreak(minutes: number) {
    const supabase = getSupabase(); if (!supabase) return;
    setBusy(true); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("start_my_game_break", { p_minutes: minutes });
    setBusy(false); if (rpcError) { setError(safetyError(rpcError.message)); return; }
    setMessage("Spielpause aktiviert. Sie kann nicht vorzeitig aufgehoben werden."); await load();
  }

  const breakActive = Boolean(safety?.break_until && new Date(safety.break_until).getTime() > checkedAt);
  return <section className="card card-pad safety-panel" id="player-safety">
    <div className="section-heading compact-heading"><div><span className="section-number">SAFE PLAY</span><h2>Deine Spielgrenzen</h2></div><b className={breakActive ? "status-badge locked" : "status-badge active"}>{breakActive ? "Pause aktiv" : "Spielbereit"}</b></div>
    <p>Du bestimmst Einsatzlimit, Tagesverlust und Pause. Globale Admin-Grenzen gelten zusätzlich; der Server verwendet immer die strengere Regel.</p>
    <form className="safety-grid" onSubmit={save}><div className="field"><label htmlFor="max-wager">Maximaler Einsatz <span>leer = kein eigenes Limit</span></label><input id="max-wager" className="input" type="number" min={1} max={1000000000} value={maxWager} onChange={(event) => setMaxWager(event.target.value)} /></div><div className="field"><label htmlFor="daily-loss">Maximaler Tagesverlust</label><input id="daily-loss" className="input" type="number" min={1} max={1000000000} value={dailyLoss} onChange={(event) => setDailyLoss(event.target.value)} /></div><div className="field"><label htmlFor="cooldown">Pause zwischen Runden</label><select id="cooldown" className="input" value={cooldown} onChange={(event) => setCooldown(event.target.value)}><option value="0">Keine</option><option value="5">5 Sekunden</option><option value="15">15 Sekunden</option><option value="30">30 Sekunden</option><option value="60">60 Sekunden</option></select></div><button className="primary" type="submit" disabled={busy}>Limits speichern</button></form>
    <div className="safety-summary"><span>Heute verloren: <strong>{safety?.loss_today ?? 0} GIBB</strong></span><span>Für alle: <strong>Einsatz {safety?.global_max_wager ?? "∞"} · Verlust {safety?.global_daily_loss_limit ?? "∞"} · Pause {safety?.global_cooldown_seconds ?? 0}s</strong></span>{breakActive && <span>Pause bis <strong>{new Date(safety!.break_until!).toLocaleString("de-CH")}</strong></span>}</div>
    <div className="break-buttons"><span>Unwiderrufliche Pause starten</span>{[[15,"15 Min"],[60,"1 Std"],[1440,"24 Std"],[10080,"7 Tage"]].map(([minutes,label]) => <button type="button" className="secondary compact" disabled={busy || breakActive} key={minutes} onClick={() => void startBreak(Number(minutes))}>{label}</button>)}</div>
    {message && <p className="message success-message" role="status">{message}</p>}{error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
