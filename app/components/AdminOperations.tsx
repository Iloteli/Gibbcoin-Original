"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Operation = {
  operation_key: string;
  label: string;
  description: string;
  category: string;
  status: "enabled" | "disabled" | "configured" | "unavailable";
  configuration: Record<string, unknown>;
  updated_at: string;
};

const statusLabel: Record<Operation["status"], string> = {
  enabled: "Aktiv", disabled: "Deaktiviert", configured: "Konfiguriert", unavailable: "Nicht verfügbar",
};
const categoryLabel: Record<string, string> = {
  system: "System", communication: "Kommunikation", data: "Daten",
  moderation: "Moderation", economy: "Ökonomie", games: "Spiele",
};

export function AdminOperations({ pin, active }: { pin: string; active: boolean }) {
  const [operations, setOperations] = useState<Operation[]>([]);
  const [center, setCenter] = useState<{ settings?: Record<string, Record<string, unknown>>; classes?: Array<Record<string, string | string[]>>; tickets?: Array<Record<string, string>>; exports?: Array<Record<string, string>>; privacy?: Array<Record<string, string>>; shop?: Array<Record<string, string | boolean>>; tasks?: Array<Record<string, string | boolean>>; seasons?: Array<Record<string, string | boolean>> }>({});
  const [maintenanceMessage, setMaintenanceMessage] = useState("");
  const [announcement, setAnnouncement] = useState({ title: "", message: "" });
  const [className, setClassName] = useState("");
  const [classYear, setClassYear] = useState("");
  const [memberIds, setMemberIds] = useState<Record<string, string>>({});
  const [centerPage, setCenterPage] = useState(1);
  const [centerHasMore, setCenterHasMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [controlError, setControlError] = useState("");
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    if (!active) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setLoading(true); setControlError("");
    const { data, error: rpcError } = await supabase.rpc("admin_list_operations");
    if (rpcError) { setError("Die Operationsübersicht ist noch nicht verfügbar."); setLoading(false); return; }
    setOperations((data ?? []) as Operation[]);
    const { data: control, error: controlRpcError } = await supabase.rpc("admin_list_control_center_page", { p_page: centerPage, p_page_size: 12 });
    setLoading(false);
    if (controlRpcError) { setControlError("Der Kontrollbereich konnte nicht geladen werden. Versuche es erneut."); return; }
    if (control) {
      const next = control as typeof center;
      setCenter(next);
      const maintenance = next.settings?.maintenance ?? {};
      const notice = next.settings?.announcement ?? {};
      setMaintenanceMessage(String(maintenance.message ?? ""));
      setAnnouncement({ title: String(notice.title ?? ""), message: String(notice.message ?? "") });
      setCenterHasMore((next.classes?.length ?? 0) === 12 || (next.tickets?.length ?? 0) === 12 || (next.shop?.length ?? 0) === 12);
    }
  }, [active, centerPage]);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function change(operation: Operation, status: Operation["status"]) {
    const supabase = getSupabase();
    if (!supabase || !pin) return;
    setBusy(operation.operation_key); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_update_operation", {
      p_operation_key: operation.operation_key, p_status: status,
      p_configuration: operation.configuration ?? {}, p_pin: pin,
    });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) {
      const code = (data as { error?: string } | null)?.error ?? rpcError?.message;
      setError(code?.startsWith("admin_pin_") ? "Deine PIN-Freigabe ist abgelaufen. Entsperre das Panel erneut." : "Die Änderung konnte nicht gespeichert werden.");
      return;
    }

    setMessage("Operation gespeichert."); await load();
  }

  async function saveControl(key: string, value: Record<string, unknown>) {
    const supabase = getSupabase();
    if (!supabase || !pin) return;
    setBusy(key); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_update_control", { p_key: key, p_value: value, p_pin: pin });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Die Konfiguration konnte nicht gespeichert werden."); return; }
    setMessage("Konfiguration gespeichert."); await load();
  }

  async function createClass(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase();
    if (!supabase || !className.trim()) return;
    setBusy("class"); setError("");
    const { data, error: rpcError } = await supabase.rpc("admin_create_class", { p_name: className, p_school_year: classYear, p_pin: pin });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Die Klasse konnte nicht angelegt werden."); return; }
    setClassName(""); setClassYear(""); setMessage("Klasse angelegt."); await load();
  }

  async function updateCase(item: Record<string, string>, status: string) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(item.id);
    const { data, error: rpcError } = await supabase.rpc("admin_update_case", { p_case_id: item.id, p_status: status, p_priority: item.priority, p_pin: pin });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Das Ticket konnte nicht aktualisiert werden."); return; }
    await load();
  }

  async function updateCatalog(kind: string, item: Record<string, string | boolean>, values: Record<string, string | boolean>) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(String(item.id ?? item.task_key));
    const id = String(item.id ?? item.task_key);
    const { data, error: rpcError } = await supabase.rpc("admin_update_catalog", { p_kind: kind, p_id: id, p_values: values, p_pin: pin });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Der Katalogeintrag konnte nicht gespeichert werden."); return; }
    await load();
  }

  async function updateClassMember(classId: string, userId: string, remove = false) {
    const supabase = getSupabase();
    if (!supabase || !userId.trim()) return;
    setBusy(`member:${classId}:${userId}`);
    const { data, error: rpcError } = await supabase.rpc(remove ? "admin_remove_class_member" : "admin_add_class_member", {
      p_class_id: classId, p_user_id: userId.trim(), p_pin: pin,
    });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Die Klassenmitgliedschaft konnte nicht gespeichert werden."); return; }
    setMemberIds((current) => ({ ...current, [classId]: "" }));
    await load();
  }

  async function runHealthCheck() {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy("health");
    const { data, error: rpcError } = await supabase.rpc("admin_run_health_check", { p_pin: pin });
    setBusy("");
    if (rpcError || !(data as { ok?: boolean } | null)?.ok) { setError("Die Systemprüfung konnte nicht ausgeführt werden."); return; }
    setMessage("Systemprüfung abgeschlossen."); await load();
  }

  if (!active) return null;
  const ticketCount = center.tickets?.length ?? 0;
  const exportCount = center.exports?.length ?? 0;
  const privacyCount = center.privacy?.length ?? 0;
  const classCount = center.classes?.length ?? 0;
  return <section className="admin-operations card card-pad" aria-labelledby="admin-operations-title">
    <div className="admin-users-head"><div><strong id="admin-operations-title">Weitere Admin-Operationen</strong><p>Konfiguration und Status der noch nicht integrierten Dienste. Keine Aktion meldet fälschlich einen erfolgreichen Versand, Backup oder Restore.</p></div><span>{loading ? "Wird geladen …" : `${operations.length} Bereiche`}</span></div>
    {loading && <p className="message" role="status">Admin-Übersicht wird geladen …</p>}
    {controlError && <p className="message error" role="alert">{controlError} <button className="secondary compact" type="button" onClick={() => void load()}>Erneut laden</button></p>}
    {!loading && !controlError && <div className="admin-operation-grid">
      <article className="admin-operation"><span className="eyebrow">Support</span><h3>{ticketCount} Fälle</h3><p>Offene und bearbeitete Anfragen im aktuellen Bereich.</p><a className="secondary compact" href="#support-privacy">Support & Datenschutz öffnen</a></article>
      <article className="admin-operation"><span className="eyebrow">Datenschutz</span><h3>{exportCount + privacyCount} Anfragen</h3><p>{exportCount} Exporte · {privacyCount} Datenschutzanfragen.</p></article>
      <article className="admin-operation"><span className="eyebrow">Klassen</span><h3>{classCount} Klassen</h3><p>Mitglieder werden nur über die geschützten Admin-RPCs verwaltet.</p></article>
    </div>}
    <div className="admin-operation-grid">
      {operations.map((operation) => <article className="admin-operation" key={operation.operation_key}>
        <div><span className="eyebrow">{categoryLabel[operation.category] ?? operation.category}</span><h3>{operation.label}</h3><p>{operation.description}</p></div>
        <div className="admin-operation-foot"><span className={`admin-badge operation-${operation.status}`}>{statusLabel[operation.status]}</span>
          <select className="input compact" aria-label={`Status ${operation.label}`} value={operation.status} disabled={busy === operation.operation_key} onChange={(event) => void change(operation, event.target.value as Operation["status"])}>
            <option value="unavailable">Nicht verfügbar</option><option value="configured">Konfiguriert</option><option value="enabled">Aktiv</option><option value="disabled">Deaktiviert</option>
          </select>
        </div>
      </article>)}
    </div>
    <div className="admin-control-tools">
          <article className="admin-operation"><h3>Wartungsmodus & Hinweis</h3><p>Der Wartungshinweis wird allen angemeldeten Personen angezeigt. Kritische Server-RPCs bleiben serverseitig geschützt.</p>
            <textarea className="input" rows={2} value={maintenanceMessage} onChange={(event) => setMaintenanceMessage(event.target.value)} placeholder="Wartungshinweis" />
            <button className="primary compact" type="button" disabled={busy !== ""} onClick={() => void saveControl("maintenance", { enabled: true, message: maintenanceMessage, until: null })}>Wartung aktivieren</button>
            <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void saveControl("maintenance", { enabled: false, message: maintenanceMessage, until: null })}>Wartung beenden</button>
          </article>
          <article className="admin-operation"><h3>Systemstatus</h3><p>Prüft Datenbank, Wallets, Buchungen und den Campus-Shop.</p><button className="primary compact" type="button" disabled={busy !== ""} onClick={() => void runHealthCheck()}>System jetzt prüfen</button></article>
          <article className="admin-operation"><h3>Globale Ankündigung</h3>
            <input className="input" value={announcement.title} onChange={(event) => setAnnouncement({ ...announcement, title: event.target.value })} placeholder="Titel" />
            <textarea className="input" rows={2} value={announcement.message} onChange={(event) => setAnnouncement({ ...announcement, message: event.target.value })} placeholder="Nachricht" />
            <button className="primary compact" type="button" disabled={busy !== ""} onClick={() => void saveControl("announcement", { enabled: true, ...announcement, until: null })}>Ankündigung veröffentlichen</button>
            <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void saveControl("announcement", { enabled: false, ...announcement, until: null })}>Ausblenden</button>
          </article>
          <article className="admin-operation"><h3>Klassenverwaltung</h3><p>Klassen dienen der Organisation. Die App-Rolle bleibt davon getrennt: <strong>Benutzer</strong> nutzt Wallet-Funktionen, <strong>Admin</strong> verwaltet freigegebene Bereiche, <strong>Owner</strong> vergibt Adminrechte.</p><form onSubmit={createClass}><input className="input" value={className} onChange={(event) => setClassName(event.target.value)} placeholder="Klassenname" /><input className="input" value={classYear} onChange={(event) => setClassYear(event.target.value)} placeholder="Schuljahr (optional)" /><button className="primary compact" disabled={busy !== ""}>Klasse anlegen</button></form>{(center.classes ?? []).map((item) => <div key={String(item.id)}><p><strong>{String(item.name)}</strong> · {item.school_year || "ohne Schuljahr"} · {Array.isArray(item.members) ? item.members.length : 0} Mitglieder</p><input className="input compact" value={memberIds[String(item.id)] ?? ""} onChange={(event) => setMemberIds((current) => ({ ...current, [String(item.id)]: event.target.value }))} placeholder="Benutzer-ID hinzufügen" /><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void updateClassMember(String(item.id), memberIds[String(item.id)] ?? "")}>Mitglied hinzufügen</button><div>{(Array.isArray(item.members) ? item.members : []).map((member) => <button className="secondary compact" type="button" key={String(member)} disabled={busy !== ""} onClick={() => void updateClassMember(String(item.id), String(member), true)}>Mitglied {String(member).slice(0, 8)} entfernen</button>)}</div></div>)}{!(center.classes ?? []).length && <p>Noch keine Klassen auf dieser Seite.</p>}<div className="admin-operation-foot"><button className="secondary compact" type="button" disabled={centerPage <= 1 || busy !== ""} onClick={() => setCenterPage((page) => page - 1)}>Neuere</button><button className="secondary compact" type="button" disabled={!centerHasMore || busy !== ""} onClick={() => setCenterPage((page) => page + 1)}>Ältere</button></div></article>
          <article className="admin-operation"><h3>Support-Fälle</h3>{(center.tickets ?? []).slice(0, 8).map((item) => <div key={item.id} className="admin-operation-foot"><span>{item.subject} · {item.priority}</span><select className="input compact" value={item.status} disabled={busy === item.id} onChange={(event) => void updateCase(item, event.target.value)}><option value="open">Offen</option><option value="in_progress">In Arbeit</option><option value="waiting">Wartet</option><option value="closed">Geschlossen</option></select></div>)}{!(center.tickets ?? []).length && <p>Keine Support-Fälle.</p>}</article>
          <article className="admin-operation"><h3>Datenschutz & Exporte</h3><p>{(center.exports ?? []).length} Exportanfragen · {(center.privacy ?? []).length} Datenschutzanfragen</p><p>Neue Anfragen werden sicher erfasst und hier zur Bearbeitung angezeigt.</p></article>
          <article className="admin-operation"><h3>Shop, Aufgaben & Saison</h3>
            <p>Einträge können direkt aktiviert oder pausiert werden.</p>
            {(center.shop ?? []).slice(0, 6).map((item) => <div className="admin-operation-foot" key={String(item.id)}><span>{String(item.name)}</span><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void updateCatalog("shop", item, { active: !item.active })}>{item.active ? "Pausieren" : "Aktivieren"}</button></div>)}
            {(center.tasks ?? []).slice(0, 6).map((item) => <div className="admin-operation-foot" key={String(item.task_key)}><span>{String(item.name)}</span><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void updateCatalog("task", item, { active: !item.active })}>{item.active ? "Pausieren" : "Aktivieren"}</button></div>)}
            {(center.seasons ?? []).slice(0, 3).map((item) => <div className="admin-operation-foot" key={String(item.id)}><span>{String(item.name)}</span><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void updateCatalog("season", item, { name: String(item.name) })}>Speichern</button></div>)}
          </article>
    </div>
    {message && <p className="message" role="status">{message}</p>}
    {error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
