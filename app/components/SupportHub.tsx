"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";
import type { Transaction } from "../lib/types";

// Ein Support-Bereich für alles: Fragen/Probleme, gemeldete Transaktionen, Datenexport und Datenschutz.
// Owner bearbeiten darunter alle Anliegen.

type Kind = "ticket" | "report";
type MyItem = { kind: Kind; id: string; subject: string; status: string; updated_at: string; note?: string | null };
type DeskItem = {
  kind: Kind; id: string; subject: string; body: string; status: string; priority: string; created_at: string;
  requester: string; assigned?: string | null; transaction?: string; note?: string | null; done: boolean;
};
type RequestItem = { id: string; status: string; format?: string; request_type?: string; created_at: string };

const statusLabels: Record<string, string> = {
  open: "Offen", in_progress: "In Arbeit", waiting: "Wartet auf Rückmeldung", closed: "Geschlossen",
  reviewing: "Wird geprüft", resolved: "Erledigt", dismissed: "Geschlossen",
  requested: "Angefragt", processing: "Wird vorbereitet", ready: "Bereit", expired: "Abgelaufen", rejected: "Abgelehnt", completed: "Abgeschlossen",
};
const ticketStatuses = ["open", "in_progress", "waiting", "closed"];
const reportStatuses = ["open", "reviewing", "resolved", "dismissed"];
const priorities: Array<[string, string]> = [["low", "Niedrig"], ["normal", "Normal"], ["high", "Hoch"], ["urgent", "Dringend"]];
const topics = ["Konto & Anmeldung", "Überweisung & Wallet", "Spiel & Belohnungen", "Kaufen & Bezahlen", "Sonstiges"];
const reportCategories: Array<[string, string]> = [["suspicious_transfer", "Verdächtige Überweisung"], ["wrong_recipient", "Falscher Empfänger"], ["harassment", "Belästigung oder Druck"], ["other", "Anderer Grund"]];

function errorText(message?: string) {
  if (message?.includes("report_already_exists")) return "Diese Transaktion hast du bereits gemeldet.";
  if (message?.includes("transaction_not_reportable")) return "Du kannst nur eigene Transaktionen melden.";
  if (message?.includes("invalid_report_description")) return "Beschreibe den Vorfall mit 10 bis 500 Zeichen.";
  return "Das hat nicht geklappt. Prüfe die Angaben und versuche es erneut.";
}

