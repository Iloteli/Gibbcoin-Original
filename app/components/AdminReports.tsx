"use client";

import { useMemo } from "react";

type ReportUser = {
  user_id: string;
  username: string;
  display_name: string;
  role: "user" | "admin" | "super_admin";
  balance: number;
  wallet_status: "active" | "locked";
  locked_until: string | null;
  lock_reason: string | null;
};

type Props = { active: boolean; users: ReportUser[]; currentRole: "admin" | "super_admin" };

const numberFormat = new Intl.NumberFormat("de-CH");

function download(name: string, rows: (string | number)[][]) {
  const escape = (value: unknown) => `"${String(value ?? "").replaceAll('"', '""')}"`;
  const content = "\uFEFF" + rows.map((row) => row.map(escape).join(";")).join("\n");
  const url = URL.createObjectURL(new Blob([content], { type: "text/csv;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  URL.revokeObjectURL(url);
}

function roleLabel(role: ReportUser["role"]) {
  if (role === "super_admin") return "Owner";
  if (role === "admin") return "Admin";
  return "Benutzer";
}

export function AdminReports({ active, users, currentRole }: Props) {
  const isOwner = currentRole === "super_admin";
  const today = new Date().toISOString().slice(0, 10);

  const report = useMemo(() => {
    const balances = users.map((item) => Number(item.balance) || 0).sort((a, b) => a - b);
    const total = balances.reduce((sum, value) => sum + value, 0);
    const middle = Math.floor(balances.length / 2);
    const median = balances.length === 0 ? 0 : balances.length % 2 === 1 ? (balances[middle] ?? 0) : (((balances[middle - 1] ?? 0) + (balances[middle] ?? 0)) / 2);
    return {
      accounts: users.length,
      admins: users.filter((item) => item.role === "admin").length,
      owners: users.filter((item) => item.role === "super_admin").length,
      locked: users.filter((item) => item.wallet_status === "locked").length,
      empty: users.filter((item) => (Number(item.balance) || 0) === 0).length,
      circulation: total,
      average: users.length ? Math.round(total / users.length) : 0,
      median: Math.round(median),
      top: [...users].sort((a, b) => (Number(b.balance) || 0) - (Number(a.balance) || 0)).slice(0, 10),
    };
  }, [users]);

  if (!active) return null;

  function exportAccounts() {
    download(`gibb-konten-${today}.csv`, [
      ["Benutzername", "Anzeigename", "Rolle", "Status", "Guthaben"],
      ...users.map((item) => [item.username, item.display_name, roleLabel(item.role), item.wallet_status === "locked" ? "Gebannt" : "Aktiv", Number(item.balance) || 0]),
    ]);
  }

  function exportLocked() {
    const locked = users.filter((item) => item.wallet_status === "locked");
    download(`gibb-sperren-${today}.csv`, [
      ["Benutzername", "Anzeigename", "Rolle", "Gesperrt bis", "Grund", "Guthaben"],
      ...locked.map((item) => [item.username, item.display_name, roleLabel(item.role), item.locked_until ? new Date(item.locked_until).toLocaleString("de-CH") : "Dauerhaft", item.lock_reason ?? "", Number(item.balance) || 0]),
    ]);
  }

  function exportTeam() {
    const team = users.filter((item) => item.role !== "user");
    download(`gibb-team-${today}.csv`, [
      ["Benutzername", "Anzeigename", "Rolle", "Status", "Guthaben"],
      ...team.map((item) => [item.username, item.display_name, roleLabel(item.role), item.wallet_status === "locked" ? "Gebannt" : "Aktiv", Number(item.balance) || 0]),
    ]);
  }

  return (
    <section className="admin-reports">
      <div className="admin-section-head">
        <div>
          <span>BERICHTE</span>
          <h3>Auswertung &amp; Export</h3>
          <p>Nur für entsperrte Admins und Owner sichtbar. Alle Zahlen stammen aus den aktuell geladenen Konten.</p>
        </div>
        <div className="report-actions">
          <button className="secondary compact" type="button" onClick={exportAccounts} disabled={!users.length}>Konten als CSV</button>
          <button className="secondary compact" type="button" onClick={exportLocked} disabled={!report.locked}>Sperren als CSV</button>
        </div>
      </div>

      <div className="report-kpis">
        <div><span>Konten</span><strong>{numberFormat.format(report.accounts)}</strong></div>
        <div><span>Coins im Umlauf</span><strong>{numberFormat.format(report.circulation)}</strong></div>
        <div><span>Durchschnitt</span><strong>{numberFormat.format(report.average)}</strong></div>
        <div><span>Median</span><strong>{numberFormat.format(report.median)}</strong></div>
        <div><span>Konten ohne Coins</span><strong>{numberFormat.format(report.empty)}</strong></div>
        <div><span>Gebannt</span><strong>{numberFormat.format(report.locked)}</strong></div>
      </div>

      <div className="report-table" role="table" aria-label="Konten mit dem höchsten Guthaben">
        <div className="report-row report-head" role="row"><span>Konto</span><span>Rolle</span><span>Guthaben</span></div>
        {report.top.length === 0 && <p className="empty">Noch keine Konten geladen.</p>}
        {report.top.map((item) => (
          <div className="report-row" role="row" key={item.user_id}>
            <span>{item.display_name} <small>@{item.username}</small></span>
            <span>{roleLabel(item.role)}</span>
            <span>{numberFormat.format(Number(item.balance) || 0)}</span>
          </div>
        ))}
      </div>

      {isOwner && (
        <div className="report-owner">
          <div>
            <strong>Nur für Owner</strong>
            <p>Team-Übersicht: {report.owners} Owner und {report.admins} Admins. Diese Liste zeigt alle Konten mit erhöhten Rechten – Fun-Ränge zählen nicht dazu.</p>
          </div>
          <button className="secondary compact" type="button" onClick={exportTeam} disabled={!report.admins && !report.owners}>Team als CSV</button>
        </div>
      )}
    </section>
  );
}
