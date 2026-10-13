"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { openUserProfile } from "./UserProfileModal";

type Period = "week" | "month" | "all";
type Entry = {
  user_id: string; username: string; display_name: string; profile_color: string | null; equipped_title: string | null;
  achievements: number; tasks: number; check_ins: number; blocks: number; points: number; rank: number;
};
type Board = { period: Period; entries: Entry[]; me: Entry | null };

const PERIODS: Array<{ key: Period; label: string }> = [
  { key: "week", label: "Diese Woche" },
  { key: "month", label: "Dieser Monat" },
  { key: "all", label: "Gesamt" },
];

export function CommunityLeaderboard({ userId }: { userId: string }) {
  const [period, setPeriod] = useState<Period>("week");
  const [board, setBoard] = useState<Board | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const load = useCallback(async (next: Period) => {
    const supabase = getSupabase();
    if (!supabase) return;
    setLoading(true);
    const { data, error: rpcError } = await supabase.rpc("get_community_leaderboard", { p_period: next });
    setLoading(false);
    if (rpcError) { setError("Die Rangliste ist noch nicht verfügbar (Datenbank-Update fehlt)."); return; }
    setError("");
    setBoard(data as Board);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(period), 0);
    return () => window.clearTimeout(timer);
  }, [load, period]);

  const entries = board?.entries ?? [];
  const podium = entries.slice(0, 3);
  const rest = entries.slice(3);
  const me = board?.me;

  return (
    <section className="card card-pad community-leaderboard" aria-label="Rangliste">
      <div className="card-head">
        <h2>Rangliste</h2>
        <div className="segmented" role="tablist" aria-label="Zeitraum">
          {PERIODS.map((p) => (
            <button key={p.key} type="button" role="tab" aria-selected={period === p.key} className={period === p.key ? "active" : ""} onClick={() => setPeriod(p.key)}>{p.label}</button>
          ))}
        </div>
      </div>
      <p className="field-hint">Punkte: Erfolg 10 · Tagesaufgabe 3 · gefundener Block 2 · täglicher Check-in 1. Kontostände werden nicht angezeigt.</p>
      {error && <div className="message error">{error}</div>}

      {me && (
        <div className="lb-me">
          <div><span>Dein Rang</span><strong>{me.points > 0 ? `#${me.rank}` : "–"}</strong></div>
          <div><span>Punkte</span><strong>{me.points}</strong></div>
          <div><span>Erfolge</span><strong>{me.achievements}</strong></div>
          <div><span>Aufgaben</span><strong>{me.tasks}</strong></div>
          <div><span>Blöcke</span><strong>{me.blocks}</strong></div>
        </div>
      )}

      {!error && !loading && entries.length === 0 && <div className="empty">In diesem Zeitraum hat noch niemand Punkte – hol dir den Tagesbonus und sei vorne!</div>}

      {podium.length > 0 && (
        <ol className="lb-podium">
          {podium.map((e, i) => (
            <li key={e.user_id} className={`place-${i + 1}${e.user_id === userId ? " you" : ""}`}>
              <button type="button" onClick={() => openUserProfile(e.user_id)} title="Profil ansehen">
                <span className="lb-medal" aria-hidden="true">{["🥇", "🥈", "🥉"][i]}</span>
                <span className="lb-avatar" style={{ background: e.profile_color ?? undefined }} aria-hidden="true">{(e.username || "?").slice(0, 1).toUpperCase()}</span>
                <strong>{e.username}{e.user_id === userId ? " (du)" : ""}</strong>
                {e.equipped_title && <small>{e.equipped_title}</small>}
                <b>{e.points} Punkte</b>
              </button>
            </li>
          ))}
        </ol>
      )}

      {rest.length > 0 && (
        <ol className="lb-list" start={4}>
          {rest.map((e) => (
            <li key={e.user_id} className={e.user_id === userId ? "you" : ""}>
              <span className="lb-rank">#{e.rank}</span>
              <button type="button" className="lb-name" onClick={() => openUserProfile(e.user_id)}>
                <span className="lb-avatar small" style={{ background: e.profile_color ?? undefined }} aria-hidden="true">{(e.username || "?").slice(0, 1).toUpperCase()}</span>
                {e.username}{e.user_id === userId ? " (du)" : ""}
              </button>
              <span className="lb-detail">{e.achievements} Erfolge · {e.tasks} Aufgaben · {e.blocks} Blöcke</span>
              <b>{e.points}</b>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
