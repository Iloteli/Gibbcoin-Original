"use client";

import { QRCodeSVG } from "qrcode.react";
import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Enrollment = { id: string; uri: string; secret: string };

export function AdminSecurityCenter() {
  const [factorId, setFactorId] = useState("");
  const [enrollment, setEnrollment] = useState<Enrollment | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const loadFactors = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const { data, error: factorError } = await supabase.auth.mfa.listFactors();
    if (factorError) { setError("Der 2FA-Status konnte nicht geladen werden."); return; }
    setFactorId(data.totp.find((factor) => factor.status === "verified")?.id ?? "");
  }, []);

  useEffect(() => { const timer = window.setTimeout(() => void loadFactors(), 0); return () => window.clearTimeout(timer); }, [loadFactors]);

  async function startEnrollment() {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError(""); setMessage("");
    const existing = await supabase.auth.mfa.listFactors();
    for (const factor of existing.data?.all.filter((item) => item.factor_type === "totp" && item.status === "unverified") ?? []) {
      await supabase.auth.mfa.unenroll({ factorId: factor.id });
    }
    const { data, error: enrollError } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "GIBB Coin Admin" });
    setBusy(false);
    if (enrollError) { setError("Die Zwei-Faktor-Einrichtung konnte nicht gestartet werden."); return; }
    setEnrollment({ id: data.id, uri: data.totp.uri, secret: data.totp.secret });
  }

  async function verifyEnrollment(event: React.FormEvent) {
    event.preventDefault();
    if (!enrollment || !/^\d{6}$/.test(code)) { setError("Gib den sechsstelligen Code aus deiner Authenticator-App ein."); return; }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError("");
    const challenge = await supabase.auth.mfa.challenge({ factorId: enrollment.id });
    if (challenge.error) { setBusy(false); setError("Die Prüfung konnte nicht gestartet werden."); return; }
    const verification = await supabase.auth.mfa.verify({ factorId: enrollment.id, challengeId: challenge.data.id, code });
    setBusy(false);
    if (verification.error) { setCode(""); setError("Der Code ist falsch oder abgelaufen."); return; }
    setEnrollment(null); setCode(""); setMessage("Zwei-Faktor-Schutz ist jetzt aktiv. Neue Sitzungen verlangen zusätzlich den Authenticator-Code.");
    await loadFactors();
  }

  async function cancelEnrollment() {
    const supabase = getSupabase();
    if (supabase && enrollment) await supabase.auth.mfa.unenroll({ factorId: enrollment.id });
    setEnrollment(null); setCode(""); setError("");
  }

  async function disableMfa() {
    if (!factorId || !window.confirm("Zwei-Faktor-Schutz wirklich deaktivieren? Das Konto ist danach nur noch durch das Passwort geschützt.")) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError(""); setMessage("");
    const { error: unenrollError } = await supabase.auth.mfa.unenroll({ factorId });
    setBusy(false);
    if (unenrollError) { setError("2FA konnte nicht deaktiviert werden. Melde dich erneut mit deinem zweiten Faktor an."); return; }
    setFactorId(""); setMessage("Zwei-Faktor-Schutz wurde deaktiviert.");
  }

  return <section className="card card-pad admin-security" id="security"><div className="admin-security-head"><div><div className="eyebrow">Kontosicherheit</div><h2>Zwei-Faktor-Schutz</h2><p>Schütze Admin- und Owner-Rechte zusätzlich mit einer Authenticator-App.</p></div><span className={factorId ? "active" : "inactive"}>{factorId ? "Aktiv" : "Empfohlen"}</span></div>{enrollment ? <form className="mfa-enrollment" onSubmit={verifyEnrollment}><div className="mfa-qr"><QRCodeSVG value={enrollment.uri} size={190} level="H" bgColor="#ffffff" fgColor="#07100d" title="Authenticator-QR-Code" /></div><div className="mfa-enrollment-copy"><strong>QR-Code mit deiner Authenticator-App scannen</strong><ol><li>Authenticator-App öffnen.</li><li>QR-Code scannen oder den Schlüssel manuell eingeben.</li><li>Den aktuellen sechsstelligen Code bestätigen.</li></ol><div className="mfa-secret"><span>Manueller Schlüssel</span><code>{enrollment.secret}</code></div><div className="field"><label htmlFor="mfa-enrollment-code">Sechsstelliger Code</label><input className="input mfa-code-input" id="mfa-enrollment-code" type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6} pattern="[0-9]{6}" value={code} onChange={(event) => { setCode(event.target.value.replace(/\D/g, "").slice(0, 6)); setError(""); }} placeholder="000000" /></div><div className="mfa-actions"><button className="secondary" type="button" disabled={busy} onClick={() => void cancelEnrollment()}>Abbrechen</button><button className="primary compact" type="submit" disabled={busy || code.length !== 6}>{busy ? "Wird geprüft …" : "2FA aktivieren"}</button></div></div></form> : <div className="admin-security-summary"><div><strong>{factorId ? "Dein Konto ist doppelt geschützt" : "Noch kein zweiter Faktor eingerichtet"}</strong><p>{factorId ? "Nach der normalen Anmeldung wird zusätzlich ein einmaliger Code verlangt. Geschützte Admin-Aktionen akzeptieren dann nur vollständig bestätigte Sitzungen." : "Die Einrichtung funktioniert mit Google Authenticator, Microsoft Authenticator, Authy, 1Password und ähnlichen Apps."}</p></div>{factorId ? <button className="secondary compact" type="button" disabled={busy} onClick={() => void disableMfa()}>{busy ? "Bitte warten …" : "2FA deaktivieren"}</button> : <button className="primary compact" type="button" disabled={busy} onClick={() => void startEnrollment()}>{busy ? "Wird vorbereitet …" : "Jetzt sicher einrichten"}</button>}</div>}{message && <p className="message success-message" role="status">✓ {message}</p>}{error && <p className="message error" role="alert">{error}</p>}<p className="mfa-security-note">Wichtig: Bewahre den Zugriff auf deine Authenticator-App sicher auf. Supabase stellt keine klassischen Wiederherstellungscodes bereit.</p></section>;
}
