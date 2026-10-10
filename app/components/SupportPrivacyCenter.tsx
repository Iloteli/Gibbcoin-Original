"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type SupportCase = { id: string; subject: string; status: string; priority: string; updated_at: string };
type RequestItem = { id: string; status: string; format?: string; request_type?: string; created_at: string };

const statusLabels: Record<string, string> = {
  open: "Offen", in_progress: "In Arbeit", waiting: "Wartet auf Rückmeldung", closed: "Geschlossen",
  requested: "Angefragt", processing: "Wird vorbereitet", ready: "Bereit", expired: "Abgelaufen",
  rejected: "Abgelehnt", completed: "Abgeschlossen",
};

export function SupportPrivacyCenter() {
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [category, setCategory] = useState("Konto & Anmeldung");
  const [priority, setPriority] = useState("normal");
  const [note, setNote] = useState("");
  const [cases, setCases] = useState<SupportCase[]>([]);
  const [exports, setExports] = useState<RequestItem[]>([]);
  const [privacy, setPrivacy] = useState<RequestItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const loadRequests = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) { setLoading(false); return; }
    const [caseResult, exportResult, privacyResult] = await Promise.all([
      supabase.from("support_cases").select("id,subject,status,priority,updated_at").order("updated_at", { ascending: false }).limit(5),
      supabase.from("admin_export_requests").select("id,status,format,created_at").order("created_at", { ascending: false }).limit(5),
      supabase.from("privacy_requests").select("id,status,request_type,created_at").order("created_at", { ascending: false }).limit(5),
    ]);
    setLoading(false);
    if (caseResult.error || exportResult.error || privacyResult.error) {
      setError("Der aktuelle Anfrage-Status konnte nicht geladen werden.");
      return;
    }
    setCases((caseResult.data ?? []) as SupportCase[]);
    setExports((exportResult.data ?? []) as RequestItem[]);
    setPrivacy((privacyResult.data ?? []) as RequestItem[]);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadRequests(), 0);
    return () => window.clearTimeout(timer);
  }, [loadRequests]);

  async function submit(kind: "support" | "export" | "privacy", type?: string) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(kind); setMessage(""); setError("");
    const result = kind === "support"
      ? await supabase.from("support_cases").insert({
        subject: subject.trim(), body: `Kategorie: ${category}\n\n${body.trim()}`, priority,
      })
      : kind === "export"
        ? await supabase.rpc("request_data_export", { p_format: type ?? "json" })
        : await supabase.rpc("create_privacy_request", { p_type: type, p_note: note.trim() || null });
    setBusy("");
    const rpcResult = result.data as { ok?: boolean; error?: string } | null;
    if (result.error || (kind !== "support" && !rpcResult?.ok)) {
      setError("Die Anfrage konnte nicht gespeichert werden. Prüfe die Angaben und versuche es erneut.");
      return;
    }
    setSubject(""); setBody(""); setNote("");
    setMessage(kind === "support" ? "Dein Support-Fall wurde eröffnet." : "Deine Anfrage wurde sicher erfasst.");
    await loadRequests();
  }

  return <section className="card card-pad" aria-labelledby="support-privacy-title">
    <div className="section-heading compact-heading"><div><span className="section-number">HILFE</span><h2 id="support-privacy-title">Support & Datenschutz</h2></div></div>
    <div className="admin-control-tools">
      <form className="admin-operation" onSubmit={(event) => { event.preventDefault(); void submit("support"); }}>
        <h3>Support-Fall eröffnen</h3><p>Wähle ein Thema und beschreibe den Kontext (z. B. Gerät, Zeitpunkt oder betroffene Transaktion).</p>
        <select className="input" value={category} onChange={(event) => setCategory(event.target.value)} aria-label="Support-Kategorie"><option>Konto & Anmeldung</option><option>Überweisung & Wallet</option><option>Spiel, Shop & Belohnungen</option><option>Sicherheit & Missbrauch</option><option>Sonstiges</option></select>
        <select className="input" value={priority} onChange={(event) => setPriority(event.target.value)} aria-label="Support-Priorität"><option value="low">Niedrige Priorität</option><option value="normal">Normale Priorität</option><option value="high">Hohe Priorität</option><option value="urgent">Dringend</option></select>
        <input className="input" required minLength={3} maxLength={120} value={subject} onChange={(event) => setSubject(event.target.value)} placeholder="Betreff" />
        <textarea className="input" required minLength={3} maxLength={4900} rows={3} value={body} onChange={(event) => setBody(event.target.value)} placeholder="Was ist passiert? Bitte keine Passwörter oder PINs senden." />
        <button className="primary compact" disabled={busy !== ""}>Support anfragen</button>
      </form>
      <article className="admin-operation">
        <h3>Datenexport</h3><p>Fordere eine Kopie deiner Wallet- und Profildaten an. Die Datei wird erst als <strong>Bereit</strong> angezeigt, wenn der Server sie erstellt hat.</p>
        <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void submit("export", "json")}>JSON-Export anfordern</button>
        <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void submit("export", "csv")}>CSV-Export anfordern</button>
      </article>
      <form className="admin-operation" onSubmit={(event) => { event.preventDefault(); void submit("privacy", (event.currentTarget.elements.namedItem("privacy-type") as HTMLSelectElement).value); }}>
        <h3>Datenschutzanfrage</h3><p>Auskunft und Korrekturen werden geprüft. Bei einer Löschung wird dein Zugang deaktiviert; gesetzliche Nachweise können anonymisiert aufbewahrt werden.</p>
        <select className="input" name="privacy-type" defaultValue="access"><option value="access">Auskunft anfordern</option><option value="correction">Daten korrigieren</option><option value="deletion">Konto löschen lassen</option></select>
        <textarea className="input" rows={2} maxLength={1000} value={note} onChange={(event) => setNote(event.target.value)} placeholder="Anmerkung (optional)" />
        <button className="secondary compact" disabled={busy !== ""}>Anfrage senden</button>
      </form>
    </div>
    <div className="admin-control-tools" aria-label="Status deiner Anfragen">
      <article className="admin-operation"><h3>Support-Status</h3>{loading ? <p>Wird geladen …</p> : cases.length ? cases.map((item) => <p key={item.id}><strong>{item.subject}</strong> · {statusLabels[item.status] ?? item.status} · {statusLabels[item.priority] ?? item.priority}</p>) : <p>Noch keine Support-Fälle. Für einen Missbrauchsverdacht nutze <a href="#community">Meldung einreichen</a>.</p>}</article>
      <article className="admin-operation"><h3>Export-Status</h3>{loading ? <p>Wird geladen …</p> : exports.length ? exports.map((item) => <p key={item.id}>{item.format?.toUpperCase()} · {statusLabels[item.status] ?? item.status}</p>) : <p>Noch keine Exporte angefragt.</p>}</article>
      <article className="admin-operation"><h3>Datenschutz-Status</h3>{loading ? <p>Wird geladen …</p> : privacy.length ? privacy.map((item) => <p key={item.id}>{item.request_type} · {statusLabels[item.status] ?? item.status}</p>) : <p>Noch keine Datenschutzanfragen.</p>}</article>
    </div>
    {message && <p className="message success-message" role="status">{message}</p>}
    {error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