export function SupportHub({ transactions, isOwner }: { transactions: Transaction[]; isOwner: boolean }) {
  const [kind, setKind] = useState<Kind>("ticket");
  const [topic, setTopic] = useState(topics[0]);
  const [priority, setPriority] = useState("normal");
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [transactionId, setTransactionId] = useState("");
  const [category, setCategory] = useState(reportCategories[0][0]);
  const [mine, setMine] = useState<MyItem[]>([]);
  const [exports, setExports] = useState<RequestItem[]>([]);
  const [privacy, setPrivacy] = useState<RequestItem[]>([]);
  const [privacyNote, setPrivacyNote] = useState("");
  const [desk, setDesk] = useState<DeskItem[]>([]);
  const [deskFilter, setDeskFilter] = useState<"open" | "all">("open");
  const [replies, setReplies] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [canDesk, setCanDesk] = useState(false);

  const load = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const [cases, reports, exportResult, privacyResult] = await Promise.all([
      supabase.from("support_cases").select("id,subject,status,updated_at").order("updated_at", { ascending: false }).limit(20),
      supabase.rpc("list_my_abuse_reports"),
      supabase.from("admin_export_requests").select("id,status,format,created_at").order("created_at", { ascending: false }).limit(5),
      supabase.from("privacy_requests").select("id,status,request_type,created_at").order("created_at", { ascending: false }).limit(5),
    ]);
    const items: MyItem[] = [
      ...((cases.data ?? []) as Array<{ id: string; subject: string; status: string; updated_at: string }>).map((c) => ({ kind: "ticket" as const, ...c })),
      ...((reports.data ?? []) as Array<{ report_id: string; category: string; status: string; updated_at: string; resolution_note: string | null }>).map((r) => ({
        kind: "report" as const, id: r.report_id, subject: `Gemeldete Transaktion · ${reportCategories.find(([key]) => key === r.category)?.[1] ?? "Anderer Grund"}`,
        status: r.status, updated_at: r.updated_at, note: r.resolution_note,
      })),
    ].sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    setMine(items);
    setExports((exportResult.data ?? []) as RequestItem[]);
    setPrivacy((privacyResult.data ?? []) as RequestItem[]);
    if (isOwner) {
      const access = await supabase.rpc("get_support_access");
      const allowed = !access.error && access.data === true;
      setCanDesk(allowed);
      if (allowed) {
        const { data } = await supabase.rpc("support_list_all");
        setDesk((data ?? []) as DeskItem[]);
      }
    }
  }, [isOwner]);

  useEffect(() => {
    const first = window.setTimeout(() => void load(), 0);
    const timer = window.setInterval(() => void load(), 30_000);
    return () => { window.clearTimeout(first); window.clearInterval(timer); };
  }, [load]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy("submit"); setError(""); setMessage("");
    const result = kind === "ticket"
      ? await supabase.from("support_cases").insert({ subject: subject.trim(), body: `Thema: ${topic}\n\n${body.trim()}`, priority })
      : await supabase.rpc("submit_abuse_report", { p_transaction_id: transactionId, p_category: category, p_description: body.trim() });
    setBusy("");
    if (result.error) { setError(errorText(result.error.message)); return; }
    setSubject(""); setBody(""); setTransactionId("");
    setMessage(kind === "ticket" ? "Dein Anliegen wurde an den Support geschickt." : "Deine Meldung wurde an den Support geschickt.");
    await load();
  }

  async function requestData(type: "export" | "privacy", value: string) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(type); setError(""); setMessage("");
    const result = type === "export"
      ? await supabase.rpc("request_data_export", { p_format: value })
      : await supabase.rpc("create_privacy_request", { p_type: value, p_note: privacyNote.trim() || null });
    setBusy("");
    if (result.error || !(result.data as { ok?: boolean } | null)?.ok) { setError(errorText()); return; }
    setPrivacyNote("");
    setMessage("Deine Anfrage wurde erfasst.");
    await load();
  }

  async function updateDesk(item: DeskItem, status: string, priorityValue: string) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(item.id); setError(""); setMessage("");
    const reply = replies[item.id] ?? "";
    const result = item.kind === "ticket"
      ? await supabase.rpc("support_update_case", { p_case_id: item.id, p_status: status, p_priority: priorityValue, p_reply: reply })
      : await supabase.rpc("support_update_report", { p_report_id: item.id, p_status: status, p_reply: reply });
    setBusy("");
    if (result.error || !(result.data as { ok?: boolean } | null)?.ok) { setError("Das Anliegen konnte nicht gespeichert werden."); return; }
    setReplies((current) => ({ ...current, [item.id]: "" }));
    setMessage(reply ? "Antwort gesendet." : "Gespeichert.");
    await load();
  }

  const deskShown = deskFilter === "open" ? desk.filter((item) => !item.done) : desk;

  return (
    <section className="card card-pad support-hub" id="support">
      <div className="section-heading compact-heading"><div><span className="section-number">HILFE</span><h2>Support</h2></div><small>Fragen, Probleme und Meldungen an einem Ort</small></div>

      <div className="support-hub-grid">
        <form className="support-new" onSubmit={submit}>
          <strong>Neues Anliegen</strong>
          <div className="support-kind" role="tablist" aria-label="Art des Anliegens">
            <button type="button" role="tab" aria-selected={kind === "ticket"} className={kind === "ticket" ? "active" : ""} onClick={() => setKind("ticket")}>💬 Frage / Problem</button>
            <button type="button" role="tab" aria-selected={kind === "report"} className={kind === "report" ? "active" : ""} onClick={() => setKind("report")}>🛡 Transaktion melden</button>
          </div>
          {kind === "ticket" ? <>
            <label className="field"><span>Thema</span><select className="input" value={topic} onChange={(event) => setTopic(event.target.value)}>{topics.map((t) => <option key={t}>{t}</option>)}</select></label>
            <label className="field"><span>Dringlichkeit</span><select className="input" value={priority} onChange={(event) => setPriority(event.target.value)}>{priorities.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
            <label className="field"><span>Betreff</span><input className="input" required minLength={3} maxLength={120} value={subject} onChange={(event) => setSubject(event.target.value)} placeholder="Kurz: worum geht es?" /></label>
          </> : <>
            <label className="field"><span>Betroffene Transaktion</span><select className="input" required value={transactionId} onChange={(event) => setTransactionId(event.target.value)}><option value="">Transaktion auswählen</option>{transactions.slice(0, 40).map((t) => <option key={t.id} value={t.id}>{new Date(t.created_at).toLocaleDateString("de-CH")} · {t.amount} GIBB · {t.note || t.type}</option>)}</select></label>
            <label className="field"><span>Grund</span><select className="input" value={category} onChange={(event) => setCategory(event.target.value)}>{reportCategories.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
          </>}
          <label className="field"><span>Beschreibung</span><textarea className="input" required minLength={kind === "report" ? 10 : 3} maxLength={kind === "report" ? 500 : 4900} rows={3} value={body} onChange={(event) => setBody(event.target.value)} placeholder="Was ist passiert? Bitte keine Passwörter oder PINs senden." /></label>
          <button className="primary compact" disabled={busy !== ""}>{busy === "submit" ? "Wird gesendet …" : "An den Support senden"}</button>
        </form>

        <div className="support-mine">
          <strong>Meine Anliegen</strong>
          {mine.length === 0 && <p className="field-hint">Noch keine Anliegen.</p>}
          {mine.map((item) => (
            <div key={`${item.kind}-${item.id}`} className={`support-mine-row ${item.status}`}>
              <div><b>{item.subject}</b><small>{new Date(item.updated_at).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })}{item.note ? ` · ${item.note}` : ""}</small></div>
              <span>{statusLabels[item.status] ?? item.status}</span>
            </div>
          ))}
          <p className="field-hint">Antworten vom Support bekommst du als Mitteilung (🔔).</p>
        </div>
      </div>

      <details className="support-privacy">
        <summary>Meine Daten & Datenschutz</summary>
        <div className="support-privacy-grid">
          <div>
            <p>Kopie deiner Wallet- und Profildaten anfordern:</p>
            <div className="support-actions">
              <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void requestData("export", "json")}>JSON-Export</button>
              <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void requestData("export", "csv")}>CSV-Export</button>
            </div>
            {exports.map((item) => <small key={item.id} className="field-hint">{item.format?.toUpperCase()} · {statusLabels[item.status] ?? item.status}</small>)}
          </div>
          <form onSubmit={(event) => { event.preventDefault(); void requestData("privacy", (event.currentTarget.elements.namedItem("privacy-type") as HTMLSelectElement).value); }}>
            <p>Datenschutzanfrage:</p>
            <select className="input" name="privacy-type" defaultValue="access"><option value="access">Auskunft anfordern</option><option value="correction">Daten korrigieren</option><option value="deletion">Konto löschen lassen</option></select>
            <textarea className="input" rows={2} maxLength={1000} value={privacyNote} onChange={(event) => setPrivacyNote(event.target.value)} placeholder="Anmerkung (optional)" />
            <button className="secondary compact" disabled={busy !== ""}>Anfrage senden</button>
            {privacy.map((item) => <small key={item.id} className="field-hint">{item.request_type} · {statusLabels[item.status] ?? item.status}</small>)}
          </form>
        </div>
      </details>

      {isOwner && canDesk && (
        <div className="support-desk">
          <div className="card-head"><h2>Support bearbeiten</h2><span>{desk.filter((item) => !item.done).length} offen</span></div>
          <div className="support-filter">
            <button type="button" className={deskFilter === "open" ? "active" : ""} onClick={() => setDeskFilter("open")}>Offene</button>
            <button type="button" className={deskFilter === "all" ? "active" : ""} onClick={() => setDeskFilter("all")}>Alle</button>
          </div>
          <div className="support-list">
            {deskShown.map((item) => (
              <article key={`${item.kind}-${item.id}`} className={`support-case ${item.done ? "closed" : ""}`}>
                <header>
                  <strong>{item.kind === "report" ? "🛡 " : "💬 "}{item.subject}</strong>
                  <span>{item.requester} · {new Date(item.created_at).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })}{item.assigned ? ` · bearbeitet von ${item.assigned}` : ""}</span>
                </header>
                {item.transaction && <small className="field-hint">Transaktion: {item.transaction}</small>}
                <p>{item.body}</p>
                <div className="support-controls">
                  <label className="field"><span>Status</span>
                    <select className="input" value={item.status} disabled={busy === item.id} onChange={(event) => void updateDesk(item, event.target.value, item.priority)}>
                      {(item.kind === "ticket" ? ticketStatuses : reportStatuses).map((key) => <option key={key} value={key}>{statusLabels[key]}</option>)}
                    </select>
                  </label>
                  {item.kind === "ticket" && <label className="field"><span>Priorität</span>
                    <select className="input" value={item.priority} disabled={busy === item.id} onChange={(event) => void updateDesk(item, item.status, event.target.value)}>
                      {priorities.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                    </select>
                  </label>}
                </div>
                <label className="field"><span>Antwort an {item.requester}</span>
                  <textarea className="input" rows={2} maxLength={item.kind === "report" ? 500 : 1000} value={replies[item.id] ?? ""} onChange={(event) => setReplies((current) => ({ ...current, [item.id]: event.target.value }))} placeholder="Antwort schreiben – kommt als Mitteilung an" />
                </label>
                <div className="support-actions">
                  <button className="primary compact" type="button" disabled={busy === item.id || !(replies[item.id] ?? "").trim()} onClick={() => void updateDesk(item, item.kind === "ticket" ? (item.status === "open" ? "in_progress" : item.status) : (item.status === "open" ? "reviewing" : item.status), item.priority)}>Antworten</button>
                  {!item.done && <button className="secondary compact" type="button" disabled={busy === item.id} onClick={() => void updateDesk(item, item.kind === "ticket" ? "closed" : "resolved", item.priority)}>Abschliessen</button>}
                </div>
              </article>
            ))}
            {!deskShown.length && <p className="field-hint">{deskFilter === "open" ? "Keine offenen Anliegen. 🎉" : "Noch keine Anliegen."}</p>}
          </div>
        </div>
      )}

      {message && <p className="message success-message" role="status">{message}</p>}
      {error && <p className="message error" role="alert">{error}</p>}
    </section>
  );
}
