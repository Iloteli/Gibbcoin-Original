"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { ThemeToggle } from "./ThemeToggle";
import { BrandMark } from "./BrandMark";


function isEmailSendRateLimit(error?: { code?: string; message?: string; status?: number }) {
  const detail = `${error?.code ?? ""} ${error?.message ?? ""}`.toLocaleLowerCase("de-CH");
  return detail.includes("over_email_send_rate_limit")
    || detail.includes("email rate limit")
    || detail.includes("email_send_rate");
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
  // Registrieren nur, wenn der Owner es auf der Chain-Seite eingeschaltet hat
  const [registrationOpen, setRegistrationOpen] = useState(false);
  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    let alive = true;
    void supabase.rpc("get_site_features").then(({ data }) => {
      if (alive) setRegistrationOpen((data as { registration_enabled?: boolean } | null)?.registration_enabled === true);
    });
    return () => { alive = false; };
  }, []);

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
      const { data, error: authError } = await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: { emailRedirectTo: window.location.origin },
      });
      if (authError) {
        if (isEmailSendRateLimit(authError)) {
          // Supabase: an dieselbe Adresse nur alle paar Sekunden eine Mail ("… only request this after 42 seconds")
          const wait = /after (\d+) seconds?/i.exec(authError.message ?? "")?.[1];
          setError(wait
            ? `An diese Adresse wurde gerade schon eine Bestätigungs-Mail geschickt – schau im Postfach (auch Spam) nach. Eine neue Mail geht erst in ${wait} Sekunden.`
            : "Die Registrierung konnte gerade nicht abgeschlossen werden, weil der E-Mail-Versand ausgelastet ist. Versuche es in einer Minute erneut.");
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
      {/* Bewegter Hintergrund: Farbwolken und aufsteigende Funken (nur Dekoration) */}
      <div className="auth-fx" aria-hidden="true">
        <i className="auth-blob b1" /><i className="auth-blob b2" /><i className="auth-blob b3" />
        {[8, 18, 31, 44, 58, 72, 86, 95].map((left, i) => <span key={left} className="auth-spark" style={{ left: `${left}%`, animationDelay: `${(i * 0.7) % 5}s` }} />)}
      </div>
      <div className="auth-theme"><ThemeToggle /></div>
      <div className="auth-layout">
        <section className="auth-showcase" aria-label="GIBB Coin Vorteile">
          <div className="auth-brand"><BrandMark size={44} className="auth-logo-mark" /><span><strong>GIBB Coin</strong><small>Wallet</small></span></div>
          <div className="auth-coin-wrap" aria-hidden="true"><div className="auth-coin">G</div></div>
          <div className="auth-pitch"><span>Deine Schulwährung. Neu gedacht.</span><h1>Senden. Empfangen. Überblick behalten.</h1><p>Ein persönliches Wallet für den GIBB-Campus – schnell, transparent und serverseitig geschützt.</p></div>
          <div className="auth-benefits"><div><b>01</b><span><strong>Sofort startklar</strong><small>Einmalig 10 GIBB Startguthaben</small></span></div><div><b>02</b><span><strong>Jede Bewegung sichtbar</strong><small>Nachvollziehbarer Transaktionsverlauf</small></span></div><div><b>03</b><span><strong>Du entscheidest</strong><small>Persönliche Benachrichtigungen</small></span></div></div>
        </section>

        <section className="auth-card" aria-labelledby="login-title">
          <div className="auth-card-heading"><span className="eyebrow">{mode === "forgot" ? "Sicherer Zugang" : "Willkommen"}</span><h2 id="login-title">{mode === "login" ? "Bei GIBB Coin anmelden" : mode === "register" ? "Dein Konto erstellen" : "Passwort zurücksetzen"}</h2><p>{mode === "login" ? "Melde dich mit E-Mail und Passwort an." : mode === "register" ? "Registriere dich ausschliesslich mit E-Mail und Passwort." : "Wir senden dir einen Bestätigungslink an die E-Mail-Adresse deines Kontos."}</p></div>
          {mode !== "forgot" && (registrationOpen ? <div className="auth-tabs" role="tablist" aria-label="Anmeldemodus">
            <button type="button" role="tab" aria-selected={mode === "login"} className={mode === "login" ? "active" : ""} onClick={() => changeMode("login")}>Anmelden</button>
            <button type="button" role="tab" aria-selected={mode === "register"} className={mode === "register" ? "active" : ""} onClick={() => changeMode("register")}>Registrieren</button>
          </div> : <p className="auth-no-signup">Neue Konten erstellt der Owner. Noch kein Konto? Melde dich beim Owner.</p>)}
          <form className="email-auth-form" onSubmit={submitEmailAuth}>
            <div className="field"><label htmlFor="auth-email">E-Mail-Adresse</label><input className="input" id="auth-email" type="email" inputMode="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="name@beispiel.ch" required /></div>
            {mode !== "forgot" && <div className="field"><label htmlFor="auth-password">Passwort <span>mindestens 8 Zeichen</span></label><div className="password-control"><input className="input" id="auth-password" type={showPassword ? "text" : "password"} minLength={8} autoComplete={mode === "login" ? "current-password" : "new-password"} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="••••••••" required /><button type="button" onClick={() => setShowPassword((visible) => !visible)} aria-label={showPassword ? "Passwort verbergen" : "Passwort anzeigen"}>{showPassword ? "Aus" : "An"}</button></div>{mode === "login" && <button className="forgot-password-link" type="button" onClick={() => changeMode("forgot")}>Passwort vergessen?</button>}</div>}
            {mode === "register" && <p className="registration-email-hint">Auch nach einer Kontolöschung darfst du dieselbe E-Mail wiederverwenden. Wir senden eine neue Bestätigungs-E-Mail – bitte nur einmal klicken.</p>}
            {mode === "login" && <p className="auth-persistence-hint"><span aria-hidden="true">✓</span><span><strong>Angemeldet bleiben ist aktiv</strong>Die sichere Sitzung wird in diesem Browser gespeichert. Passwort und 2FA-Code werden nicht von GIBB Coin gespeichert.</span></p>}
            <button className="primary auth-submit" type="submit" disabled={busy}>{busy ? "Bitte warten …" : mode === "login" ? "Sicher anmelden" : mode === "register" ? "Kostenloses Konto erstellen" : "Reset-Link per E-Mail senden"}</button>
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
