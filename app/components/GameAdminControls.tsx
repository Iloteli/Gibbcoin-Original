"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type GameKey = "roulette" | "coin_flip" | "blackjack" | "dice_duel" | "high_card" | "poker" | "plinko" | "dino_run" | "slots" | "baccarat" | "keno" | "wheel" | "mines" | "bingo" | "crash";
type PrankGameKey = Exclude<GameKey, "dino_run">;
type SettingKey = "game_center" | GameKey;
type GameSetting = { game_key: SettingKey; label: string; enabled: boolean; updated_at: string };
type PrankScope = "all" | "user";
type PrankAdminSetting = {
  game_key: PrankGameKey;
  label: string;
  enabled: boolean;
  win_chance: number;
  scope: PrankScope;
  target_username: string | null;
  target_display_name: string | null;
};
type DinoAdminSetting = { speed_level: number; difficulty_level: number };
type SecureResult = { ok?: boolean; error?: string };
type CenterAdminState = { settings?: GameSetting[] };
type GameExtrasAdminState = {
  ok: boolean;
  games: PrankAdminSetting[];
  dino: DinoAdminSetting;
};
type Props = {
  adminPin: string;
  currentRole: "admin" | "super_admin";
  onPinRejected: (message: string) => void;
  pinReady: boolean;
  pinLocked: boolean;
};

const gameIcons: Record<GameKey, string> = {
  roulette: "◎",
  coin_flip: "◐",
  blackjack: "♠",
  dice_duel: "⚄",
  high_card: "♦",
  poker: "♣",
  plinko: "●",
  dino_run: "▰",
  slots: "▦",
  baccarat: "♢",
  keno: "⑨",
  wheel: "◉",
  mines: "✦",
  bingo: "▤",
  crash: "↗",
};

function gameAdminError(code?: string) {
  if (code?.includes("admin_pin_not_set")) return "Richte zuerst oben deinen persönlichen vierstelligen Admin-PIN ein.";
  if (code?.includes("admin_pin_invalid")) return "Der Admin-PIN ist falsch.";
  if (code?.includes("admin_pin_locked")) return "Der Admin-PIN ist nach zu vielen Versuchen vorübergehend gesperrt.";
  if (code?.includes("pin_must_have_four_digits")) return "Der Admin-PIN muss genau vier Ziffern enthalten.";
  if (code?.includes("mfa")) return "Bestätige zuerst deine Admin-Sitzung mit 2FA.";
  if (code?.includes("target_user_not_found")) return "Dieser Benutzername wurde nicht gefunden.";
  if (code?.includes("target_username_required")) return "Gib einen Benutzernamen ein.";
  if (code?.includes("admin_required")) return "Für die Spielverwaltung fehlen dir die Adminrechte.";
  return "Die Spiel-Einstellung konnte nicht sicher gespeichert werden.";
}

