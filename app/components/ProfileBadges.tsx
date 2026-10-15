"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Extras = { ok: boolean; member_no: number; members: number; sent: number; received: number; games: number; game_wins: number; blocks: number; trades: number };
type Badge = { key: string; icon: string; label: string; hint: string; earned: boolean };

type Props = { userId: string; balance?: number; dinoBest?: number; role?: string; showLocked?: boolean };

const nf = (n: number) => n.toLocaleString("de-CH");

function badgesFor(x: Extras, p: Props): Badge[] {
  return [
    { key: "owner", icon: "👑", label: "Owner", hint: "Leitet GIBB Coin", earned: p.role === "super_admin" },
    { key: "early", icon: "🌱", label: "Früh dabei", hint: "Eines der ersten 50 Konten", earned: x.member_no <= 50 },
    { key: "first", icon: "💸", label: "Erste Zahlung", hint: "Einmal GIBB gesendet", earned: x.sent >= 1 },
    { key: "popular", icon: "🤝", label: "Beliebt", hint: "10 Zahlungen erhalten", earned: x.received >= 10 },
    { key: "player", icon: "🎮", label: "Spieler", hint: "10 Runden gespielt", earned: x.games >= 10 },
    { key: "lucky", icon: "🍀", label: "Glückspilz", hint: "10 Runden gewonnen", earned: x.game_wins >= 10 },
    { key: "miner", icon: "⛏️", label: "Miner", hint: "Einen Block gemint", earned: x.blocks >= 1 },
    { key: "pro-miner", icon: "💎", label: "Profi-Miner", hint: "100 Blöcke gemint", earned: x.blocks >= 100 },
    { key: "trader", icon: "📈", label: "Händler", hint: "Am Markt gehandelt", earned: x.trades >= 1 },
    { key: "dino", icon: "🦖", label: "Dino-Profi", hint: "1’000 Punkte in Dino Run", earned: (p.dinoBest ?? 0) >= 1000 },
    { key: "saver", icon: "💰", label: "Sammler", hint: "1’000 GIBB auf dem Konto", earned: (p.balance ?? 0) >= 1000 },
  ].filter((b) => b.key !== "owner" || b.earned);
}

// Abzeichen und Zahlen eines Profils (nur Summen, keine einzelnen Buchungen)
export function ProfileBadges(props: Props) {
  const [extras, setExtras] = useState<Extras | null>(null);

  useEffect(() => {
    let alive = true;
    const supabase = getSupabase();
    if (!supabase) return;
    void supabase.rpc("get_public_profile_extras", { p_user_id: props.userId }).then(({ data, error }) => {
      if (alive && !error && (data as Extras | null)?.ok) setExtras(data as Extras);
    });
    return () => { alive = false; };
  }, [props.userId]);

  if (!extras) return null;
  const badges = badgesFor(extras, props);
  const earned = badges.filter((b) => b.earned);
  const shown = props.showLocked ? badges : earned;

  return (
    <div className="profile-badges">
      <div className="profile-badge-stats">
        <div><span>Mitglied</span><strong>#{nf(extras.member_no)}</strong></div>
        <div><span>Gesendet</span><strong>{nf(extras.sent)}</strong></div>
        <div><span>Erhalten</span><strong>{nf(extras.received)}</strong></div>
        <div><span>Spiele</span><strong>{nf(extras.games)}</strong></div>
        <div><span>Blöcke</span><strong>{nf(extras.blocks)}</strong></div>
        <div><span>Handel</span><strong>{nf(extras.trades)}</strong></div>
      </div>
      <div className="profile-badge-head"><strong>Abzeichen</strong><small>{earned.length} von {badges.length}</small></div>
      {shown.length ? (
        <ul className="profile-badge-list">
          {shown.map((b, i) => (
            <li key={b.key} className={b.earned ? "earned" : "locked"} title={b.hint} style={{ animationDelay: `${i * 40}ms` }}>
              <span aria-hidden="true">{b.icon}</span><b>{b.label}</b><small>{b.earned ? b.hint : `Noch offen: ${b.hint}`}</small>
            </li>
          ))}
        </ul>
      ) : <p className="profile-badge-empty">Noch keine Abzeichen – sende GIBB, spiele oder mine, um welche zu sammeln.</p>}
    </div>
  );
}
