"use client";

import type { User } from "@supabase/supabase-js";
import { useState } from "react";
import type { Profile, Wallet } from "../lib/types";
import { getSupabase } from "../lib/supabase";

type Props = {
  user: User;
  profile: Profile;
  wallet: Wallet | null;
  onNavigate: (view: "home" | "send" | "games" | "community" | "activity" | "chain" | "account" | "admin", target?: string) => void;
};

export function SecurityOverview({ user, profile, wallet, onNavigate }: Props) {
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState("");

  async function refreshSession() {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy("session");
    const { error } = await supabase.auth.refreshSession();
    setBusy("");
    setMessage(error ? "Die Sitzung konnte nicht aktualisiert werden." : "Sitzung erfolgreich aktualisiert.");
  }

  async function requestPasswordReset() {
    const supabase = getSupabase();
    if (!supabase || !user.email) return;
    setBusy("password");
    const { error } = await supabase.auth.resetPasswordForEmail(user.email, { redirectTo: `${window.location.origin}/` });
    setBusy("");
    setMessage(error ? "Der Passwort-Reset konnte nicht angefordert werden." : "Ein sicherer Passwort-Reset-Link wurde angefordert.");
  }

  async function copy(value: string, label: string) {
    try {
      await navigator.clipboard.writeText(value);
      setMessage(`${label} kopiert.`);
    } catch {
      setMessage("Kopieren ist in diesem Browser nicht verfügbar.");
    }
  }

  const secureConnection = typeof window === "undefined" || window.location.protocol === "https:";
  const accountActive = wallet?.status !== "locked";
  const provider = user.app_metadata?.provider === "google" ? "Google" : "E-Mail";

  return (
    <section className="card card-pad security-overview" id="security-overview" aria-labelledby="security-overview-title">
      <div className="section-heading compact-heading">
        <div><span className="section-number">SICHERHEIT</span><h2 id="security-overview-title">Sicherheitscenter</h2></div>
        <span className={secureConnection && accountActive ? "readiness-status ready" : "readiness-status"}>{secureConnection && accountActive ? "Geschützt" : "Prüfen"}</span>
      </div>
      <div className="security-overview-grid">
        <article><strong>Verbindung</strong><span>{secureConnection ? "HTTPS geschützt" : "Unsichere Verbindung"}</span></article>
        <article><strong>Anmeldung</strong><span>{provider} · Sitzung aktiv</span></article>
        <article><strong>Wallet-Status</strong><span>{accountActive ? "Aktiv" : "Gesperrt"}</span></article>
        <article><strong>Serverautorität</strong><span>Transfers werden serverseitig geprüft</span></article>
        <article><strong>Admin-MFA</strong><span>{profile.role === "user" ? "Für Adminrechte erforderlich" : "Im Adminbereich verwalten"}</span></article>
        <article><strong>Datenschutz</strong><span>Export und Löschung verfügbar</span></article>
        <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void refreshSession()}>{busy === "session" ? "Prüft …" : "Sitzung aktualisieren"}</button>
        <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void requestPasswordReset()}>{busy === "password" ? "Sendet …" : "Passwort-Reset anfordern"}</button>
        <button className="secondary compact" type="button" onClick={() => void copy(user.id, "Konto-ID")}>Konto-ID kopieren</button>
        <button className="secondary compact" type="button" onClick={() => void copy(user.email ?? "", "E-Mail")}>E-Mail kopieren</button>
        <button className="secondary compact" type="button" onClick={() => onNavigate("community", "reports")}>Verdächtige Aktivität melden</button>
        <button className="secondary compact" type="button" onClick={() => onNavigate("account", "support-privacy")}>Support kontaktieren</button>
        <button className="secondary compact" type="button" onClick={() => onNavigate("account", "support-privacy")}>Datenschutzanfrage</button>
        <button className="secondary compact" type="button" onClick={() => onNavigate(profile.role === "user" ? "activity" : "admin", profile.role === "user" ? "notifications" : "security")}>Sicherheitsmeldungen öffnen</button>
      </div>
      {message && <p className="message success-message" role="status">✓ {message}</p>}
    </section>
  );
}
