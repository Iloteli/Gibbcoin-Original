"use client";

import { useState } from "react";
import { getSupabase } from "../lib/supabase";

type Props = {
  recoveryAvailable: boolean;
  onComplete: (message?: string) => Promise<void>;
};

export function PasswordResetPage({ recoveryAvailable, onComplete }: Props) {
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function updatePassword(event: React.FormEvent) {
    event.preventDefault();
    if (password.length < 8) { setError("Das neue Passwort muss mindestens 8 Zeichen lang sein."); return; }
    if (password !== confirmation) { setError("Die beiden Passwörter stimmen nicht überein."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Anmeldung ist aktuell nicht konfiguriert."); return; }

    setBusy(true); setError("");
    const { error: updateError } = await supabase.auth.updateUser({ password });
    if (updateError) {
      setBusy(false);
      setError("Das Passwort konnte nicht geändert werden. Fordere einen neuen Reset-Link an.");
      return;
    }
    await onComplete("Dein Passwort wurde geändert. Du kannst dich jetzt sicher anmelden.");
  }

  return (
    <main className="auth-page">
      <section className="password-reset-card" aria-labelledby="password-reset-title">
        <span className="coin-mark auth-logo" aria-hidden="true">G</span>
        <span className="eyebrow">E-Mail bestätigt</span>
        <h1 id="password-reset-title">Neues Passwort festlegen</h1>
        {recoveryAvailable ? <>
          <p>Wähle ein neues Passwort für dein GIBB-Coin-Konto. Admins und Owner können es nicht sehen.</p>
          <form onSubmit={updatePassword}>
            <div className="field"><label htmlFor="new-password">Neues Passwort <span>mindestens 8 Zeichen</span></label><div className="password-control"><input className="input" id="new-password" type={showPassword ? "text" : "password"} minLength={8} autoComplete="new-password" value={password} onChange={(event) => setPassword(event.target.value)} required /><button type="button" onClick={() => setShowPassword((visible) => !visible)} aria-label={showPassword ? "Passwort verbergen" : "Passwort anzeigen"}>{showPassword ? "Aus" : "An"}</button></div></div>
            <div className="field"><label htmlFor="confirm-new-password">Neues Passwort bestätigen</label><input className="input" id="confirm-new-password" type={showPassword ? "text" : "password"} minLength={8} autoComplete="new-password" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} required /></div>
            <button className="primary auth-submit" type="submit" disabled={busy}>{busy ? "Wird gespeichert …" : "Passwort sicher speichern"}</button>
          </form>
        </> : <>
          <p>Dieser Reset-Link ist ungültig oder abgelaufen. Fordere auf dem Anmeldebildschirm einen neuen Link an.</p>
          <button className="primary auth-submit" type="button" onClick={() => void onComplete()}>Neuen Reset-Link anfordern</button>
        </>}
        {error && <p className="message error" role="alert">{error}</p>}
      </section>
    </main>
  );
}
