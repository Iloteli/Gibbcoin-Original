"use client";

import type { User } from "@supabase/supabase-js";
import type { Profile, Transaction, Wallet } from "../lib/types";
import { useState } from "react";

type Props = {
  user: User;
  profile: Profile;
  wallet: Wallet | null;
  transactions: Transaction[];
  onRefresh: () => Promise<void>;
  onNavigate: (view: "send" | "activity" | "games", target?: string) => void;
};

function downloadSummary(profile: Profile, wallet: Wallet | null, transactions: Transaction[]) {
  const summary = [
    "GIBB Coin – persönlicher Kontoauszug",
    `Name: ${profile.display_name}`,
    `Benutzername: @${profile.username}`,
    `Guthaben: ${wallet?.balance ?? 0} GIBB`,
    `Erstellt: ${new Date().toLocaleString("de-CH")}`,
    "",
    `Transaktionen im geladenen Verlauf: ${transactions.length}`,
  ].join("\n");
  const url = URL.createObjectURL(new Blob([summary], { type: "text/plain;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `gibb-kontoauszug-${profile.username}.txt`;
  anchor.click();
  URL.revokeObjectURL(url);
}

export function AccountEssentials({ user, profile, wallet, transactions, onRefresh, onNavigate }: Props) {
  const [notice, setNotice] = useState("");
  const [refreshing, setRefreshing] = useState(false);

  async function copy(label: string, value: string) {
    try {
      await navigator.clipboard.writeText(value);
      setNotice(`${label} kopiert.`);
    } catch {
      setNotice("Kopieren ist in diesem Browser nicht verfügbar.");
    }
    window.setTimeout(() => setNotice(""), 2600);
  }

  async function refresh() {
    setRefreshing(true);
    await onRefresh();
    setRefreshing(false);
    setNotice("Kontostand aktualisiert.");
    window.setTimeout(() => setNotice(""), 2600);
  }

  return (
    <section className="card card-pad account-essentials" aria-labelledby="account-essentials-title">
      <div className="section-heading compact-heading">
        <div><span className="section-number">SCHNELLZUGRIFF</span><h2 id="account-essentials-title">Wichtige Kontoaktionen</h2></div>
        <small>Alles Nötige an einem Ort</small>
      </div>
      <div className="account-essentials-grid">
        <button type="button" onClick={() => onNavigate("send", "send-coins")}><strong>Coins senden</strong><span>Transfer starten</span></button>
        <button type="button" onClick={() => onNavigate("activity", "transactions")}><strong>Verlauf öffnen</strong><span>Transaktionen prüfen</span></button>
        <button type="button" onClick={() => onNavigate("games", "game-center")}><strong>Spielpause prüfen</strong><span>Spielgrenzen öffnen</span></button>
        <button type="button" onClick={() => void refresh()} disabled={refreshing}><strong>{refreshing ? "Aktualisiert …" : "Jetzt aktualisieren"}</strong><span>Serverstand laden</span></button>
        <button type="button" onClick={() => void copy("Guthaben", `${wallet?.balance ?? 0} GIBB`)}><strong>Guthaben kopieren</strong><span>{wallet?.balance ?? 0} GIBB</span></button>
        <button type="button" onClick={() => void copy("Benutzername", `@${profile.username}`)}><strong>Benutzername kopieren</strong><span>@{profile.username}</span></button>
        <button type="button" onClick={() => void copy("Konto-ID", user.id)}><strong>Konto-ID kopieren</strong><span>Sicher teilen</span></button>
        <button type="button" onClick={() => downloadSummary(profile, wallet, transactions)}><strong>Kontoauszug speichern</strong><span>Lokale Textkopie</span></button>
        <button type="button" onClick={() => window.print()}><strong>Seite drucken</strong><span>Für Unterlagen</span></button>
        <button type="button" onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })}><strong>Zum Seitenanfang</strong><span>Schnell zurück</span></button>
      </div>
      {notice && <p className="message success-message" role="status">✓ {notice}</p>}
    </section>
  );
}
