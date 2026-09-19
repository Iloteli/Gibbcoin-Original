"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { openUserProfile } from "./UserProfileModal";

type GroupWallet = {
  group_id: string;
  group_name: string;
  group_description: string | null;
  balance: number;
  member_role: "owner" | "manager" | "member";
  member_count: number;
  join_code: string;
  updated_at: string;
};

type GroupMember = {
  user_id: string;
  display_name: string;
  username: string;
  member_role: "owner" | "manager" | "member";
  joined_at: string;
};

type GroupEntry = {
  entry_id: string;
  kind: "deposit" | "payout";
  amount: number;
  actor_label: string;
  recipient_label: string | null;
  note: string | null;
  created_at: string;
};

type Props = { onChanged: () => Promise<void> };

function groupError(message?: string) {
  if (message?.includes("insufficient_balance")) return "Dein persönliches Wallet besitzt nicht genügend Coins.";
  if (message?.includes("insufficient_group_balance")) return "Die Gruppen-Wallet besitzt nicht genügend Coins.";
  if (message?.includes("invalid_join_code") || message?.includes("group_not_found")) return "Dieser Gruppencode ist ungültig.";
  if (message?.includes("group_limit_reached")) return "Du kannst maximal zehn eigene Gruppen-Wallets erstellen.";
  if (message?.includes("membership_limit_reached")) return "Du bist bereits in zu vielen Gruppen-Wallets.";
  if (message?.includes("group_manager_required")) return "Nur Verantwortliche dürfen Coins aus der Gruppe auszahlen.";
  if (message?.includes("group_owner_required")) return "Nur der Owner darf den Gruppennamen ändern.";
  if (message?.includes("recipient_not_group_member")) return "Wähle ein Mitglied dieser Gruppe aus.";
  if (message?.includes("owner_cannot_leave_group")) return "Die erstellende Person kann ihre Gruppe nicht verlassen.";
  if (message?.includes("wallet_locked")) return "Dein Konto ist gesperrt.";
  return "Die Gruppen-Wallet konnte gerade nicht aktualisiert werden.";
}

function roleLabel(role: GroupWallet["member_role"]) {
  if (role === "owner") return "Owner";
  if (role === "manager") return "Verantwortlich";
  return "Mitglied";
}

