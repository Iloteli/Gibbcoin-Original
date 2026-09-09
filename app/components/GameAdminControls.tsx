"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type GameKey = "roulette" | "coin_flip" | "blackjack" | "dice_duel" | "high_card" | "poker" | "plinko" | "dino_run" | "slots" | "baccarat" | "keno" | "wheel" | "mines" | "bingo" | "crash";
type SettingKey = "game_center" | GameKey;
type GameSetting = { game_key: SettingKey; label: string; enabled: boolean; updated_at: string };
type DinoAdminSetting = { speed_level: number; difficulty_level: number };
type GlobalGameLimits = { max_wager: number | null; daily_loss_limit: number | null; cooldown_seconds: number; updated_at?: string };
type SecureResult = { ok?: boolean; error?: string };
type CenterAdminState = { settings?: GameSetting[] };
type Props = { adminPin: string; currentRole: "admin" | "super_admin"; onPinRejected: (message: string) => void; pinReady: boolean; pinLocked: boolean };

function gameAdminError(code?: string) {
  if (code?.includes("admin_pin_not_set")) return "Richte zuerst oben deinen persönlichen vierstelligen Admin-PIN ein.";
  if (code?.includes("admin_pin_invalid")) return "Der Admin-PIN ist falsch.";
  if (code?.includes("admin_pin_locked")) return "Der Admin-PIN ist nach zu vielen Versuchen vorübergehend gesperrt.";
  if (code?.includes("mfa")) return "Bestätige zuerst deine Admin-Sitzung mit 2FA.";
  if (code?.includes("admin_required")) return "Für die Spielverwaltung fehlen dir die Adminrechte.";
  if (code?.includes("invalid_global")) return "Prüfe die globalen Spielgrenzen. Leere Felder bedeuten unbegrenzt.";
  return "Die Spiel-Einstellung konnte nicht sicher gespeichert werden.";
}

