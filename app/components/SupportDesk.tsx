"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type SupportCase = {
  id: string; subject: string; body: string; status: "open" | "in_progress" | "waiting" | "closed";
  priority: "low" | "normal" | "high" | "urgent"; created_at: string; updated_at: string; requester: string; assigned: string | null;
};

const statusLabel: Record<SupportCase["status"], string> = { open: "Offen", in_progress: "In Arbeit", waiting: "Wartet", closed: "Geschlossen" };
const priorityLabel: Record<SupportCase["priority"], string> = { low: "Niedrig", normal: "Normal", high: "Hoch", urgent: "Dringend" };

// Owner-Rang: Support-Tickets aller Nutzer sehen, beantworten und abschliessen.
export function SupportDesk() {
  const [cases, setCases] = useState<SupportCase[]>([]);
  const [filter, setFilter] = useState<"open" | "all">("open");
  const [replies, setReplies] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const { data, error: rpcError } = await supabase.rpc("support_list_cases", { p_status: null });
    if (rpcError) { setError("Die Support-Tickets konnten nicht geladen werden."); return; }
    setError("");
    setCases((data ?? []) as SupportCase[]);
  }, []);

  useEffect(() => {
    const first = window.setTimeout(() => void load(), 0);
    const timer = window.setInterval(() => void load(), 30_000);
    return () => { window.clearTimeout(first); window.clearInterval(timer); };
  }, [load]);

  const update = async (item: SupportCase, status: SupportCase["status"], priority: SupportCase["priority"]) => {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(item.id); setError(""); setMessage("");
    const reply = replies[item.id] ?? "";
    const { data, error: rpcError } = await supabase.rpc("support_update_case", { p_case_id: item.id, p_status: status, p_priority: priority, p_reply: reply });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Das Ticket konnte nicht gespeichert werden."); return; }
    setReplies((current) => ({ ...current, [item.id]: "" }));
    setMessage(reply ? "Antwort gesendet." : "Ticket gespeichert.");
    await load();
  };

  const shown = filter === "open" ? cases.filter((item) => item.status !== "closed") : cases;

  return (
    <section className="card card-pad support-desk">
      <div className="card-head"><h2>Support-Tickets</h2><span>{cases.filter((item) => item.status !== "closed").length} offen</span></div>
      <div className="support-filter">
        <button type="button" className={filter === "open" ? "active" : ""} onClick={() => setFilter("open")}>Offene</button>
        <button type="button" className={filter === "all" ? "active" : ""} onClick={() => setFilter("all")}>Alle</button>
      </div>
      {error && <div className="message error">{error}</div>}
      {message && !error && <div className="message">{message}</div>}
      <div className="support-list">
        {shown.map((item) => (
          <article key={item.id} className={`support-case ${item.status}`}>
            <header>
              <strong>{item.subject}</strong>
              <span>{item.requester} · {new Date(item.created_at).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })}{item.assigned ? ` · bearbeitet von ${item.assigned}` : ""}</span>
            </header>
            <p>{item.body}</p>
            <div className="support-controls">
              <label className="field"><span>Status</span>
                <select className="input" value={item.status} disabled={busy === item.id} onChange={(event) => void update(item, event.target.value as SupportCase["status"], item.priority)}>
                  {(Object.keys(statusLabel) as SupportCase["status"][]).map((key) => <option key={key} value={key}>{statusLabel[key]}</option>)}
                </select>
              </label>
              <label className="field"><span>Priorität</span>
                <select className="input" value={item.priority} disabled={busy === item.id} onChange={(event) => void update(item, item.status, event.target.value as SupportCase["priority"])}>
                  {(Object.keys(priorityLabel) as SupportCase["priority"][]).map((key) => <option key={key} value={key}>{priorityLabel[key]}</option>)}
                </select>
              </label>
            </div>
            <label className="field"><span>Antwort an {item.requester}</span>
              <textarea className="input" rows={2} maxLength={1000} value={replies[item.id] ?? ""} onChange={(event) => setReplies((current) => ({ ...current, [item.id]: event.target.value }))} placeholder="Antwort schreiben – kommt als Mitteilung an" />
            </label>
            <div className="support-actions">
              <button className="primary compact" type="button" disabled={busy === item.id || !(replies[item.id] ?? "").trim()} onClick={() => void update(item, item.status === "open" ? "in_progress" : item.status, item.priority)}>Antworten</button>
              {item.status !== "closed" && <button className="secondary compact" type="button" disabled={busy === item.id} onClick={() => void update(item, "closed", item.priority)}>Abschliessen</button>}
            </div>
          </article>
        ))}
        {!shown.length && <p className="field-hint">{filter === "open" ? "Keine offenen Tickets. 🎉" : "Noch keine Tickets."}</p>}
      </div>
    </section>
  );
}
