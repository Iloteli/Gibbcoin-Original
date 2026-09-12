"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type DailyTask = { task_key: string; name: string; description: string; target_count: number; progress: number; reward: number; claimed: boolean };
type Challenge = { id: string; slug: string; name: string; description: string; target_count: number; reward: number };
type Progress = { challenge_id: string; progress: number; target_count: number; claimed: boolean };
type Item = { id: string; name: string; description: string; price: number; icon: string; kind: "title" | "color"; cosmetic_value: string; stock: number | null };
type SeasonEntry = { rank: number; username: string; points: number; wins: number; is_me: boolean };
type SeasonState = { season: { name: string; ends_at: string; rewards: number[] }; entries: SeasonEntry[]; my_entry: SeasonEntry | null };
type Props = { userId: string; walletBalance: number; onChanged: () => Promise<void> };

function rewardError(message?: string) {
  if (message?.includes("already")) return "Diese Belohnung wurde bereits abgeholt.";
  if (message?.includes("not_completed")) return "Das Ziel ist noch nicht erreicht.";
  if (message?.includes("insufficient")) return "Dein Guthaben reicht für diesen Artikel nicht aus.";
  if (message?.includes("no_finished_season")) return "Es gibt noch keine abgeschlossene Saison.";
  if (message?.includes("no_season_reward")) return "Für die letzte Saison ist keine Podest-Prämie verfügbar.";
  return "Die Aktion konnte gerade nicht abgeschlossen werden.";
}