export function GameAdminControls({ adminPin, currentRole, onPinRejected, pinReady, pinLocked }: Props) {
  const [settings, setSettings] = useState<GameSetting[]>([]);
  const [dinoSetting, setDinoSetting] = useState<DinoAdminSetting>({ speed_level: 1, difficulty_level: 1 });
  const [globalMaxWager, setGlobalMaxWager] = useState("");
  const [globalDailyLoss, setGlobalDailyLoss] = useState("");
  const [globalCooldown, setGlobalCooldown] = useState("0");
  const [busy, setBusy] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const loadAdminGameState = useCallback(async () => {
    const supabase = getSupabase(); if (!supabase) return;
    setLoading(true);
    const [centerResponse, dinoResponse, limitResponse] = await Promise.all([
      supabase.rpc("get_game_center_state"),
      supabase.rpc("get_dino_admin_state"),
      supabase.rpc("get_global_game_limits"),
    ]);
    setLoading(false);
    if (centerResponse.error || dinoResponse.error || limitResponse.error) { setError(gameAdminError(centerResponse.error?.message ?? dinoResponse.error?.message ?? limitResponse.error?.message)); return; }
    setSettings((centerResponse.data as CenterAdminState | null)?.settings ?? []);
    setDinoSetting((dinoResponse.data as DinoAdminSetting | null) ?? { speed_level: 1, difficulty_level: 1 });
    const limits = limitResponse.data as GlobalGameLimits | null;
    setGlobalMaxWager(limits?.max_wager?.toString() ?? "");
    setGlobalDailyLoss(limits?.daily_loss_limit?.toString() ?? "");
    setGlobalCooldown(String(limits?.cooldown_seconds ?? 0));
    setError("");
  }, []);
  useEffect(() => { const timer = window.setTimeout(() => void loadAdminGameState(), 0); return () => window.clearTimeout(timer); }, [loadAdminGameState]);
  useEffect(() => { const supabase = getSupabase(); if (!supabase) return; const channel = supabase.channel("admin-game-settings-live").on("postgres_changes", { event: "UPDATE", schema: "public", table: "game_settings" }, () => void loadAdminGameState()).subscribe(); return () => { void supabase.removeChannel(channel); }; }, [loadAdminGameState]);

  const controlsDisabled = loading || busy !== null || !pinReady || pinLocked || !/^\d{4}$/.test(adminPin);
  function requirePin() { if (!pinReady) { setError("Richte zuerst oben deinen persönlichen vierstelligen Admin-PIN ein."); return false; } if (pinLocked) { setError("Dein Admin-PIN ist gesperrt."); return false; } if (!/^\d{4}$/.test(adminPin)) { setError("Öffne den Adminpanel-Tab erneut und gib deinen PIN einmalig ein."); return false; } return true; }

  async function toggleGame(setting: GameSetting) {
    if (!requirePin()) return; const supabase = getSupabase(); if (!supabase) return;
    setBusy(`toggle:${setting.game_key}`); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_game_enabled", { p_game_key: setting.game_key, p_enabled: !setting.enabled, p_pin: adminPin });
    setBusy(null); const result = data as SecureResult | null;
    if (rpcError || !result?.ok) { const next = gameAdminError(result?.error ?? rpcError?.message); if (result?.error?.startsWith("admin_pin_")) onPinRejected(next); else setError(next); await loadAdminGameState(); return; }
    setMessage(`${setting.label} wurde ${setting.enabled ? "deaktiviert" : "aktiviert"}.`); await loadAdminGameState();
  }

  async function saveDinoSettings() {
    if (!requirePin()) return; const supabase = getSupabase(); if (!supabase) return;
    setBusy("dino:tuning"); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_dino_game_settings", { p_speed_level: dinoSetting.speed_level, p_difficulty_level: dinoSetting.difficulty_level, p_pin: adminPin });
    setBusy(null); const result = data as SecureResult | null;
    if (rpcError || !result?.ok) { const next = gameAdminError(result?.error ?? rpcError?.message); if (result?.error?.startsWith("admin_pin_")) onPinRejected(next); else setError(next); await loadAdminGameState(); return; }
    setMessage(`Dino Run gespeichert: Tempo ${dinoSetting.speed_level}/5 · Schwierigkeit ${dinoSetting.difficulty_level}/5.`); await loadAdminGameState();
  }

  async function saveGlobalLimits(event: React.FormEvent) {
    event.preventDefault();
    if (!requirePin()) return;
    const supabase = getSupabase(); if (!supabase) return;
    const maxWager = globalMaxWager === "" ? null : Number(globalMaxWager);
    const dailyLoss = globalDailyLoss === "" ? null : Number(globalDailyLoss);
    const cooldown = Number(globalCooldown);
    if ((maxWager !== null && (!Number.isSafeInteger(maxWager) || maxWager < 1))
      || (dailyLoss !== null && (!Number.isSafeInteger(dailyLoss) || dailyLoss < 1))
      || !Number.isInteger(cooldown) || cooldown < 0 || cooldown > 3600) {
      setError("Prüfe die globalen Spielgrenzen. Erlaubt sind ganze Coinbeträge und 0–3600 Sekunden Pause.");
      return;
    }
    setBusy("global:limits"); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_global_game_limits", {
      p_max_wager: maxWager,
      p_daily_loss_limit: dailyLoss,
      p_cooldown_seconds: cooldown,
      p_pin: adminPin,
    });
    setBusy(null); const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const next = gameAdminError(result?.error ?? rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) onPinRejected(next); else setError(next);
      await loadAdminGameState(); return;
    }
    setMessage("Die globalen Spielgrenzen gelten jetzt serverseitig für alle Konten.");
    await loadAdminGameState();
  }

  return <section className="game-admin admin-game-controls" id="admin-game-controls" aria-labelledby="admin-games-title">
    <div className="game-admin-intro"><span>SPIELVERWALTUNG · NUR ADMINPANEL</span><h3 id="admin-games-title">Alle Spiele zentral steuern</h3><p>{currentRole === "super_admin" ? "Owner und Admins" : "Admins"} können Spiele ein- oder ausschalten und Dino Run abstimmen. Gewinnchancen bleiben fest und für alle gleich.</p></div>
    <div className="game-admin-pin"><span>PIN-Freigabe</span><strong>{!pinReady ? "PIN zuerst einrichten" : pinLocked ? "PIN ist gesperrt" : /^\d{4}$/.test(adminPin) ? "Adminpanel freigeschaltet" : "Adminpanel gesperrt"}</strong><small>{/^\d{4}$/.test(adminPin) ? "Gilt bis du den Admin-Tab verlässt" : "PIN beim Öffnen des Adminpanels eingeben"}</small></div>
    <div className="game-switches">{settings.map((setting) => <button type="button" role="switch" aria-checked={setting.enabled} className={setting.enabled ? "on" : ""} disabled={controlsDisabled} key={setting.game_key} onClick={() => void toggleGame(setting)}><span><b>{setting.label}</b><small>{setting.enabled ? "Aktiv" : "Deaktiviert"}</small></span><i aria-hidden="true"><em /></i>{busy === `toggle:${setting.game_key}` && <u>Lädt …</u>}</button>)}</div>
    <form className="global-game-limits" onSubmit={saveGlobalLimits}>
      <div><span>ADMIN &amp; OWNER · ALLE SPIELE</span><h3>Globale Spielgrenzen</h3><p>Diese Regeln gelten für jedes Konto. Persönliche Grenzen dürfen weiterhin strenger sein, aber niemals lockerer.</p></div>
      <div className="field"><label htmlFor="global-max-wager">Maximaler Einsatz <small>leer = unbegrenzt</small></label><input id="global-max-wager" className="input" type="number" inputMode="numeric" min={1} max={1000000000000} step={1} value={globalMaxWager} disabled={controlsDisabled} onChange={(event) => setGlobalMaxWager(event.target.value)} placeholder="Unbegrenzt" /></div>
      <div className="field"><label htmlFor="global-daily-loss">Tagesverlust pro Konto <small>leer = unbegrenzt</small></label><input id="global-daily-loss" className="input" type="number" inputMode="numeric" min={1} max={1000000000000} step={1} value={globalDailyLoss} disabled={controlsDisabled} onChange={(event) => setGlobalDailyLoss(event.target.value)} placeholder="Unbegrenzt" /></div>
      <div className="field"><label htmlFor="global-game-cooldown">Pause zwischen Runden</label><select id="global-game-cooldown" className="input" value={globalCooldown} disabled={controlsDisabled} onChange={(event) => setGlobalCooldown(event.target.value)}><option value="0">Keine</option><option value="5">5 Sekunden</option><option value="15">15 Sekunden</option><option value="30">30 Sekunden</option><option value="60">1 Minute</option><option value="120">2 Minuten</option><option value="300">5 Minuten</option><option value="600">10 Minuten</option></select></div>
      <button type="submit" className="primary compact" disabled={controlsDisabled}>{busy === "global:limits" ? "Speichert …" : "Für alle speichern"}</button>
    </form>
    <div className="dino-admin-tuning"><div><span>ADMIN &amp; OWNER · DINO RUN</span><h3>Tempo und Schwierigkeit</h3><p>Stufe 1 entspricht dem normalen Lauf. Die Einstellung gilt ab dem nächsten Start.</p></div><label htmlFor="dino-speed-level">Geschwindigkeit <b>{dinoSetting.speed_level}/5</b><input id="dino-speed-level" type="range" min={1} max={5} step={1} value={dinoSetting.speed_level} disabled={controlsDisabled} onChange={(event) => setDinoSetting((current) => ({ ...current, speed_level: Number(event.target.value) }))} /></label><label htmlFor="dino-difficulty-level">Schwierigkeit <b>{dinoSetting.difficulty_level}/5</b><input id="dino-difficulty-level" type="range" min={1} max={5} step={1} value={dinoSetting.difficulty_level} disabled={controlsDisabled} onChange={(event) => setDinoSetting((current) => ({ ...current, difficulty_level: Number(event.target.value) }))} /></label><button type="button" className="primary compact" disabled={controlsDisabled} onClick={() => void saveDinoSettings()}>{busy === "dino:tuning" ? "Speichert …" : "Dino-Einstellungen speichern"}</button></div>
    {loading && <p className="message" role="status">Spiel-Einstellungen werden geladen …</p>}{message && <p className="message success-message" role="status">✓ {message}</p>}{error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