export function GameAdminControls({ adminPin, currentRole, onPinRejected, pinReady, pinLocked }: Props) {
  const [settings, setSettings] = useState<GameSetting[]>([]);
  const [prankSettings, setPrankSettings] = useState<PrankAdminSetting[]>([]);
  const [dinoSetting, setDinoSetting] = useState<DinoAdminSetting>({ speed_level: 1, difficulty_level: 1 });
  const [busy, setBusy] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const loadAdminGameState = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) {
      setLoading(false);
      setError("Die Serververbindung für die Spielverwaltung ist noch nicht bereit.");
      return;
    }
    setLoading(true);
    const [centerResponse, extrasResponse] = await Promise.all([
      supabase.rpc("get_game_center_state"),
      supabase.rpc("get_game_extras_admin_state"),
    ]);
    setLoading(false);
    if (centerResponse.error || extrasResponse.error) {
      setError(gameAdminError(centerResponse.error?.message ?? extrasResponse.error?.message));
      return;
    }
    const center = centerResponse.data as CenterAdminState | null;
    const extras = extrasResponse.data as GameExtrasAdminState | null;
    if (!extras?.ok) {
      setError("Die erweiterten Spiel-Einstellungen konnten nicht geladen werden.");
      return;
    }
    setSettings(center?.settings ?? []);
    setPrankSettings(extras.games ?? []);
    setDinoSetting(extras.dino ?? { speed_level: 1, difficulty_level: 1 });
    setError("");
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadAdminGameState(), 0);
    return () => window.clearTimeout(timer);
  }, [loadAdminGameState]);

  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    const channel = supabase
      .channel("admin-game-settings-live")
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "game_settings" }, () => void loadAdminGameState())
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [loadAdminGameState]);

  const controlsDisabled = loading || busy !== null || !pinReady || pinLocked || !/^\d{4}$/.test(adminPin);

  function requirePin() {
    if (!pinReady) {
      setError("Richte zuerst oben deinen persönlichen vierstelligen Admin-PIN ein.");
      document.getElementById("admin-pin-setup")?.scrollIntoView({ behavior: "smooth", block: "center" });
      return false;
    }
    if (pinLocked) {
      setError("Dein Admin-PIN ist gesperrt. Entsperre ihn zuerst oben im Adminpanel.");
      return false;
    }
    if (!/^\d{4}$/.test(adminPin)) {
      setError("Öffne den Adminpanel-Tab erneut und gib deinen PIN einmalig ein.");
      return false;
    }
    return true;
  }

  function updatePrankDraft(gameKey: PrankGameKey, patch: Partial<PrankAdminSetting>) {
    setPrankSettings((current) => current.map((setting) => (
      setting.game_key === gameKey ? { ...setting, ...patch } : setting
    )));
  }

  async function toggleGame(setting: GameSetting) {
    if (!requirePin()) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(`toggle:${setting.game_key}`); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_game_enabled", {
      p_game_key: setting.game_key,
      p_enabled: !setting.enabled,
      p_pin: adminPin,
    });
    setBusy(null);
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const actionError = gameAdminError(result?.error ?? rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) onPinRejected(actionError);
      else setError(actionError);
      await loadAdminGameState();
      return;
    }
    setMessage(`${setting.label} wurde ${setting.enabled ? "deaktiviert" : "aktiviert"}.`);
    await loadAdminGameState();
  }

  async function savePrankSettings(setting: PrankAdminSetting, enabled = setting.enabled) {
    if (!requirePin()) return;
    if (!Number.isInteger(setting.win_chance) || setting.win_chance < 0 || setting.win_chance > 100) {
      setError("Die Gewinnchance muss zwischen 0 und 100 Prozent liegen.");
      return;
    }
    if (setting.scope === "user" && !setting.target_username?.trim()) {
      setError("Gib für diesen Modus einen Benutzernamen ein.");
      return;
    }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(`prank:${setting.game_key}`); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_game_visual_prank", {
      p_game_key: setting.game_key,
      p_enabled: enabled,
      p_win_chance: setting.win_chance,
      p_scope: setting.scope,
      p_target_username: setting.scope === "user" ? setting.target_username?.trim() ?? "" : "",
      p_pin: adminPin,
    });
    setBusy(null);
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const actionError = gameAdminError(result?.error ?? rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) onPinRejected(actionError);
      else setError(actionError);
      await loadAdminGameState();
      return;
    }
    setMessage(`${setting.label}: visueller Modus ${enabled ? "aktiv" : "aus"} · ${setting.win_chance} % Gewinn · ${setting.scope === "all" ? "für alle" : `nur für @${setting.target_username}`}.`);
    await loadAdminGameState();
  }

  async function saveDinoSettings() {
    if (!requirePin()) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy("dino:tuning"); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_dino_game_settings", {
      p_speed_level: dinoSetting.speed_level,
      p_difficulty_level: dinoSetting.difficulty_level,
      p_pin: adminPin,
    });
    setBusy(null);
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const actionError = gameAdminError(result?.error ?? rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) onPinRejected(actionError);
      else setError(actionError);
      await loadAdminGameState();
      return;
    }
    setMessage(`Dino Run gespeichert: Tempo ${dinoSetting.speed_level}/5 · Schwierigkeit ${dinoSetting.difficulty_level}/5. Gilt ab dem nächsten Lauf.`);
    await loadAdminGameState();
  }

  return (
    <section className="game-admin admin-game-controls" id="admin-game-controls" aria-labelledby="admin-games-title">
      <div className="game-admin-intro"><span>SPIELVERWALTUNG · NUR ADMINPANEL</span><h3 id="admin-games-title">Alle Spiele zentral steuern</h3><p>Hier verwalten {currentRole === "super_admin" ? "Owner und Admins" : "Admins"} Spielstatus, visuelle Modi sowie Tempo und Schwierigkeit von Dino Run.</p></div>
      <div className="game-admin-pin"><span>PIN-Freigabe</span><strong>{!pinReady ? "PIN zuerst einrichten" : pinLocked ? "PIN ist gesperrt" : /^\d{4}$/.test(adminPin) ? "Adminpanel freigeschaltet" : "Adminpanel gesperrt"}</strong><small>{/^\d{4}$/.test(adminPin) ? "Gilt bis du den Admin-Tab verlässt" : "PIN beim Öffnen des Adminpanels eingeben"}</small></div>
      <div className="game-switches">{settings.map((setting) => <button type="button" role="switch" aria-checked={setting.enabled} className={setting.enabled ? "on" : ""} disabled={controlsDisabled} key={setting.game_key} onClick={() => void toggleGame(setting)}><span><b>{setting.label}</b><small>{setting.enabled ? "Aktiv" : "Deaktiviert"}</small></span><i aria-hidden="true"><em /></i>{busy === `toggle:${setting.game_key}` && <u>Lädt …</u>}</button>)}</div>

      <div className="game-prank-admin">
        <div className="game-prank-heading"><span>ADMIN &amp; OWNER · VISUELLER SPASSMODUS</span><h3>Chancen pro Spiel einstellen</h3><p>Nur diese Steuerung zeigt den Modus. Wallet, Coin-Statistik, Transaktionsverlauf und Spielhistorie bleiben unverändert. Dino Run ist ausgeschlossen.</p></div>
        <div className="game-prank-grid">{prankSettings.map((setting) => {
          const itemBusy = busy === `prank:${setting.game_key}`;
          return <article className={`game-prank-card ${setting.enabled ? "enabled" : ""}`} key={setting.game_key}>
            <header><div><span>{gameIcons[setting.game_key]}</span><strong>{setting.label}</strong></div><b>{setting.enabled ? "AN" : "AUS"}</b></header>
            <label htmlFor={`prank-chance-${setting.game_key}`}>Gewinn <b>{setting.win_chance} %</b> · Verlust <b>{100 - setting.win_chance} %</b></label>
            <input id={`prank-chance-${setting.game_key}`} type="range" min={0} max={100} step={1} value={setting.win_chance} disabled={controlsDisabled} onChange={(event) => updatePrankDraft(setting.game_key, { win_chance: Number(event.target.value) })} />
            <label htmlFor={`prank-scope-${setting.game_key}`}>Gültig für</label>
            <select id={`prank-scope-${setting.game_key}`} className="input" value={setting.scope} disabled={controlsDisabled} onChange={(event) => updatePrankDraft(setting.game_key, { scope: event.target.value as PrankScope })}><option value="all">Alle Benutzer</option><option value="user">Nur eine Person</option></select>
            {setting.scope === "user" && <label className="prank-user-field" htmlFor={`prank-user-${setting.game_key}`}>Benutzername<input id={`prank-user-${setting.game_key}`} className="input" value={setting.target_username ?? ""} disabled={controlsDisabled} onChange={(event) => updatePrankDraft(setting.game_key, { target_username: event.target.value })} placeholder="z. B. iloteli" /></label>}
            <div><button type="button" className={setting.enabled ? "secondary compact" : "primary compact"} disabled={controlsDisabled} onClick={() => void savePrankSettings(setting, !setting.enabled)}>{itemBusy ? "Speichert …" : setting.enabled ? "Ausschalten" : "Einschalten"}</button><button type="button" className="secondary compact" disabled={controlsDisabled} onClick={() => void savePrankSettings(setting)}>Einstellungen speichern</button></div>
          </article>;
        })}</div>
      </div>

      <div className="dino-admin-tuning">
        <div><span>ADMIN &amp; OWNER · DINO RUN</span><h3>Tempo und Schwierigkeit</h3><p>Stufe 1 entspricht dem normalen Lauf. Die Einstellung gilt ab dem nächsten Start.</p></div>
        <label htmlFor="dino-speed-level">Geschwindigkeit <b>{dinoSetting.speed_level}/5</b><input id="dino-speed-level" type="range" min={1} max={5} step={1} value={dinoSetting.speed_level} disabled={controlsDisabled} onChange={(event) => setDinoSetting((current) => ({ ...current, speed_level: Number(event.target.value) }))} /></label>
        <label htmlFor="dino-difficulty-level">Schwierigkeit <b>{dinoSetting.difficulty_level}/5</b><input id="dino-difficulty-level" type="range" min={1} max={5} step={1} value={dinoSetting.difficulty_level} disabled={controlsDisabled} onChange={(event) => setDinoSetting((current) => ({ ...current, difficulty_level: Number(event.target.value) }))} /></label>
        <button type="button" className="primary compact" disabled={controlsDisabled} onClick={() => void saveDinoSettings()}>{busy === "dino:tuning" ? "Speichert …" : "Dino-Einstellungen speichern"}</button>
      </div>

      {loading && <p className="message" role="status">Spiel-Einstellungen werden geladen …</p>}
      {message && <p className="message success-message" role="status">✓ {message}</p>}
      {error && <p className="message error" role="alert">{error}</p>}
    </section>
  );
}
