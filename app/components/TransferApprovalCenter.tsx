"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Approval = {
  id: string;
  student_user_id: string;
  receiver_user_id: string;
  amount: number;
  note: string | null;
  threshold: number;
  status: "pending" | "approved" | "declined" | "cancelled";
  created_at: string;
};
type Context = {
  threshold?: number;
  guardians?: Array<{ id: string; name: string }>;
  students?: Array<{ id: string; name: string }>;
};

export function TransferApprovalCenter() {
  const [context, setContext] = useState<Context>({});
  const [approvals, setApprovals] = useState<Approval[]>([]);
  const [guardianEmail, setGuardianEmail] = useState("");
  const [inviteToken, setInviteToken] = useState("");
  const [acceptToken, setAcceptToken] = useState("");
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const [{ data: contextData, error: contextError }, { data: approvalData, error: approvalError }] = await Promise.all([
      supabase.rpc("get_transfer_approval_context"),
      supabase.rpc("list_transfer_approvals"),
    ]);
    if (contextError || approvalError) {
      setError("Freigaben konnten gerade nicht geladen werden.");
      return;
    }
    setContext((contextData ?? {}) as Context);
    setApprovals((approvalData ?? []) as Approval[]);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function inviteGuardian(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase();
    if (!supabase || !guardianEmail.trim()) return;
    setBusy("invite"); setMessage(""); setError("");
    const { data, error: rpcError } = await supabase.rpc("create_guardian_invitation", { p_guardian_email: guardianEmail.trim() });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) {
      setError("Die Einladung konnte nicht erstellt werden.");
      return;
    }
    setInviteToken(String((data as { token?: string }).token ?? ""));
    setGuardianEmail("");
    setMessage("Einladung erstellt. Teile den Einladungs-Code sicher mit der erziehungsberechtigten Person.");
  }

  async function acceptInvitation(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase();
    if (!supabase || !acceptToken.trim()) return;
    setBusy("accept"); setMessage(""); setError("");
    const { data, error: rpcError } = await supabase.rpc("accept_guardian_invitation", { p_token: acceptToken.trim() });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) {
      setError("Der Einladungs-Code ist ungültig, abgelaufen oder für ein anderes Konto bestimmt.");
      return;
    }
    setAcceptToken("");
    setMessage("Beziehung bestätigt. Künftige Transfers werden hier zur Freigabe angezeigt.");
    await load();
  }

  async function decide(id: string, decision: "approve" | "decline") {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(id); setMessage(""); setError("");
    const { data, error: rpcError } = await supabase.rpc("decide_transfer_approval", { p_approval_id: id, p_decision: decision });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) {
      setError("Die Freigabe konnte nicht gespeichert werden. Das Guthaben wurde nicht verändert.");
      return;
    }
    setMessage(decision === "approve" ? "Transfer freigegeben." : "Transfer abgelehnt.");
    await load();
  }

  const pendingForGuardian = approvals.filter((item) => item.status === "pending" && context.students?.some((student) => student.id === item.student_user_id));
  const pendingForStudent = approvals.filter((item) => item.status === "pending" && !pendingForGuardian.some((candidate) => candidate.id === item.id));
  return <section className="card card-pad" id="transfer-approvals" aria-labelledby="transfer-approvals-title">
    <div className="card-head"><div><h2 id="transfer-approvals-title">Schulfreigaben</h2><p>Transfers ab {context.threshold ?? "…"} GIBB werden erst nach einer Guardian-Freigabe gebucht.</p></div><button className="secondary compact" type="button" onClick={() => void load()}>Aktualisieren</button></div>
    <div className="workspace-grid">
      <article className="admin-operation"><h3>Guardian einladen</h3><p>Die Einladung gilt sieben Tage und ist an die E-Mail-Adresse gebunden.</p><form onSubmit={inviteGuardian}><input className="input" type="email" value={guardianEmail} onChange={(event) => setGuardianEmail(event.target.value)} placeholder="guardian@example.org" required /><button className="primary compact" disabled={busy !== ""}>Code erstellen</button></form>{inviteToken && <p className="message" role="status"><strong>Einladungs-Code:</strong> <code>{inviteToken}</code></p>}</article>
      <article className="admin-operation"><h3>Einladung annehmen</h3><p>Guardians geben den Code mit ihrem eigenen angemeldeten Konto ein.</p><form onSubmit={acceptInvitation}><input className="input" value={acceptToken} onChange={(event) => setAcceptToken(event.target.value)} placeholder="Einladungs-Code" required /><button className="secondary compact" disabled={busy !== ""}>Beziehung bestätigen</button></form></article>
    </div>
    {pendingForGuardian.length > 0 && <div><h3>Wartende Freigaben</h3>{pendingForGuardian.map((item) => <article className="admin-operation-foot" key={item.id}><span><strong>{item.amount} GIBB</strong> · {new Date(item.created_at).toLocaleString("de-CH")}<small>{item.note ? ` · ${item.note}` : ""}</small></span><span><button className="primary compact" type="button" disabled={busy !== ""} onClick={() => void decide(item.id, "approve")}>Freigeben</button><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void decide(item.id, "decline")}>Ablehnen</button></span></article>)}</div>}
    {pendingForStudent.length > 0 && <p className="message" role="status">Deine grossen Transfers warten auf die Freigabe deiner erziehungsberechtigten Person.</p>}
    {message && <p className="message" role="status">{message}</p>}{error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
