"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";
import type { Transaction } from "../lib/types";

type UserReport = { report_id: string; transaction_id: string; category: string; description: string; status: string; resolution_note: string | null; created_at: string; updated_at: string };
type AdminReport = UserReport & { reporter_user_id: string; reporter_name: string; transaction_summary: string };
type Props = { transactions: Transaction[]; isAdmin: boolean };

const categories = [
  ["suspicious_transfer", "Verdächtige Überweisung"],
  ["wrong_recipient", "Falscher Empfänger"],
  ["harassment", "Belästigung oder Druck"],
  ["other", "Anderer Grund"],
] as const;

function reportError(message?: string) {
  if (message?.includes("report_already_exists")) return "Diese Transaktion hast du bereits gemeldet.";
  if (message?.includes("transaction_not_reportable")) return "Du kannst nur eigene Transaktionen melden.";
  if (message?.includes("invalid_report_description")) return "Beschreibe den Vorfall mit 10 bis 500 Zeichen.";
  if (message?.includes("mfa_required")) return "Bestätige zuerst deine Zwei-Faktor-Anmeldung.";
  return "Die Meldung konnte gerade nicht verarbeitet werden.";
}

function statusLabel(status: string) {
  if (status === "open") return "Offen";
  if (status === "reviewing") return "Wird geprüft";
  if (status === "resolved") return "Erledigt";
  return "Geschlossen";
}

export function AbuseReports({ transactions, isAdmin }: Props) {
  const [transactionId, setTransactionId] = useState("");
  const [category, setCategory] = useState<(typeof categories)[number][0]>("suspicious_transfer");
  const [description, setDescription] = useState("");
  const [myReports, setMyReports] = useState<UserReport[]>([]);
  const [adminReports, setAdminReports] = useState<AdminReport[]>([]);
  const [reviewNotes, setReviewNotes] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const visibleAdminReports = adminReports.filter((report) => report.status !== "dismissed");

  const loadReports = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const ownResult = await supabase.rpc("list_my_abuse_reports");
    if (ownResult.error) { setError(reportError(ownResult.error.message)); return; }
    setMyReports((ownResult.data ?? []) as UserReport[]);
    if (isAdmin) {
      const adminResult = await supabase.rpc("admin_list_abuse_reports", { p_status: null });
      if (adminResult.error) { setError(reportError(adminResult.error.message)); return; }
      setAdminReports((adminResult.data ?? []) as AdminReport[]);
    }
  }, [isAdmin]);

  useEffect(() => { const timer = window.setTimeout(() => void loadReports(), 0); return () => window.clearTimeout(timer); }, [loadReports]);

  async function submitReport(event: React.FormEvent) {
    event.preventDefault(); setBusy("submit"); setError(""); setMessage("");
    const supabase = getSupabase();
    const { error: submitError } = supabase
      ? await supabase.rpc("submit_abuse_report", { p_transaction_id: transactionId, p_category: category, p_description: description })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (submitError) { setError(reportError(submitError.message)); return; }
    setTransactionId(""); setDescription(""); setMessage("Deine Meldung wurde sicher an das Admin-Team übermittelt.");
    await loadReports();
  }

  async function review(reportId: string, status: "reviewing" | "resolved" | "dismissed") {
    setBusy(reportId); setError(""); setMessage("");
    const supabase = getSupabase();
    const { error: reviewError } = supabase
      ? await supabase.rpc("admin_review_abuse_report", { p_report_id: reportId, p_status: status, p_resolution_note: reviewNotes[reportId] || null })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (reviewError) { setError(reportError(reviewError.message)); return; }
    if (status === "dismissed") {
      setAdminReports((current) => current.filter((report) => report.report_id !== reportId));
      setMessage("Das Ticket wurde geschlossen und aus der Liste entfernt.");
      return;
    }
    setMessage("Der Meldungsstatus wurde aktualisiert.");
    await loadReports();
  }

  return <section className="card card-pad abuse-center" id="reports">
    <div className="section-heading"><div><span className="section-number">06</span><h2>Sicherheit & Meldungen</h2></div><small>Verdächtige Vorgänge nachvollziehbar melden</small></div>
    <div className="report-grid">
      <form className="report-form" onSubmit={submitReport}>
        <div><strong>Transaktion melden</strong><p>Admins können den Fall prüfen, aber keine Transaktion heimlich verändern.</p></div>
        <label>Betroffene Transaktion<select className="input" required value={transactionId} onChange={(event) => setTransactionId(event.target.value)}><option value="">Transaktion auswählen</option>{transactions.slice(0, 40).map((transaction) => <option value={transaction.id} key={transaction.id}>{transaction.sender_label} → {transaction.receiver_label} · {transaction.amount} GIBB</option>)}</select></label>
        <label>Grund<select className="input" value={category} onChange={(event) => setCategory(event.target.value as typeof category)}>{categories.map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label>
        <label>Beschreibung<textarea className="input report-textarea" minLength={10} maxLength={500} required value={description} onChange={(event) => setDescription(event.target.value)} placeholder="Was ist passiert? Keine Passwörter oder PINs eintragen." /></label>
        <button className="primary compact" disabled={busy !== ""}>Sicher melden</button>
      </form>
      <div className="my-report-list"><div className="group-list-heading"><strong>Meine Meldungen</strong><span>{myReports.length}</span></div>{myReports.length === 0 && <div className="empty">Noch keine Meldungen.</div>}{myReports.map((report) => <article className="report-row" key={report.report_id}><div><strong>{categories.find(([value]) => value === report.category)?.[1] ?? "Meldung"}</strong><small>{report.description}</small>{report.resolution_note && <p>Antwort: {report.resolution_note}</p>}</div><span className={`report-status ${report.status}`}>{statusLabel(report.status)}</span></article>)}</div>
    </div>

    {isAdmin && <div className="admin-report-review"><div className="group-list-heading"><strong>Admin-Prüfbereich</strong><span>{visibleAdminReports.filter((report) => report.status === "open" || report.status === "reviewing").length} aktiv</span></div>{visibleAdminReports.length === 0 && <div className="empty">Keine Meldungen zu prüfen.</div>}{visibleAdminReports.map((report) => <article className="admin-report-row" key={report.report_id}><div className="admin-report-copy"><span>{report.reporter_name} · {new Date(report.created_at).toLocaleDateString("de-CH")}</span><strong>{report.transaction_summary}</strong><p>{report.description}</p></div><div className="admin-report-actions"><textarea className="input" maxLength={500} value={reviewNotes[report.report_id] ?? report.resolution_note ?? ""} onChange={(event) => setReviewNotes((current) => ({ ...current, [report.report_id]: event.target.value }))} placeholder="Interne Antwort an meldende Person" /><div><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void review(report.report_id, "reviewing")}>Prüfen</button><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void review(report.report_id, "resolved")}>Erledigt</button><button className="admin-danger compact" type="button" disabled={busy !== ""} onClick={() => void review(report.report_id, "dismissed")}>Schliessen</button></div></div></article>)}</div>}
    {message && <p className="message" role="status">✓ {message}</p>}{error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
