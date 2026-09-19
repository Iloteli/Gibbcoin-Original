"use client";

import { useState } from "react";
import type { Profile, Wallet } from "../lib/types";

type Props = {
  profile: Profile;
  wallet: Wallet | null;
  onNavigate: (view: "home" | "send" | "games" | "community" | "activity" | "chain" | "account" | "admin", target?: string) => void;
};

export function AccountReadiness({ profile, wallet, onNavigate }: Props) {
  const [dismissed, setDismissed] = useState(false);

  function dismiss() {
    setDismissed(true);
  }

  const profileReady = Boolean(profile.display_name && profile.username);
  const walletReady = wallet?.status !== "locked";

  return (
    <section className="card card-pad account-readiness" aria-labelledby="account-readiness-title">
      <div className="section-heading compact-heading">
        <div><span className="section-number">START</span><h2 id="account-readiness-title">Dein sicherer Start</h2></div>
        <span className={profileReady && walletReady ? "readiness-status ready" : "readiness-status"}>{profileReady && walletReady ? "Bereit" : "Noch offen"}</span>
      </div>
      {!dismissed && (
        <div className="onboarding-banner" role="status">
          <div>
            <strong>Willkommen bei GIBB Coin</strong>
            <p>Richte die wichtigsten Bereiche einmal ein. Danach findest du alle Alltagsaktionen direkt im Dashboard.</p>
          </div>
          <button className="secondary compact" type="button" onClick={dismiss}>Hinweis ausblenden</button>
        </div>
      )}
      <div className="readiness-grid">
        <button className={profileReady ? "readiness-item complete" : "readiness-item"} type="button" onClick={() => onNavigate("account", "profile")}>
          <span aria-hidden="true">{profileReady ? "✓" : "01"}</span><strong>Profil vervollständigen</strong><small>{profileReady ? "Name und Benutzername sind gesetzt." : "Name und Benutzername prüfen"}</small>
        </button>
        <button className={walletReady ? "readiness-item complete" : "readiness-item"} type="button" onClick={() => onNavigate("home", "wallet")}>
          <span aria-hidden="true">{walletReady ? "✓" : "02"}</span><strong>Wallet-Status prüfen</strong><small>{walletReady ? "Wallet ist aktiv." : "Wallet benötigt Aufmerksamkeit."}</small>
        </button>
        <button className="readiness-item" type="button" onClick={() => onNavigate("send", "qr-code")}>
          <span aria-hidden="true">03</span><strong>QR-Zahlung einrichten</strong><small>Empfangen und Senden ohne Tippfehler</small>
        </button>
        <button className="readiness-item" type="button" onClick={() => onNavigate("activity", "notifications")}>
          <span aria-hidden="true">04</span><strong>Benachrichtigungen prüfen</strong><small>Zahlungen und Sicherheitsmeldungen im Blick</small>
        </button>
        <button className="readiness-item" type="button" onClick={() => onNavigate("account", "support-privacy")}>
          <span aria-hidden="true">05</span><strong>Hilfe und Datenschutz</strong><small>Support, Export und Löschanfragen</small>
        </button>
      </div>
    </section>
  );
}
