"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

const REGISTRATION_COOLDOWN_MS = 60_000;
const EMAIL_RATE_LIMIT_COOLDOWN_MS = 60_000;
const REGISTRATION_COOLDOWN_KEY = "gibb-registration-cooldown-until";

function isEmailSendRateLimit(error?: { code?: string; message?: string; status?: number }) {
  const detail = `${error?.code ?? ""} ${error?.message ?? ""}`.toLocaleLowerCase("de-CH");
  return detail.includes("over_email_send_rate_limit")
    || detail.includes("email rate limit")
    || detail.includes("email_send_rate");
}

function formatRegistrationCooldown(seconds: number) {
  return seconds >= 60 ? `${Math.ceil(seconds / 60)} min` : `${seconds}s`;
}

function loginErrorMessage(error?: { code?: string; message?: string; status?: number }) {
  const detail = `${error?.code ?? ""} ${error?.message ?? ""}`.toLocaleLowerCase("de-CH");
  if (detail.includes("banned") || detail.includes("ban_duration")) {
    return "Dieses Konto wurde gebannt. Eine Anmeldung ist erst wieder möglich, nachdem ein Admin das Konto freigegeben hat.";
  }
  if (detail.includes("rate_limit") || error?.status === 429) {
    return "Zu viele Anmeldeanfragen in kurzer Zeit. Bitte warte kurz und versuche es danach genau einmal erneut.";
  }
  return "E-Mail oder Passwort ist nicht korrekt.";
}

function registrationErrorMessage(error?: { code?: string; message?: string; status?: number }) {
  const detail = `${error?.code ?? ""} ${error?.message ?? ""}`.toLocaleLowerCase("de-CH");
  if (detail.includes("rate_limit") || detail.includes("after") || error?.status === 429) {
    return "Deine E-Mail-Adresse ist frei und kann wiederverwendet werden. Nur das Versandlimit für Bestätigungs-E-Mails ist gerade erreicht.";
  }
  if (detail.includes("already") || detail.includes("exists")) {
    return "Das Konto konnte gerade nicht erstellt werden. Bitte prüfe deine Eingaben oder versuche es später erneut.";
  }
  if (detail.includes("password") || detail.includes("weak")) {
    return "Das Passwort ist zu schwach. Verwende mindestens 8 Zeichen und mische Buchstaben, Zahlen und Sonderzeichen.";
  }
  if (detail.includes("invalid") && detail.includes("email")) {
    return "Diese E-Mail-Adresse ist ungültig. Prüfe die Schreibweise.";
  }
  if (detail.includes("signup_disabled")) {
    return "Neue Registrierungen sind momentan deaktiviert.";
  }
  return "Das Konto konnte gerade nicht erstellt werden. Bitte versuche es in einem Moment erneut.";
}

