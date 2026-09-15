"use client";

import { useState } from "react";
import { getSupabase } from "../lib/supabase";

export function SupportPrivacyCenter() {
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function submit(kind: "support" | "export" | "privacy", type?: string) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(kind); setMessage(""); setError("");
    const result = kind === "support"
      ? await supabase.from("support_cases").insert({ subject: subject.trim(), body: body.trim() })
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
  }

  return <section className="card card-pad" aria-labelledby="support-privacy-title">
    <div className="section-heading compact-heading"><div><span className="section-number">HILFE</span><h2 id="support-privacy-title">Support & Datenschutz</h2></div></div>
    <div className="admin-control-tools">
      <form className="admin-operation" onSubmit={(event) => { event.preventDefault(); void submit("support"); }}>
        <h3>Support-Fall eröffnen</h3>
        <input className="input" required minLength={3} maxLength={120} value={subject} onChange={(event) => setSubject(event.target.value)} placeholder="Betreff" />
        <textarea className="input" required minLength={3} maxLength={5000} rows={3} value={body} onChange={(event) => setBody(event.target.value)} placeholder="Wie können wir helfen?" />
        <button className="primary compact" disabled={busy !== ""}>Support anfragen</button>
      </form>
      <article className="admin-operation">
        <h3>Datenexport</h3><p>Fordere eine Kopie deiner Wallet- und Profildaten an.</p>
        <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void submit("export", "json")}>JSON-Export anfordern</button>
        <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void submit("export", "csv")}>CSV-Export anfordern</button>
      </article>
      <form className="admin-operation" onSubmit={(event) => { event.preventDefault(); void submit("privacy", (event.currentTarget.elements.namedItem("privacy-type") as HTMLSelectElement).value); }}>
        <h3>Datenschutzanfrage</h3>
        <select className="input" name="privacy-type" defaultValue="access"><option value="access">Auskunft anfordern</option><option value="correction">Daten korrigieren</option><option value="deletion">Konto löschen lassen</option></select>
        <textarea className="input" rows={2} maxLength={1000} value={note} onChange={(event) => setNote(event.target.value)} placeholder="Anmerkung (optional)" />
        <button className="secondary compact" disabled={busy !== ""}>Anfrage senden</button>
      </form>
    </div>
    {message && <p className="message success-message" role="status">{message}</p>}
    {error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
