"use client";

import type { Session } from "@supabase/supabase-js";
import { useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Props = { onVerified: (session: Session) => void; onLogout: () => Promise<void> };

export function MfaChallengePage({ onVerified, onLogout }: Props) {
  const [factorId, setFactorId] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    let active = true;
    void supabase.auth.mfa.listFactors().then(({ data, error: factorError }) => {
      if (!active) return;
      const verified = data?.totp.find((factor) => factor.status === "verified");
      if (factorError || !verified) setError("Der eingerichtete zweite Faktor konnte nicht geladen werden.");
      else setFactorId(verified.id);
    });
    return () => { active = false; };
  }, []);

  async function verify(event: React.FormEvent) {
    event.preventDefault();
    if (!factorId || !/^\d{6}$/.test(code)) { setError("Gib den sechsstelligen Code aus deiner Authenticator-App ein."); return; }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError("");
    const challenge = await supabase.auth.mfa.challenge({ factorId });
    if (challenge.error) { setBusy(false); setError("Die Sicherheitsprüfung konnte nicht gestartet werden."); return; }
    const verification = await supabase.auth.mfa.verify({ factorId, challengeId: challenge.data.id, code });
    if (verification.error) { setBusy(false); setCode(""); setError("Der Code ist falsch oder abgelaufen."); return; }
    const { data: latestSession, error: sessionError } = await supabase.auth.getSession();
    setBusy(false);
    if (sessionError || !latestSession.session) {
      setError("Die bestätigte Sitzung konnte nicht gespeichert werden. Bitte versuche es nochmals.");
      return;
    }
    onVerified(latestSession.session);
  }

  return <main className="auth-page"><section className="mfa-challenge-card" aria-labelledby="mfa-title"><span className="coin-mark auth-logo" aria-hidden="true">G</span><span className="eyebrow">Zusätzlicher Schutz</span><h1 id="mfa-title">Zwei-Faktor-Code</h1><p>Dieses Konto ist geschützt. Öffne deine Authenticator-App und bestätige die Anmeldung mit dem aktuellen Code.</p><form onSubmit={verify}><div className="field"><label htmlFor="mfa-code">Sechsstelliger Sicherheitscode</label><input className="input mfa-code-input" id="mfa-code" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} value={code} onChange={(event) => { setCode(event.target.value.replace(/\D/g, "").slice(0, 6)); setError(""); }} placeholder="000000" /></div><button className="primary auth-submit" type="submit" disabled={busy || !factorId || code.length !== 6}>{busy ? "Wird geprüft …" : "Sicher anmelden"}</button></form><p className="mfa-persistence-note">Nach dieser Bestätigung bleibt die sichere Sitzung in diesem Browser gespeichert, bis du dich abmeldest oder der Zugang aus Sicherheitsgründen beendet wird.</p>{error && <p className="message error" role="alert">{error}</p>}<button className="back-to-login" type="button" onClick={() => void onLogout()}>Anderes Konto verwenden</button></section></main>;
}