export function LoginPage() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [mode, setMode] = useState<"login" | "register" | "forgot">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [registrationCooldownSeconds, setRegistrationCooldownSeconds] = useState(0);

  useEffect(() => {
    const notice = window.sessionStorage.getItem("gibb-account-notice");
    const successNotice = window.sessionStorage.getItem("gibb-success-notice");
    if (!notice && !successNotice) return;
    window.sessionStorage.removeItem("gibb-account-notice");
    window.sessionStorage.removeItem("gibb-success-notice");
    const timer = window.setTimeout(() => {
      if (notice) setError(notice);
      if (successNotice) setMessage(successNotice);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    function updateRegistrationCooldown() {
      let cooldownUntil = Number(window.sessionStorage.getItem(REGISTRATION_COOLDOWN_KEY) ?? 0);
      if (cooldownUntil - Date.now() > EMAIL_RATE_LIMIT_COOLDOWN_MS) {
        window.sessionStorage.removeItem(REGISTRATION_COOLDOWN_KEY);
        cooldownUntil = 0;
      }
      const seconds = Math.max(0, Math.ceil((cooldownUntil - Date.now()) / 1000));
      setRegistrationCooldownSeconds(seconds);
      if (seconds === 0) window.sessionStorage.removeItem(REGISTRATION_COOLDOWN_KEY);
    }

    updateRegistrationCooldown();
    const timer = window.setInterval(updateRegistrationCooldown, 1000);
    return () => window.clearInterval(timer);
  }, []);

  function changeMode(nextMode: "login" | "register" | "forgot") {
    setMode(nextMode);
    setError("");
    setMessage("");
  }

  async function submitEmailAuth(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase();
    if (!supabase) { setError("Die Anmeldung ist aktuell nicht konfiguriert."); return; }
    if (!email.trim() || (mode !== "forgot" && password.length < 8)) {
      setError("Bitte gib eine gültige E-Mail und mindestens 8 Passwortzeichen ein.");
      return;
    }
    if (mode === "register" && registrationCooldownSeconds > 0) {
      setError(`Bitte warte noch ${registrationCooldownSeconds} Sekunden, bevor du erneut registrierst.`);
      return;
    }

    setBusy(true); setError(""); setMessage("");
    if (mode === "forgot") {
      const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/?password-reset=1`,
      });
      if (resetError) {
        setError("Der Reset-Link konnte gerade nicht versendet werden. Bitte warte kurz und versuche es erneut.");
      } else {
        setMessage("Falls ein Konto mit dieser E-Mail existiert, ist ein Bestätigungslink unterwegs. Öffne den Link, um dein neues Passwort festzulegen.");
      }
    } else if (mode === "login") {
      const { error: authError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (authError) setError(loginErrorMessage(authError));
      else window.sessionStorage.removeItem("gibb-account-notice");
    } else {
      const cooldownUntil = Date.now() + REGISTRATION_COOLDOWN_MS;
      window.sessionStorage.setItem(REGISTRATION_COOLDOWN_KEY, String(cooldownUntil));
      setRegistrationCooldownSeconds(Math.ceil(REGISTRATION_COOLDOWN_MS / 1000));
      const { data, error: authError } = await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: { emailRedirectTo: window.location.origin },
      });
      if (authError) {
        if (isEmailSendRateLimit(authError)) {
          const retryAt = Date.now() + EMAIL_RATE_LIMIT_COOLDOWN_MS;
          window.sessionStorage.setItem(REGISTRATION_COOLDOWN_KEY, String(retryAt));
          setRegistrationCooldownSeconds(Math.ceil(EMAIL_RATE_LIMIT_COOLDOWN_MS / 1000));
          setError("Die Registrierung konnte gerade nicht abgeschlossen werden, weil der E-Mail-Versand ausgelastet ist. Versuche es in 60 Sekunden erneut.");
        } else {
          setError(registrationErrorMessage(authError));
        }
      } else if (!data.session) {
        setMessage("Fast geschafft: Öffne jetzt den Bestätigungslink in deiner E-Mail, um die Registrierung abzuschliessen.");
      }
    }
    setBusy(false);
  }

  return (
    <main className="auth-page">
      <div className="auth-layout">
        <section className="auth-showcase" aria-label="GIBB Coin Vorteile">
          <div className="auth-brand"><span className="coin-mark auth-logo" aria-hidden="true">G</span><span><strong>GIBB Coin</strong><small>Wallet</small></span></div>
          <div className="auth-pitch"><span>Deine Schulwährung. Neu gedacht.</span><h1>Senden. Empfangen. Überblick behalten.</h1><p>Ein persönliches Wallet für den GIBB-Campus – schnell, transparent und serverseitig geschützt.</p></div>
          <div className="auth-benefits"><div><b>01</b><span><strong>Sofort startklar</strong><small>Einmalig 10 GIBB Startguthaben</small></span></div><div><b>02</b><span><strong>Jede Bewegung sichtbar</strong><small>Nachvollziehbarer Transaktionsverlauf</small></span></div><div><b>03</b><span><strong>Du entscheidest</strong><small>Persönliche Benachrichtigungen</small></span></div></div>
          <p className="auth-security">Geschützt durch Supabase Auth, Row Level Security und serverseitige Transaktionen.</p>
        </section>

        <section className="auth-card" aria-labelledby="login-title">
          <div className="auth-card-heading"><span className="eyebrow">{mode === "forgot" ? "Sicherer Zugang" : "Willkommen"}</span><h2 id="login-title">{mode === "login" ? "Bei GIBB Coin anmelden" : mode === "register" ? "Dein Konto erstellen" : "Passwort zurücksetzen"}</h2><p>{mode === "login" ? "Melde dich mit E-Mail und Passwort an." : mode === "register" ? "Registriere dich ausschliesslich mit E-Mail und Passwort." : "Wir senden dir einen Bestätigungslink an die E-Mail-Adresse deines Kontos."}</p></div>
          {mode !== "forgot" && <div className="auth-tabs" role="tablist" aria-label="Anmeldemodus">
            <button type="button" role="tab" aria-selected={mode === "login"} className={mode === "login" ? "active" : ""} onClick={() => changeMode("login")}>Anmelden</button>
            <button type="button" role="tab" aria-selected={mode === "register"} className={mode === "register" ? "active" : ""} onClick={() => changeMode("register")}>Registrieren</button>
          </div>}
          <form className="email-auth-form" onSubmit={submitEmailAuth}>
            <div className="field"><label htmlFor="auth-email">E-Mail-Adresse</label><input className="input" id="auth-email" type="email" inputMode="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="name@beispiel.ch" required /></div>
            {mode !== "forgot" && <div className="field"><label htmlFor="auth-password">Passwort <span>mindestens 8 Zeichen</span></label><div className="password-control"><input className="input" id="auth-password" type={showPassword ? "text" : "password"} minLength={8} autoComplete={mode === "login" ? "current-password" : "new-password"} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="••••••••" required /><button type="button" onClick={() => setShowPassword((visible) => !visible)} aria-label={showPassword ? "Passwort verbergen" : "Passwort anzeigen"}>{showPassword ? "Aus" : "An"}</button></div>{mode === "login" && <button className="forgot-password-link" type="button" onClick={() => changeMode("forgot")}>Passwort vergessen?</button>}</div>}
            {mode === "register" && <p className="registration-email-hint">Auch nach einer Kontolöschung darfst du dieselbe E-Mail wiederverwenden. Wir senden eine neue Bestätigungs-E-Mail – bitte nur einmal klicken.</p>}
            {mode === "login" && <p className="auth-persistence-hint"><span aria-hidden="true">✓</span><span><strong>Angemeldet bleiben ist aktiv</strong>Die sichere Sitzung wird in diesem Browser gespeichert. Passwort und 2FA-Code werden nicht von GIBB Coin gespeichert.</span></p>}
            <button className="primary auth-submit" type="submit" disabled={busy || (mode === "register" && registrationCooldownSeconds > 0)}>{busy ? "Bitte warten …" : mode === "login" ? "Sicher anmelden" : mode === "register" ? registrationCooldownSeconds > 0 ? `Erneut möglich in ${formatRegistrationCooldown(registrationCooldownSeconds)}` : "Kostenloses Konto erstellen" : "Reset-Link per E-Mail senden"}</button>
          </form>
          {mode === "forgot" && <button className="back-to-login" type="button" onClick={() => changeMode("login")}>← Zurück zur Anmeldung</button>}
          {message && <p className="message success-message" role="status">✓ {message}</p>}
          {error && <p className="message error" role="alert">{error}</p>}
          <p className="auth-note">Mit der Anmeldung akzeptierst du die Nutzungsbedingungen von GIBB Coin.</p>
        </section>
      </div>
    </main>
  );
}
