"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { Profile, Transaction, Wallet } from "../lib/types";
import { BrandMark } from "./BrandMark";

type Props = {
  userId: string;
  profile: Profile | null;
  wallet: Wallet | null;
  transactions: Transaction[];
  onNavigate: (view: "activity" | "send" | "market", target?: string) => void;
};

const HIDE_KEY = "gibb-hide-balance";
const nf = (n: number) => new Intl.NumberFormat("de-CH").format(n);

// Zählt sanft zum echten Wert hoch (nur Darstellung – der angezeigte Endwert ist immer der echte)
function useCountUp(target: number) {
  const [value, setValue] = useState(target);
  const from = useRef(target);
  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const start = performance.now();
    const begin = from.current;
    let frame = 0;
    const step = (now: number) => {
      const t = reduce ? 1 : Math.min(1, (now - start) / 900);
      const eased = 1 - Math.pow(1 - t, 3);
      setValue(Math.round(begin + (target - begin) * eased));
      if (t < 1) frame = requestAnimationFrame(step); else from.current = target;
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [target]);
  return value;
}

// Konto-Dashboard: Begrüssung, Status, Guthaben (ausblendbar), Statistik, Guthaben-Verlauf und letzte Buchungen.
// Alle Zahlen stammen aus den geladenen Kontodaten; der Verlauf wird aus den echten Buchungen zurückgerechnet.
export function AccountHero({ userId, profile, wallet, transactions, onNavigate }: Props) {
  const [hidden, setHidden] = useState(() => { try { return window.localStorage.getItem(HIDE_KEY) === "1"; } catch { return false; } });
  const balance = wallet?.balance ?? 0;
  const shown = useCountUp(balance);
  const locked = wallet?.status === "locked";
  const name = profile?.display_name?.split(" ")[0] || profile?.username || "du";
  const hour = new Date().getHours();
  const greeting = hour < 11 ? "Guten Morgen" : hour < 17 ? "Hallo" : "Guten Abend";

  const stats = useMemo(() => {
    let inSum = 0, outSum = 0, inCount = 0, outCount = 0;
    for (const tx of transactions) {
      if (tx.receiver_user_id === userId) { inSum += tx.amount; inCount += 1; }
      if (tx.sender_user_id === userId) { outSum += tx.amount; outCount += 1; }
    }
    // Guthaben-Verlauf: vom aktuellen Stand rückwärts durch die geladenen Buchungen (neueste zuerst)
    const sorted = [...transactions].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()).slice(0, 30);
    const points = [balance];
    let running = balance;
    for (const tx of sorted) {
      if (tx.receiver_user_id === userId) running -= tx.amount;
      if (tx.sender_user_id === userId) running += tx.amount;
      points.push(Math.max(0, running));
    }
    return { inSum, outSum, inCount, outCount, history: points.reverse() };
  }, [transactions, userId, balance]);

  const recent = useMemo(() => [...transactions].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()).slice(0, 5), [transactions]);

  const toggle = () => {
    setHidden((h) => { const next = !h; try { window.localStorage.setItem(HIDE_KEY, next ? "1" : "0"); } catch { /* privat */ } return next; });
  };

  const w = 320, hgt = 70;
  const hist = stats.history;
  const max = Math.max(1, ...hist), min = Math.min(...hist);
  const pts = hist.map((v, i) => `${(i / Math.max(1, hist.length - 1)) * w},${hgt - 6 - ((v - min) / Math.max(1, max - min)) * (hgt - 12)}`).join(" ");

  return (
    <section className="acct" aria-labelledby="acct-title">
      <header className="acct-head">
        <div className="acct-hello">
          <BrandMark size={44} />
          <div>
            <span className="acct-kicker">DEIN KONTO</span>
            <h1 id="acct-title">{greeting}, {name}</h1>
          </div>
        </div>
        <div className="acct-status">
          <span className={`acct-chip ${locked ? "warn" : "ok"}`}><i aria-hidden="true" />{locked ? "Konto gesperrt" : "Konto aktiv"}</span>
          <span className="acct-chip"><i aria-hidden="true" className="role" />{profile?.role === "super_admin" ? "Owner" : profile?.role === "admin" ? "Admin" : "Mitglied"}</span>
        </div>
      </header>

      <div className="acct-grid">
        <article className="acct-balance" aria-live="polite">
          <div className="acct-balance-top">
            <span>Verfügbares Guthaben</span>
            <button type="button" className="acct-eye" onClick={toggle} aria-pressed={hidden} aria-label={hidden ? "Guthaben anzeigen" : "Guthaben ausblenden"}>
              {hidden
                ? <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18M10.6 10.6a2 2 0 0 0 2.8 2.8M9.9 5.1A10 10 0 0 1 12 5c5 0 9 4.5 10 7a12 12 0 0 1-3.1 4.2M6.1 6.1A12 12 0 0 0 2 12c1 2.5 5 7 10 7a9.6 9.6 0 0 0 4-.9" /></svg>
                : <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12c1-2.5 5-7 10-7s9 4.5 10 7c-1 2.5-5 7-10 7S3 14.5 2 12Z" /><circle cx="12" cy="12" r="3" /></svg>}
            </button>
          </div>
          <strong className="acct-amount">{hidden ? "••••••" : nf(shown)} <small>GIBB</small></strong>
          <span className="acct-sub">{hidden ? "Ausgeblendet" : `${nf(transactions.length)} Buchungen geladen`}</span>
          <svg className="acct-spark" viewBox={`0 0 ${w} ${hgt}`} preserveAspectRatio="none" role="img" aria-label={`Guthaben-Verlauf der letzten ${hist.length - 1} Buchungen`}>
            <defs><linearGradient id="acct-spark-fill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#3ee0ff" stopOpacity=".35" /><stop offset="1" stopColor="#3ee0ff" stopOpacity="0" /></linearGradient></defs>
            {hist.length > 1 && !hidden && <>
              <polygon points={`0,${hgt} ${pts} ${w},${hgt}`} fill="url(#acct-spark-fill)" />
              <polyline className="acct-spark-line" points={pts} fill="none" pathLength={1} />
            </>}
          </svg>
          <div className="acct-actions">
            <button type="button" className="primary compact" onClick={() => onNavigate("send", "send-coins")}>Senden</button>
            <button type="button" className="secondary compact" onClick={() => onNavigate("market")}>Markt</button>
            <button type="button" className="secondary compact" onClick={() => onNavigate("activity", "transactions")}>Alle Buchungen</button>
          </div>
        </article>

        <div className="acct-stats">
          <article><span>Eingänge</span><strong className="in">{hidden ? "•••" : `+${nf(stats.inSum)}`}</strong><small>{stats.inCount} Buchungen</small></article>
          <article><span>Ausgänge</span><strong className="out">{hidden ? "•••" : `−${nf(stats.outSum)}`}</strong><small>{stats.outCount} Buchungen</small></article>
          <article><span>Saldo der Buchungen</span><strong>{hidden ? "•••" : `${stats.inSum - stats.outSum >= 0 ? "+" : "−"}${nf(Math.abs(stats.inSum - stats.outSum))}`}</strong><small>aus den geladenen Buchungen</small></article>
        </div>

        <article className="acct-recent">
          <div className="acct-recent-head"><h2>Letzte Buchungen</h2><button type="button" className="acct-link" onClick={() => onNavigate("activity", "transactions")}>Alle ansehen →</button></div>
          {recent.length === 0 ? <p className="acct-empty">Noch keine Buchungen – sobald du GIBB sendest oder erhältst, erscheinen sie hier.</p> : (
            <ul>
              {recent.map((tx) => {
                const incoming = tx.receiver_user_id === userId;
                return (
                  <li key={tx.id} className={incoming ? "in" : "out"}>
                    <span className="acct-dir" aria-hidden="true">{incoming ? "↙" : "↗"}</span>
                    <span className="acct-who"><b>{incoming ? tx.sender_label || "System" : tx.receiver_label || "System"}</b><small>{new Date(tx.created_at).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })} · {tx.type?.replace(/_/g, " ").toLowerCase() || "transfer"}</small></span>
                    <span className="acct-amt">{hidden ? "•••" : `${incoming ? "+" : "−"}${nf(tx.amount)}`}</span>
                  </li>
                );
              })}
            </ul>
          )}
        </article>
      </div>
    </section>
  );
}