export function GroupWallets({ onChanged }: Props) {
  const [groups, setGroups] = useState<GroupWallet[]>([]);
  const [selectedId, setSelectedId] = useState("");
  const [members, setMembers] = useState<GroupMember[]>([]);
  const [history, setHistory] = useState<GroupEntry[]>([]);
  const [name, setName] = useState("");
  const [renameValue, setRenameValue] = useState("");
  const [description, setDescription] = useState("");
  const [joinCode, setJoinCode] = useState("");
  const [depositAmount, setDepositAmount] = useState("");
  const [depositNote, setDepositNote] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawNote, setWithdrawNote] = useState("");
  const [payoutAmount, setPayoutAmount] = useState("");
  const [payoutUserId, setPayoutUserId] = useState("");
  const [payoutNote, setPayoutNote] = useState("");
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const selected = useMemo(() => groups.find((group) => group.group_id === selectedId) ?? null, [groups, selectedId]);

  const loadGroups = useCallback(async (preferredId?: string) => {
    const supabase = getSupabase();
    if (!supabase) return;
    const { data, error: loadError } = await supabase.rpc("list_my_group_wallets");
    if (loadError) { setError(groupError(loadError.message)); return; }
    const next = (data ?? []) as GroupWallet[];
    setGroups(next);
    setSelectedId((current) => {
      const candidate = preferredId || current;
      return next.some((group) => group.group_id === candidate) ? candidate : next[0]?.group_id ?? "";
    });
  }, []);

  const loadGroupDetails = useCallback(async (groupId: string) => {
    const supabase = getSupabase();
    if (!supabase || !groupId) { setMembers([]); setHistory([]); return; }
    const [memberResult, historyResult] = await Promise.all([
      supabase.rpc("list_group_members", { p_group_id: groupId }),
      supabase.rpc("list_group_history", { p_group_id: groupId }),
    ]);
    if (memberResult.error || historyResult.error) {
      setError(groupError(memberResult.error?.message ?? historyResult.error?.message));
      return;
    }
    setMembers((memberResult.data ?? []) as GroupMember[]);
    setHistory((historyResult.data ?? []) as GroupEntry[]);
  }, []);

  useEffect(() => { const timer = window.setTimeout(() => void loadGroups(), 0); return () => window.clearTimeout(timer); }, [loadGroups]);
  useEffect(() => {
    if (!selectedId) return;
    const timer = window.setTimeout(() => void loadGroupDetails(selectedId), 0);
    return () => window.clearTimeout(timer);
  }, [loadGroupDetails, selectedId]);

  async function refreshGroup(groupId = selectedId, refreshPersonal = false) {
    await loadGroups(groupId);
    await loadGroupDetails(groupId);
    if (refreshPersonal) await onChanged();
  }

  async function createGroup(event: React.FormEvent) {
    event.preventDefault(); setError(""); setMessage(""); setBusy("create");
    const supabase = getSupabase();
    const { data, error: createError } = supabase
      ? await supabase.rpc("create_group_wallet", { p_name: name, p_description: description || null })
      : { data: null, error: { message: "client_unavailable" } };
    setBusy("");
    if (createError) { setError(groupError(createError.message)); return; }
    const created = (data as Array<{ group_id: string }> | null)?.[0];
    setName(""); setDescription(""); setMessage("Gruppen-Wallet wurde erstellt.");
    await loadGroups(created?.group_id);
  }

  async function joinGroup(event: React.FormEvent) {
    event.preventDefault(); setError(""); setMessage(""); setBusy("join");
    const supabase = getSupabase();
    const { data, error: joinError } = supabase
      ? await supabase.rpc("join_group_wallet", { p_join_code: joinCode })
      : { data: null, error: { message: "client_unavailable" } };
    setBusy("");
    if (joinError) { setError(groupError(joinError.message)); return; }
    setJoinCode(""); setMessage("Du bist der Gruppen-Wallet beigetreten.");
    await loadGroups(typeof data === "string" ? data : undefined);
  }

  async function deposit(event: React.FormEvent) {
    event.preventDefault(); setError(""); setMessage(""); setBusy("deposit");
    const supabase = getSupabase();
    const { error: depositError } = supabase
      ? await supabase.rpc("deposit_group_coins", { p_group_id: selectedId, p_amount: Number(depositAmount), p_note: depositNote || null })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (depositError) { setError(groupError(depositError.message)); return; }
    setDepositAmount(""); setDepositNote(""); setMessage("Coins wurden sicher in die Gruppen-Wallet gelegt.");
    await refreshGroup(selectedId, true);
  }

  async function payout(event: React.FormEvent) {
    event.preventDefault(); setError(""); setMessage(""); setBusy("payout");
    const supabase = getSupabase();
    const { error: payoutError } = supabase
      ? await supabase.rpc("payout_group_coins", { p_group_id: selectedId, p_recipient_user_id: payoutUserId, p_amount: Number(payoutAmount), p_note: payoutNote || null })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (payoutError) { setError(groupError(payoutError.message)); return; }
    setPayoutAmount(""); setPayoutNote(""); setMessage("Coins wurden aus der Gruppe ausgezahlt.");
    await refreshGroup(selectedId, true);
  }

  async function withdraw(event: React.FormEvent) {
    event.preventDefault(); setError(""); setMessage(""); setBusy("withdraw");
    const supabase = getSupabase();
    const { error: withdrawError } = supabase
      ? await supabase.rpc("withdraw_group_coins", { p_group_id: selectedId, p_amount: Number(withdrawAmount), p_note: withdrawNote || null })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (withdrawError) { setError(groupError(withdrawError.message)); return; }
    setWithdrawAmount(""); setWithdrawNote(""); setMessage("Coins wurden in dein persönliches Wallet gelegt.");
    await refreshGroup(selectedId, true);
  }

  async function changeRole(member: GroupMember) {
    const nextRole = member.member_role === "manager" ? "member" : "manager";
    setError(""); setMessage(""); setBusy(`role-${member.user_id}`);
    const supabase = getSupabase();
    const { error: roleError } = supabase
      ? await supabase.rpc("set_group_member_role", { p_group_id: selectedId, p_user_id: member.user_id, p_role: nextRole })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (roleError) { setError(groupError(roleError.message)); return; }
    setMessage(`${member.display_name} ist jetzt ${nextRole === "manager" ? "verantwortlich" : "Mitglied"}.`);
    await loadGroupDetails(selectedId);
  }

  async function renameGroup(event: React.FormEvent) {
    event.preventDefault();
    if (!selected) return;
    setError(""); setMessage(""); setBusy("rename");
    const supabase = getSupabase();
    const { error: renameError } = supabase
      ? await supabase.rpc("rename_group_wallet", { p_group_id: selected.group_id, p_name: renameValue })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (renameError) { setError(groupError(renameError.message)); return; }
    setRenameValue("");
    setMessage("Der Gruppenname wurde geändert.");
    await refreshGroup(selected.group_id);
  }

  async function leaveGroup() {
    setError(""); setMessage(""); setBusy("leave");
    const supabase = getSupabase();
    const { error: leaveError } = supabase
      ? await supabase.rpc("leave_group_wallet", { p_group_id: selectedId })
      : { error: { message: "client_unavailable" } };
    setBusy("");
    if (leaveError) { setError(groupError(leaveError.message)); return; }
    setMessage("Du hast die Gruppe verlassen.");
    await loadGroups();
  }

  return <section className="card card-pad group-wallets" id="group-wallets">
    <div className="section-heading"><div><span className="section-number">05</span><h2>Gruppen-Wallets</h2></div><small>Für Klassen, Teams und Projekte</small></div>
    <div className="group-onboarding">
      <form className="group-create-form" onSubmit={createGroup}>
        <strong>Neue Gruppe</strong>
        <input className="input" value={name} onChange={(event) => setName(event.target.value)} minLength={3} maxLength={60} required placeholder="z. B. Abschlussprojekt" />
        <input className="input" value={description} onChange={(event) => setDescription(event.target.value)} maxLength={160} placeholder="Kurze Beschreibung (optional)" />
        <button className="primary compact" type="submit" disabled={busy !== ""}>Erstellen</button>
      </form>
      <form className="group-join-form" onSubmit={joinGroup}>
        <strong>Mit Code beitreten</strong><p>Den sicheren 32-stelligen Code erhältst du von einem Gruppenmitglied.</p>
        <div><input className="input join-code-input" value={joinCode} onChange={(event) => setJoinCode(event.target.value.replace(/[^a-fA-F0-9]/g, "").toUpperCase())} minLength={32} maxLength={32} required placeholder="32-stelliger Gruppencode" /><button className="secondary" type="submit" disabled={busy !== ""}>Beitreten</button></div>
      </form>
    </div>

    {groups.length === 0 && <div className="empty group-empty">Du bist noch in keiner Gruppen-Wallet.</div>}
    {groups.length > 0 && <>
      <div className="group-tabs" role="tablist" aria-label="Gruppen-Wallet auswählen">{groups.map((group) => <button type="button" role="tab" aria-selected={selectedId === group.group_id} className={selectedId === group.group_id ? "active" : ""} key={group.group_id} onClick={() => setSelectedId(group.group_id)}><strong>{group.group_name}</strong><span>{new Intl.NumberFormat("de-CH").format(group.balance)} GIBB</span></button>)}</div>
      {selected && <div className="group-dashboard">
        <div className="group-summary"><div><span>{roleLabel(selected.member_role)}</span><h3>{selected.group_name}</h3><p>{selected.group_description || "Gemeinsam Coins verwalten und jede Bewegung nachvollziehen."}</p></div><div className="group-balance"><span>Gruppenguthaben</span><strong>{new Intl.NumberFormat("de-CH").format(selected.balance)} <small>GIBB</small></strong><button type="button" onClick={() => void navigator.clipboard?.writeText(selected.join_code)}>Code {selected.join_code} kopieren</button></div></div>
        {selected.member_role === "owner" && <form className="group-rename-form" onSubmit={renameGroup}><label htmlFor="group-rename">Gruppenname ändern</label><div><input id="group-rename" className="input" value={renameValue} onChange={(event) => setRenameValue(event.target.value)} minLength={3} maxLength={60} required placeholder={selected.group_name} /><button className="secondary compact" type="submit" disabled={busy !== "" || renameValue.trim() === selected.group_name}>Speichern</button></div><small>Nur der Owner kann den offiziellen Namen dieser Gruppen-Wallet ändern.</small></form>}
        <div className="group-actions-grid">
          <form onSubmit={deposit}><strong>Coins einzahlen</strong><div className="group-inline-fields"><input className="input" type="number" min="1" max="100000" step="1" required value={depositAmount} onChange={(event) => setDepositAmount(event.target.value)} placeholder="Betrag" /><input className="input" maxLength={160} value={depositNote} onChange={(event) => setDepositNote(event.target.value)} placeholder="Notiz (optional)" /><button className="primary compact" disabled={busy !== ""}>Einzahlen</button></div></form>
          <form onSubmit={withdraw}><strong>Ins eigene Wallet nehmen</strong><div className="group-inline-fields"><input className="input" type="number" min="1" max="100000" step="1" required value={withdrawAmount} onChange={(event) => setWithdrawAmount(event.target.value)} placeholder="Betrag" /><input className="input" maxLength={160} value={withdrawNote} onChange={(event) => setWithdrawNote(event.target.value)} placeholder="Notiz (optional)" /><button className="secondary" disabled={busy !== ""}>Entnehmen</button></div></form>
          {(selected.member_role === "owner" || selected.member_role === "manager") && <form className="group-payout-form" onSubmit={payout}><strong>An Mitglied auszahlen</strong><div className="group-inline-fields payout"><select className="input" required value={payoutUserId} onChange={(event) => setPayoutUserId(event.target.value)}><option value="">Mitglied wählen</option>{members.map((member) => <option value={member.user_id} key={member.user_id}>{member.display_name}</option>)}</select><input className="input" type="number" min="1" max="100000" step="1" required value={payoutAmount} onChange={(event) => setPayoutAmount(event.target.value)} placeholder="Betrag" /><input className="input" maxLength={160} value={payoutNote} onChange={(event) => setPayoutNote(event.target.value)} placeholder="Notiz" /><button className="secondary" disabled={busy !== ""}>Auszahlen</button></div></form>}
        </div>
        <div className="group-details-grid">
          <div><div className="group-list-heading"><strong>Mitglieder</strong><span>{selected.member_count}</span></div><div className="group-member-list">{members.map((member) => <div className="group-member" key={member.user_id}><span className="recipient-avatar">{member.display_name[0]}</span><div><button className="user-profile-link" type="button" onClick={() => openUserProfile(member.user_id)}><strong>{member.display_name}</strong><small>@{member.username} · {roleLabel(member.member_role)}</small></button></div>{selected.member_role === "owner" && member.member_role !== "owner" && <button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void changeRole(member)}>{member.member_role === "manager" ? "Zu Mitglied" : "Verantwortlich"}</button>}</div>)}</div>{selected.member_role !== "owner" && <button className="group-leave" type="button" onClick={() => void leaveGroup()} disabled={busy !== ""}>Gruppe verlassen</button>}</div>
          <div><div className="group-list-heading"><strong>Gruppenverlauf</strong><span>{history.length}</span></div><div className="group-history">{history.length === 0 && <div className="empty">Noch keine Gruppenbewegungen.</div>}{history.map((entry) => <article key={entry.entry_id}><span className={entry.kind}>{entry.kind === "deposit" ? "↓" : "↑"}</span><div><strong>{entry.kind === "deposit" ? `${entry.actor_label} hat eingezahlt` : entry.actor_label === entry.recipient_label ? `${entry.actor_label} hat Coins entnommen` : `${entry.actor_label} → ${entry.recipient_label}`}</strong><small>{entry.note || new Date(entry.created_at).toLocaleString("de-CH")}</small></div><b>{entry.kind === "deposit" ? "+" : "−"}{entry.amount}</b></article>)}</div></div>
        </div>
      </div>}
    </>}
    {message && <p className="message" role="status">✓ {message}</p>}{error && <p className="message error" role="alert">{error}</p>}
  </section>;
}
