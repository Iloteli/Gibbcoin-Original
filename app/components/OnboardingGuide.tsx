"use client";

import { useState } from "react";

type DashboardView = "home" | "send" | "games" | "community" | "activity" | "chain" | "market" | "account" | "admin";

type Props = {
  onNavigate: (view: DashboardView, target?: string) => void;
};

const DISMISS_KEY = "gibb-onboarding-guide-dismissed";

export function OnboardingGuide({ onNavigate }: Props) {
  const [visible, setVisible] = useState(() => typeof window !== "undefined" && window.localStorage.getItem(DISMISS_KEY) !== "1");

  function dismiss() {
    window.localStorage.setItem(DISMISS_KEY, "1");
    setVisible(false);
  }

  if (!visible) return null;

  return (
    <section className="card card-pad onboarding-guide" aria-labelledby="onboarding-guide-title">
      <div className="section-heading compact-heading">
        <div><span className="section-number">START</span><h2 id="onboarding-guide-title">Dein erster Rundgang</h2></div>
        <button className="secondary compact" type="button" onClick={dismiss}>Später ausblenden</button>
      </div>
      <p className="onboarding-guide-intro">Drei kurze Schritte zeigen dir, wie du sicher loslegst. Dein Guthaben bleibt dabei unverändert.</p>
      <div className="onboarding-guide-grid">
        <button type="button" onClick={() => onNavigate("account", "profile")}><span aria-hidden="true">01</span><strong>Profil prüfen</strong><small>Name und Benutzername machen dich für andere erkennbar.</small></button>
        <button type="button" onClick={() => onNavigate("send", "send-coins")}><span aria-hidden="true">02</span><strong>Testzahlung vorbereiten</strong><small>Wähle einen Empfänger und prüfe Betrag und Notiz vor dem Senden.</small></button>
        <button type="button" onClick={() => onNavigate("activity", "transactions")}><span aria-hidden="true">03</span><strong>Verlauf verstehen</strong><small>Jede Buchung bleibt nachvollziehbar und kann als Beleg geöffnet werden.</small></button>
      </div>
      <p className="onboarding-guide-note" role="note">Offline kannst du gespeicherte Daten ansehen. Senden, Spielen und Admin-Aktionen brauchen eine Serververbindung.</p>
    </section>
  );
}
