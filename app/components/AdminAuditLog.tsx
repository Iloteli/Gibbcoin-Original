"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "../lib/supabase";

type AuditEntry = { id: string; admin_username: string | null; target_username: string | null; action: string; reason: string | null; old_value: unknown; new_value: unknown; created_at: string };
type Props = { active: boolean };

function download(name: string, content: string) {
  const url = URL.createObjectURL(new Blob([content], { type: "text/csv;charset=utf-8" }));
  const anchor = document.createElement("a"); anchor.href = url; anchor.download = name; anchor.click(); URL.revokeObjectURL(url);
}

export function AdminAuditLog({ active }: Props) {
  const [entries, setEntries] = useState<AuditEntry[]>([]);
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const load = useCallback(async () => {
    if (!active) return; const supabase = getSupabase(); if (!supabase) return;
    setLoading(true); const { data, error: rpcError } = await supabase.rpc("admin_list_audit_logs", { p_limit: 200 }); setLoading(false);
    if (rpcError) { setError("Das Admin-Protokoll konnte nicht geladen werden."); return; }
    setEntries((data ?? []) as AuditEntry[]); setError("");
  }, [active]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  const filtered = useMemo(() => { const needle = query.toLowerCase().trim(); return !needle ? entries : entries.filter((entry) => `${entry.action} ${entry.admin_username ?? ""} ${entry.target_username ?? ""} ${entry.reason ?? ""}`.toLowerCase().includes(needle)); }, [entries, query]);
  function exportCsv() {
    const escape = (value: unknown) => `"${String(value ?? "").replaceAll('"','""')}"`;
    const rows = [["Zeit", "Aktion", "Admin", "Ziel", "Grund"], ...filtered.map((entry) => [entry.created_at, entry.action, entry.admin_username ?? "", entry.target_username ?? "", entry.reason ?? ""])];
    download(`gibb-admin-protokoll-${new Date().toISOString().slice(0,10)}.csv`, "\uFEFF" + rows.map((row) => row.map(escape).join(";")).join("\n"));
  }
  if (!active) return null;
  return <section className="admin-audit"><div className="admin-section-head"><div><span>SICHERHEIT</span><h3>Admin-Protokoll</h3><p>Nachvollziehbare Rollen-, Konto- und Coin-Aktionen.</p></div><div className="audit-actions"><input className="input" aria-label="Admin-Protokoll durchsuchen" placeholder="Aktion, Person, Grund …" value={query} onChange={(event) => setQuery(event.target.value)} /><button className="secondary compact" type="button" onClick={exportCsv} disabled={!filtered.length}>CSV exportieren</button><button className="secondary compact" type="button" onClick={() => void load()} disabled={loading}>{loading ? "Lädt …" : "Aktualisieren"}</button></div></div>{error && <p className="message error">{error}</p>}<div className="audit-list">{filtered.length === 0 && !loading && <p className="empty">Keine passenden Aktionen.</p>}{filtered.slice(0, 100).map((entry) => <article key={entry.id}><span>{new Date(entry.created_at).toLocaleString("de-CH")}</span><strong>{entry.action.replaceAll("_", " ")}</strong><p>@{entry.admin_username || "system"} → {entry.target_username ? `@${entry.target_username}` : "–"}{entry.reason ? ` · ${entry.reason}` : ""}</p></article>)}</div></section>;
}