export function RewardsHub({ userId, walletBalance, onChanged }: Props) {
  const [tasks, setTasks] = useState<DailyTask[]>([]);
  const [challenges, setChallenges] = useState<Challenge[]>([]);
  const [progress, setProgress] = useState<Map<string, Progress>>(new Map());
  const [items, setItems] = useState<Item[]>([]);
  const [owned, setOwned] = useState<Set<string>>(new Set());
  const [season, setSeason] = useState<SeasonState | null>(null);
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    const supabase = getSupabase(); if (!supabase) return;
    const [taskResult, challengeResult, progressResult, itemResult, purchaseResult, seasonResult] = await Promise.all([
      supabase.rpc("get_daily_tasks"),
      supabase.from("challenges").select("id,slug,name,description,target_count,reward").eq("active", true).order("created_at"),
      supabase.rpc("get_challenge_progress"),
      supabase.from("marketplace_items").select("id,name,description,price,icon,kind,cosmetic_value,stock").eq("active", true).order("price"),
      supabase.from("purchases").select("item_id").eq("user_id", userId),
      supabase.rpc("get_season_state"),
    ]);
    const firstError = [taskResult, challengeResult, progressResult, itemResult, purchaseResult, seasonResult].find((result) => result.error)?.error;
    if (firstError) { setError("Aufgaben, Shop oder Saison konnten nicht vollständig geladen werden."); return; }
    setTasks(((taskResult.data as { tasks?: DailyTask[] } | null)?.tasks ?? []));
    setChallenges((challengeResult.data ?? []) as Challenge[]);
    setProgress(new Map(((progressResult.data ?? []) as Progress[]).map((item) => [item.challenge_id, item])));
    setItems((itemResult.data ?? []) as Item[]);
    setOwned(new Set(((purchaseResult.data ?? []) as Array<{ item_id: string }>).map((item) => item.item_id)));
    setSeason(seasonResult.data as SeasonState);
  }, [userId]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function act(key: string, rpc: string, args?: Record<string, unknown>) {
    const supabase = getSupabase(); if (!supabase) return;
    setBusy(key); setMessage(""); setError("");
    const { data, error: rpcError } = await supabase.rpc(rpc, args);
    setBusy("");
    if (rpcError) { setError(rewardError(rpcError.message)); return; }
    const reward = Number(Array.isArray(data) ? (data[0] as { amount?: number })?.amount ?? 0 : (data as { reward?: number } | null)?.reward ?? 0);
    setMessage(reward > 0 ? `Belohnung abgeholt: +${reward} GIBB.` : "Erfolgreich gespeichert.");
    await Promise.all([load(), onChanged()]);
  }

  return <section className="rewards-hub" id="rewards-hub">
    <div className="section-heading"><div><span className="section-number">REWARDS</span><h2>Aufgaben, Erfolge & Shop</h2></div><span>{walletBalance.toLocaleString("de-CH")} GIBB</span></div>
    <div className="reward-feature-grid">
      <article className="card card-pad daily-bonus"><span>TÄGLICHER CHECK-IN</span><h3>Dein täglicher Bonus</h3><p>Einmal pro Kalendertag abholen. Jede Buchung landet direkt in deinem Wallet.</p><button type="button" className="primary" disabled={busy !== ""} onClick={() => void act("daily", "claim_daily_reward")}>{busy === "daily" ? "Wird geprüft …" : "Tagesbonus abholen"}</button></article>
      <article className="card card-pad season-card"><span>LIVE SAISON</span><h3>{season?.season.name ?? "Campus Saison"}</h3><p>Ende: {season ? new Date(season.season.ends_at).toLocaleDateString("de-CH") : "–"} · Podest: {(season?.season.rewards ?? [300,150,75]).join(" / ")} GIBB</p><ol>{(season?.entries ?? []).slice(0, 5).map((entry) => <li className={entry.is_me ? "is-me" : ""} key={`${entry.rank}-${entry.username}`}><b>#{entry.rank}</b><span>{entry.username}</span><strong>{entry.points} P</strong></li>)}</ol><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void act("season", "claim_previous_season_reward")}>Letzte Saison-Prämie prüfen</button></article>
    </div>

    <div className="card card-pad"><h3>Tagesaufgaben</h3><div className="task-grid">{tasks.map((task) => { const ready = task.progress >= task.target_count; return <article key={task.task_key}><div><strong>{task.name}</strong><span>+{task.reward} GIBB</span></div><p>{task.description}</p><progress max={task.target_count} value={task.progress} /><small>{task.progress}/{task.target_count}</small><button className="secondary compact" type="button" disabled={!ready || task.claimed || busy !== ""} onClick={() => void act(`task-${task.task_key}`, "claim_daily_task", { p_task_key: task.task_key })}>{task.claimed ? "Abgeholt" : ready ? "Belohnung holen" : "Noch offen"}</button></article>; })}</div></div>

    <div className="card card-pad"><h3>Erfolge</h3><div className="achievement-grid">{challenges.map((challenge) => { const current = progress.get(challenge.id); const ready = (current?.progress ?? 0) >= challenge.target_count; return <article key={challenge.id}><span>◆</span><div><strong>{challenge.name}</strong><p>{challenge.description}</p><small>{current?.progress ?? 0}/{challenge.target_count} · +{challenge.reward} GIBB</small></div><button className="secondary compact" type="button" disabled={!ready || current?.claimed || busy !== ""} onClick={() => void act(`challenge-${challenge.id}`, "claim_challenge", { p_challenge_id: challenge.id })}>{current?.claimed ? "Erreicht" : ready ? "Abholen" : "Offen"}</button></article>; })}</div></div>

    <div className="card card-pad"><div className="shop-head"><div><h3>Campus-Shop</h3><p>Nur kosmetische Profil-Titel und Farben – keine Spielvorteile.</p></div><span>{owned.size} gekauft</span></div><div className="shop-grid">{items.map((item) => { const purchased = owned.has(item.id); return <article key={item.id} style={item.kind === "color" ? { borderColor: item.cosmetic_value } : undefined}><span className="shop-icon" style={item.kind === "color" ? { color: item.cosmetic_value } : undefined}>{item.icon}</span><strong>{item.name}</strong><p>{item.description}</p><small>{item.price} GIBB</small><button className={purchased ? "secondary compact" : "primary compact"} type="button" disabled={busy !== "" || (!purchased && walletBalance < item.price)} onClick={() => void act(`shop-${item.id}`, purchased ? "equip_marketplace_item" : "buy_marketplace_item", { p_item_id: item.id })}>{purchased ? "Ausrüsten" : "Kaufen"}</button></article>; })}</div></div>
    {message && <p className="message success-message" role="status">{message}</p>}{error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
