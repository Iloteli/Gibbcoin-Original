"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { GameAdminControls } from "./GameAdminControls";

type AdminUser = {
  user_id: string;
  username: string;
  display_name: string;
  role: "user" | "admin" | "super_admin";
  visual_role: "demo_admin" | "demo_owner" | null;
  balance: number;
  wallet_status: "active" | "locked";
};

type PinStatus = { has_pin: boolean; failed_attempts: number; locked_until: string | null };
type AdminCoinStats = { given: number; removed: number; since: string | null };
type SecureResult = { ok?: boolean; error?: string; transaction_id?: string };
type AdjustmentMode = "credit" | "remove";
type Props = {
  currentRole: "admin" | "super_admin";
  currentUserId: string;
  onChanged: () => Promise<void>;
  onExit: () => void;
};

function pinError(code?: string) {
  if (code?.includes("mfa_required")) return "Bestätige diese Sitzung zuerst mit deinem Zwei-Faktor-Code.";
  if (code === "admin_pin_not_set") return "Richte zuerst deinen persönlichen Admin-PIN ein.";
  if (code === "admin_pin_invalid") return "Der Admin-PIN ist falsch. Die Aktion wurde nicht ausgeführt.";
  if (code === "admin_pin_locked") return "Zu viele Fehlversuche. Die PIN-Eingabe ist 15 Minuten gesperrt.";
  if (code === "pin_must_have_four_digits") return "Der PIN muss genau vier Ziffern enthalten.";
  return "Die geschützte Admin-Aktion konnte nicht ausgeführt werden.";
}

function adjustmentError(code?: string, rpcMessage?: string) {
  if (code?.startsWith("admin_pin_")) return pinError(code);
  const message = `${code ?? ""} ${rpcMessage ?? ""}`;
  if (message.includes("mfa_required")) return "Bestätige diese Sitzung zuerst mit deinem Zwei-Faktor-Code.";
  if (message.includes("invalid_admin_amount")) return "Der Betrag ist zu gross oder ungültig.";
  if (message.includes("invalid_admin_reason")) return "Der Grund muss zwischen 3 und 120 Zeichen lang sein.";
  if (message.includes("insufficient_balance")) return "Dieses Konto besitzt nicht genügend Coins.";
  if (message.includes("cannot_credit_own_coins")) return "Admins dürfen ihrem eigenen Konto keine Coins gutschreiben.";
  if (message.includes("cannot_remove_own_coins")) return "Du kannst Coins nur anderen Konten entziehen.";
  if (message.includes("cannot_remove_owner_coins")) return "Das Owner-Guthaben ist geschützt und kann von keinem Admin entzogen werden.";
  if (message.includes("wallet_not_found")) return "Für dieses Konto wurde kein Wallet gefunden.";
  if (message.includes("account_locked")) return "Dein Admin-Konto ist gesperrt.";
  if (message.includes("admin_required")) return "Für diese Aktion fehlen dir die Adminrechte.";
  return "Die Coin-Aktion konnte nicht ausgeführt werden. Versuche es erneut.";
}

function adminError(message?: string) {
  if (message?.includes("mfa_required")) return "Bestätige diese Sitzung zuerst mit deinem Zwei-Faktor-Code.";
  if (message?.includes("cannot_change_own_role")) return "Du kannst deine eigene Adminrolle nicht ändern.";
  if (message?.includes("cannot_lock_own_account")) return "Du kannst dein eigenes Konto nicht sperren.";
  if (message?.includes("cannot_modify_super_admin")) return "Das Owner-Konto kann hier nicht geändert werden.";
  if (message?.includes("owner_required")) return "Nur der Owner darf Adminrechte vergeben oder entfernen.";
  if (message?.includes("cannot_modify_peer_admin")) return "Admins können andere Admin-Konten nicht sperren.";
  if (message?.includes("cannot_visual_role_self")) return "Die Demo-Anzeige kann nicht für das eigene Konto gesetzt werden.";
  if (message?.includes("invalid_visual_role")) return "Diese Demo-Anzeige ist nicht verfügbar.";
  if (message?.startsWith("admin_pin_")) return pinError(message);
  if (message?.includes("wallet_not_found")) return "Für dieses Konto wurde kein Wallet gefunden.";
  if (message?.includes("account_status_update_failed")) return "Der Bann konnte nicht vollständig gespeichert werden. Versuche es erneut.";
  if (message?.includes("admin_required")) return "Für diese Aktion fehlen dir die Adminrechte.";
  return "Die Admin-Aktion konnte nicht ausgeführt werden.";
}

function visualRoleLabel(role: AdminUser["visual_role"]) {
  if (role === "demo_owner") return "Owner 1 · nur Anzeige";
  if (role === "demo_admin") return "Admin 1 · nur Anzeige";
  return "Kein Fun-Rang";
}

function accountDeletionError(code?: string) {
  if (code?.includes("mfa_required")) return "Bestätige diese Sitzung zuerst mit deinem Zwei-Faktor-Code.";
  if (code?.startsWith("admin_pin_")) return pinError(code);
  if (code?.includes("pin_must_have_four_digits")) return "Der Admin-PIN muss genau vier Ziffern enthalten.";
  if (code?.includes("cannot_delete_own_account")) return "Du kannst dein eigenes Konto nicht löschen.";
  if (code?.includes("cannot_delete_owner")) return "Das Owner-Konto ist vor dem Löschen geschützt.";
  if (code?.includes("cannot_delete_peer_admin")) return "Admins können keine anderen Admin-Konten löschen.";
  if (code?.includes("admin_required")) return "Für diese Löschung fehlen dir die Adminrechte.";
  if (code?.includes("account_locked")) return "Dein Admin-Konto ist gesperrt.";
  if (code?.includes("user_not_found")) return "Dieses Konto existiert nicht mehr.";
  if (code?.includes("account_deleted_cleanup_pending")) return "Der Zugang wurde gelöscht. Die Anonymisierung des Verlaufs muss noch geprüft werden.";
  return "Das Konto konnte nicht gelöscht werden. Versuche es erneut.";
}

function passwordResetError(code?: string) {
  if (code?.includes("mfa_required")) return "Bestätige diese Sitzung zuerst mit deinem Zwei-Faktor-Code.";
  if (code?.includes("cannot_reset_own_password")) return "Für dein eigenes Konto nutzt du «Passwort vergessen?» auf dem Anmeldebildschirm.";
  if (code?.includes("cannot_reset_owner")) return "Das Owner-Passwort kann nicht über das Adminpanel zurückgesetzt werden.";
  if (code?.includes("cannot_reset_peer_admin")) return "Admins dürfen Passwörter normaler Benutzer zurücksetzen. Admin-Konten verwaltet nur der Owner.";
  if (code?.includes("email_missing")) return "Für dieses Konto ist keine E-Mail-Adresse hinterlegt.";
  if (code?.includes("email_delivery_failed")) return "Die Reset-E-Mail konnte gerade nicht versendet werden. Bitte warte kurz und versuche es erneut.";
  if (code?.includes("user_not_found")) return "Dieses Konto existiert nicht mehr.";
  if (code?.includes("account_locked")) return "Dein Admin-Konto ist gesperrt.";
  if (code?.includes("admin_required")) return "Für diese Aktion fehlen dir die Adminrechte.";
  return "Der Passwort-Reset konnte nicht gestartet werden.";
}

export function AdminPanel({ currentRole, currentUserId, onChanged, onExit }: Props) {
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [pinStatus, setPinStatus] = useState<PinStatus | null>(null);
  const [coinStats, setCoinStats] = useState<AdminCoinStats>({ given: 0, removed: 0, since: null });
  const [query, setQuery] = useState("");
  const [targetId, setTargetId] = useState("");
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("Admin-Gutschrift");
  const [adjustmentMode, setAdjustmentMode] = useState<AdjustmentMode>("credit");
  const [adminSessionPin, setAdminSessionPin] = useState("");
  const [entryPin, setEntryPin] = useState("");
  const [entryPinError, setEntryPinError] = useState("");
  const [adminAccessGranted, setAdminAccessGranted] = useState(false);
  const [newPin, setNewPin] = useState("");
  const [confirmPin, setConfirmPin] = useState("");
  const [currentPin, setCurrentPin] = useState("");
  const [changePinOpen, setChangePinOpen] = useState(false);
  const [ownerPinRecovery, setOwnerPinRecovery] = useState(false);
  const [pinFormError, setPinFormError] = useState("");
  const [deleteTarget, setDeleteTarget] = useState<AdminUser | null>(null);
  const [deleteConfirmation, setDeleteConfirmation] = useState("");
  const [deletePromptError, setDeletePromptError] = useState("");
  const [statsResetOpen, setStatsResetOpen] = useState(false);
  const [statsResetError, setStatsResetError] = useState("");
  const [busy, setBusy] = useState(false);
  const [actionBusy, setActionBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const loadAdminData = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const [
      { data: listedUsers, error: usersError },
      { data: status, error: pinStatusError },
      { data: stats, error: statsError },
      { data: visualRoles },
    ] = await Promise.all([
      supabase.rpc("admin_list_users", { p_query: "" }),
      supabase.rpc("admin_pin_status"),
      supabase.rpc("admin_coin_stats"),
      supabase.rpc("admin_list_visual_roles"),
    ]);
    if (usersError || pinStatusError || statsError) {
      setError(adminError(usersError?.message ?? pinStatusError?.message ?? statsError?.message));
      return;
    }
    const visualRoleByUser = new Map<string, AdminUser["visual_role"]>(
      ((visualRoles ?? []) as Array<{ user_id: string; visual_role: AdminUser["visual_role"] }>).map((item) => [item.user_id, item.visual_role]),
    );
    setUsers(((listedUsers ?? []) as Array<Omit<AdminUser, "visual_role">>).map((item) => ({
      ...item,
      visual_role: visualRoleByUser.get(item.user_id) ?? null,
    })));
    setPinStatus((status ?? { has_pin: false, failed_attempts: 0, locked_until: null }) as PinStatus);
    setCoinStats((stats ?? { given: 0, removed: 0, since: null }) as AdminCoinStats);
    setTargetId((current) => currentRole === "admin" && current === currentUserId ? "" : current || (currentRole === "super_admin" ? currentUserId : ""));
  }, [currentRole, currentUserId]);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadAdminData(), 0);
    return () => window.clearTimeout(timer);
  }, [loadAdminData]);

  const filteredUsers = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase("de-CH");
    if (!needle) return users;
    return users.filter((item) => `${item.display_name} ${item.username}`.toLocaleLowerCase("de-CH").includes(needle));
  }, [query, users]);

  const adjustmentUsers = useMemo(
    () => adjustmentMode === "remove"
      ? filteredUsers.filter((item) => item.user_id === currentUserId || item.role !== "super_admin")
      : currentRole === "super_admin" ? filteredUsers : filteredUsers.filter((item) => item.user_id !== currentUserId),
    [adjustmentMode, currentRole, currentUserId, filteredUsers],
  );

  const adminStats = useMemo(() => ({
    users: users.length,
    admins: users.filter((item) => item.role === "admin" || item.role === "super_admin").length,
    locked: users.filter((item) => item.wallet_status === "locked").length,
    circulation: users.reduce((sum, item) => sum + item.balance, 0),
  }), [users]);

  const pinLocked = Boolean(pinStatus?.locked_until);
  const removingCoins = adjustmentMode === "remove";
  const adminAccessPending = pinStatus === null;
  const adminAccessRequired = Boolean(pinStatus?.has_pin) && !adminAccessGranted;

  function chooseAdjustmentMode(nextMode: AdjustmentMode) {
    setAdjustmentMode(nextMode);
    setReason(nextMode === "remove" ? currentRole === "super_admin" ? "Owner-Abzug" : "Admin-Abzug" : "Admin-Gutschrift");
    setError(""); setMessage("");
    const selectedTarget = users.find((item) => item.user_id === targetId);
    const removingOwnCoins = targetId === currentUserId;
    if (nextMode === "remove" && !removingOwnCoins && selectedTarget?.role === "super_admin") {
      setTargetId(users.find((item) => item.user_id !== currentUserId && item.role !== "super_admin")?.user_id ?? "");
    }
    if (nextMode === "credit" && removingOwnCoins && currentRole === "admin") {
      setTargetId(users.find((item) => item.user_id !== currentUserId)?.user_id ?? "");
    }
  }

  function openPinManager(recovery: boolean) {
    setOwnerPinRecovery(recovery);
    setChangePinOpen(!recovery || adminAccessGranted);
    setEntryPin(""); setCurrentPin(""); setNewPin(""); setConfirmPin("");
    setEntryPinError(""); setPinFormError(""); setError(""); setMessage("");
    window.setTimeout(() => document.getElementById("admin-pin-manager")?.scrollIntoView({ behavior: "smooth", block: "center" }), 0);
  }

  async function unlockAdminPanel(event: React.FormEvent) {
    event.preventDefault();
    if (!/^\d{4}$/.test(entryPin)) {
      setEntryPinError("Der PIN muss genau vier Ziffern enthalten.");
      return;
    }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setEntryPinError("");
    const { data, error: rpcError } = await supabase.rpc("admin_verify_pin", { p_pin: entryPin });
    setBusy(false);
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      setEntryPin("");
      setEntryPinError(pinError(result?.error ?? rpcError?.message));
      await loadAdminData();
      return;
    }
    setAdminSessionPin(entryPin);
    setEntryPin("");
    setEntryPinError("");
    setAdminAccessGranted(true);
  }

  function expireAdminAccess(message?: string) {
    setAdminSessionPin("");
    setAdminAccessGranted(false);
    setEntryPin("");
    setEntryPinError(message ?? "Deine Adminpanel-Freigabe ist abgelaufen. Gib deinen PIN erneut ein.");
  }

  async function savePin(event: React.FormEvent) {
    event.preventDefault();
    setError(""); setMessage(""); setPinFormError("");
    if (!/^\d{4}$/.test(newPin) || newPin !== confirmPin) {
      setPinFormError(newPin !== confirmPin ? "Die beiden PIN-Eingaben stimmen nicht überein." : "Der PIN muss genau vier Ziffern enthalten.");
      return;
    }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true);
    const { data, error: rpcError } = ownerPinRecovery
      ? await supabase.rpc("owner_reset_admin_pin", { p_new_pin: newPin })
      : await supabase.rpc("admin_set_pin", {
          p_new_pin: newPin,
          p_current_pin: pinStatus?.has_pin ? currentPin : null,
        });
    setBusy(false);
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      setPinFormError(result?.error === "owner_required" ? "Nur der Owner darf einen gesperrten oder vergessenen PIN zurücksetzen." : pinError(result?.error ?? rpcError?.message));
      return;
    }
    setMessage(ownerPinRecovery ? "Dein Owner-PIN wurde zurückgesetzt. Du kannst jetzt anderen Konten Coins gutschreiben." : pinStatus?.has_pin ? "Dein Admin-PIN wurde geändert." : "Dein persönlicher Admin-PIN ist eingerichtet.");
    setAdminSessionPin(newPin);
    setAdminAccessGranted(true);
    setEntryPin(""); setEntryPinError("");
    setNewPin(""); setConfirmPin(""); setCurrentPin(""); setChangePinOpen(false);
    setOwnerPinRecovery(false); setPinFormError("");
    await loadAdminData();
  }

  async function requestAdjustment(event: React.FormEvent) {
    event.preventDefault();
    setError(""); setMessage("");
    if (!pinStatus?.has_pin) {
      setError("Richte zuerst einmalig deinen persönlichen vierstelligen Admin-PIN ein. Deine Eingaben bleiben erhalten.");
      document.getElementById("admin-pin-setup")?.scrollIntoView({ behavior: "smooth", block: "center" });
      return;
    }
    if (pinLocked) {
      if (currentRole === "super_admin") {
        openPinManager(true);
        setPinFormError("Dein PIN ist nach fünf Fehlversuchen gesperrt. Lege hier einen neuen vierstelligen Owner-PIN fest.");
      } else {
        setError("Dein Admin-PIN ist nach fünf Fehlversuchen vorübergehend gesperrt.");
      }
      return;
    }
    const parsed = Number(amount);
    if (!targetId) { setError("Wähle zuerst einen Benutzer aus."); return; }
    if (!removingCoins && currentRole === "admin" && targetId === currentUserId) { setError("Admins dürfen ihrem eigenen Konto keine Coins gutschreiben."); return; }
    if (!Number.isInteger(parsed) || parsed <= 0) { setError("Gib einen positiven, ganzen Coinbetrag ein."); return; }
    const target = users.find((item) => item.user_id === targetId);
    if (removingCoins && target?.role === "super_admin" && targetId !== currentUserId) { setError("Vom Owner-Konto können keine Coins entzogen werden."); return; }
    if (removingCoins && target && target.balance < parsed) { setError("Dieses Konto besitzt nicht genügend Coins."); return; }
    if (reason.trim().length < 3) { setError(`Gib einen kurzen Grund für ${removingCoins ? "den Abzug" : "die Gutschrift"} ein.`); return; }
    if (!adminAccessGranted || !/^\d{4}$/.test(adminSessionPin)) {
      expireAdminAccess();
      return;
    }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError("");
    const { data, error: rpcError } = await supabase.rpc("admin_adjust_balance_secure", {
      p_target_user_id: targetId,
      p_amount: removingCoins ? -Number(amount) : Number(amount),
      p_reason: reason.trim(),
      p_pin: adminSessionPin,
    });
    setBusy(false);
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const actionError = adjustmentError(result?.error, rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) expireAdminAccess(actionError);
      else setError(actionError);
      await loadAdminData();
      return;
    }
    setAmount("");
    setMessage(removingCoins
      ? `${amount} Coins wurden ${target?.display_name ?? "dem Benutzer"} sicher entzogen.`
      : `Coins wurden sicher an ${target?.display_name ?? "den Benutzer"} gutgeschrieben.`);
    if (!removingCoins) setTargetId(currentRole === "super_admin" ? currentUserId : "");
    await Promise.all([loadAdminData(), onChanged()]);
  }

  async function changeRole(target: AdminUser) {
    if (currentRole !== "super_admin") {
      setError("Nur der Owner darf Adminrechte vergeben oder entfernen.");
      return;
    }
    const nextRole = target.role === "admin" ? "user" : "admin";
    const action = nextRole === "admin" ? "Adminrechte geben" : "Adminrechte entfernen";
    if (!window.confirm(`${action}: ${target.display_name}?`)) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setActionBusy(`role:${target.user_id}`); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("admin_set_role", {
      p_target_user_id: target.user_id,
      p_role: nextRole,
      p_reason: nextRole === "admin" ? "Adminrechte im Adminpanel vergeben" : "Adminrechte im Adminpanel entfernt",
    });
    setActionBusy("");
    if (rpcError) { setError(adminError(rpcError.message)); return; }
    setMessage(nextRole === "admin" ? `${target.display_name} ist jetzt Admin.` : `${target.display_name} ist jetzt normaler Benutzer.`);
    await Promise.all([loadAdminData(), onChanged()]);
  }

  async function changeAccountStatus(target: AdminUser) {
    const nextStatus = target.wallet_status === "active" ? "locked" : "active";
    const confirmation = nextStatus === "locked"
      ? `${target.display_name} wirklich bannen? Die Person wird automatisch abgemeldet und kann sich danach nicht mehr anmelden.`
      : `Bann für ${target.display_name} wirklich aufheben? Die Person kann sich danach wieder anmelden.`;
    if (!window.confirm(confirmation)) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setActionBusy(`status:${target.user_id}`); setError(""); setMessage("");
    const { data, error: functionError } = await supabase.functions.invoke("admin-account-status", {
      body: { target_user_id: target.user_id, status: nextStatus },
    });
    setActionBusy("");
    const result = data as { error?: string } | null;
    if (functionError || result?.error) { setError(adminError(result?.error ?? functionError?.message)); return; }
    setMessage(nextStatus === "locked" ? `${target.display_name} wurde gebannt und wird automatisch abgemeldet.` : `${target.display_name} wurde entbannt und kann sich wieder anmelden.`);
    await Promise.all([loadAdminData(), onChanged()]);
  }

  async function sendPasswordReset(target: AdminUser) {
    const confirmation = `Reset-Link per E-Mail an ${target.display_name} senden? Das Passwort wird weder angezeigt noch direkt geändert.`;
    if (!window.confirm(confirmation)) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setActionBusy(`password:${target.user_id}`); setError(""); setMessage("");
    const { data, error: functionError } = await supabase.functions.invoke("admin-send-password-reset", {
      body: { target_user_id: target.user_id },
    });
    setActionBusy("");
    const result = data as { error?: string; sent?: boolean } | null;
    if (functionError || result?.error || !result?.sent) {
      setError(passwordResetError(result?.error ?? functionError?.message));
      return;
    }
    setMessage(`Ein sicherer Passwort-Reset-Link wurde an die E-Mail-Adresse von ${target.display_name} gesendet.${target.wallet_status === "locked" ? " Das Konto bleibt bis zum Entbannen gesperrt." : ""}`);
  }

  function openAccountDeletion(target: AdminUser) {
    if (target.user_id === currentUserId) {
      setError("Du kannst dein eigenes Konto nicht löschen.");
      return;
    }
    if (target.role === "super_admin") {
      setError("Das Owner-Konto kann nicht gelöscht werden.");
      return;
    }
    if (currentRole === "admin" && target.role === "admin") {
      setError("Admins können keine anderen Admin-Konten löschen.");
      return;
    }
    setDeleteTarget(target);
    setDeleteConfirmation("");
    setDeletePromptError("");
    setError("");
    setMessage("");
  }

  async function deleteAccount(event: React.FormEvent) {
    event.preventDefault();
    if (!deleteTarget) return;
    if (deleteConfirmation.trim().toLocaleLowerCase("de-CH") !== deleteTarget.display_name.trim().toLocaleLowerCase("de-CH")) {
      setDeletePromptError("Gib den angezeigten Namen genau ein, um die Löschung zu bestätigen.");
      return;
    }
    if (!adminAccessGranted || !/^\d{4}$/.test(adminSessionPin)) {
      setDeleteTarget(null);
      expireAdminAccess();
      return;
    }

    const supabase = getSupabase();
    if (!supabase) return;
    setActionBusy(`delete:${deleteTarget.user_id}`);
    setDeletePromptError("");
    const { data, error: functionError } = await supabase.functions.invoke("owner-delete-account", {
      body: { target_user_id: deleteTarget.user_id, pin: adminSessionPin },
    });
    setActionBusy("");
    const result = data as { error?: string; deleted?: boolean } | null;
    if (functionError || result?.error || !result?.deleted) {
      const deletionError = accountDeletionError(result?.error ?? functionError?.message);
      if (result?.error?.startsWith("admin_pin_")) {
        setDeleteTarget(null);
        expireAdminAccess(deletionError);
      } else {
        setDeletePromptError(deletionError);
      }
      await loadAdminData();
      return;
    }

    const deletedName = deleteTarget.display_name;
    if (targetId === deleteTarget.user_id) setTargetId(currentUserId);
    setDeleteTarget(null);
    setDeleteConfirmation("");
    setDeletePromptError("");
    setMessage(`${deletedName} wurde dauerhaft gelöscht. Die bisherige E-Mail-Adresse ist sofort wieder für ein neues Konto frei. Frühere Buchungen werden als „Gelöschtes Konto“ angezeigt.`);
    await Promise.all([loadAdminData(), onChanged()]);
  }

  async function setVisualRole(target: AdminUser, visualRole: AdminUser["visual_role"]) {
    if (!adminAccessGranted || !/^\d{4}$/.test(adminSessionPin)) {
      expireAdminAccess();
      return;
    }
    if (target.user_id === currentUserId) {
      setError("Die Demo-Anzeige kann nicht für das eigene Konto gesetzt werden.");
      return;
    }
    if (target.role === "super_admin") {
      setError("Das echte Owner-Konto ist geschützt.");
      return;
    }
    const actionLabel = visualRoleLabel(visualRole);
    if (!window.confirm(`${visualRole ? `${actionLabel} für` : "Fun-Rang für"} ${target.display_name} setzen?\n\nDies ändert keine echten Rollen oder Rechte.`)) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setActionBusy(`visual:${target.user_id}:${visualRole ?? "none"}`); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_set_visual_role", {
      p_target_user_id: target.user_id,
      p_visual_role: visualRole,
      p_pin: adminSessionPin,
    });
    setActionBusy("");
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const actionError = adminError(result?.error ?? rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) expireAdminAccess(actionError);
      else setError(actionError);
      return;
    }
    setMessage(visualRole ? `${target.display_name} trägt jetzt ${actionLabel}.` : `Der Fun-Rang für ${target.display_name} wurde entfernt.`);
    await loadAdminData();
  }

  function openStatsReset() {
    setError(""); setMessage(""); setStatsResetError("");
    if (!pinStatus?.has_pin) {
      setError("Richte zuerst deinen persönlichen vierstelligen Admin-PIN ein.");
      document.getElementById("admin-pin-setup")?.scrollIntoView({ behavior: "smooth", block: "center" });
      return;
    }
    if (pinLocked) {
      setError("Dein Admin-PIN ist vorübergehend gesperrt. Der Statistik-Reset wurde nicht gestartet.");
      return;
    }
    setStatsResetOpen(true);
  }

  async function resetCoinStats(event: React.FormEvent) {
    event.preventDefault();
    if (!adminAccessGranted || !/^\d{4}$/.test(adminSessionPin)) {
      setStatsResetOpen(false);
      expireAdminAccess();
      return;
    }
    const supabase = getSupabase();
    if (!supabase) return;
    setActionBusy("stats-reset"); setStatsResetError("");
    const { data, error: rpcError } = await supabase.rpc("admin_reset_coin_stats", { p_pin: adminSessionPin });
    setActionBusy("");
    const result = data as SecureResult | null;
    if (rpcError || !result?.ok) {
      const resetError = pinError(result?.error ?? rpcError?.message);
      if (result?.error?.startsWith("admin_pin_")) {
        setStatsResetOpen(false);
        expireAdminAccess(resetError);
      } else {
        setStatsResetError(resetError);
      }
      await loadAdminData();
      return;
    }
    setStatsResetOpen(false); setStatsResetError("");
    setMessage("Deine Plus/Minus-Statistik wurde auf 0 gesetzt. Guthaben und Transaktionsverlauf blieben unverändert.");
    await loadAdminData();
  }

  return (
    <section className="card card-pad admin-panel" id="admin-panel">
      <div className="admin-panel-head">
        <div><div className="eyebrow">Geschützter Bereich</div><h2>Adminpanel</h2><p>Dein persönlicher PIN entsperrt das Adminpanel einmalig, bis du diesen Tab wieder verlässt.</p></div>
        {pinStatus?.has_pin && <div className="admin-pin-actions"><button className="secondary" type="button" onClick={() => openPinManager(false)}>PIN ändern</button>{currentRole === "super_admin" && <button className="secondary" type="button" onClick={() => openPinManager(true)}>PIN vergessen / entsperren</button>}</div>}
      </div>

      {pinLocked && <div className="pin-lockout" role="alert"><div><strong>Dein Admin-PIN ist gesperrt</strong><p>Nach fünf falschen Eingaben wurden geschützte Coin-Aktionen vorübergehend blockiert.</p></div>{currentRole === "super_admin" && <button className="primary compact" type="button" onClick={() => openPinManager(true)}>Neuen Owner-PIN setzen</button>}</div>}

      <div className="admin-stats" aria-label="Admin-Übersicht"><div><span>Konten</span><strong>{adminStats.users}</strong></div><div><span>Admins</span><strong>{adminStats.admins}</strong></div><div><span>Gebannt</span><strong>{adminStats.locked}</strong></div><div><span>Coins im Umlauf</span><strong>{new Intl.NumberFormat("de-CH").format(adminStats.circulation)}</strong></div></div>

      <div className="admin-coin-stats" aria-label="Deine Coin-Statistik">
        <div><span>Von dir gegeben</span><strong className="positive">+{new Intl.NumberFormat("de-CH").format(coinStats.given)}</strong></div>
        <div><span>Von dir entfernt</span><strong className="negative">−{new Intl.NumberFormat("de-CH").format(coinStats.removed)}</strong></div>
        <div className="admin-coin-stats-reset"><p>{coinStats.since ? `Gezählt seit ${new Date(coinStats.since).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })}.` : "Gezählt seit deiner ersten Admin-Aktion."} Der Reset verändert weder Wallets noch Buchungen.</p><button className="secondary compact" type="button" disabled={Boolean(actionBusy)} onClick={openStatsReset}>Plus/Minus zurücksetzen</button></div>
      </div>

      <div className="admin-reserve">
        <div><span>Unbegrenzte Admin-Reserve</span><strong>∞ GIBB</strong><p>{currentRole === "super_admin" ? "Als Owner darfst du Coins für andere und für dein eigenes Konto erzeugen." : "Admins erzeugen Coins nur für andere Konten. Eigengutschriften sind serverseitig gesperrt."}</p></div>
        {currentRole === "super_admin" ? <button className="secondary compact" type="button" onClick={() => { chooseAdjustmentMode("credit"); setQuery(""); setTargetId(currentUserId); document.getElementById("admin-amount")?.focus(); }}>Mir selbst Coins geben</button> : <span>Eigengutschrift gesperrt</span>}
      </div>

      {!pinStatus?.has_pin && <form className="pin-setup" id="admin-pin-setup" onSubmit={savePin}>
        <div><strong>1. Admin-PIN einrichten</strong><p>Lege einmalig vier Ziffern fest. Der PIN wird gehasht gespeichert und ist für andere Admins nicht sichtbar.</p></div>
        <div className="pin-fields"><input className="input pin-input" aria-label="Neuer vierstelliger Admin-PIN" type="password" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} placeholder="••••" value={newPin} onChange={(event) => setNewPin(event.target.value.replace(/\D/g, "").slice(0, 4))} /><input className="input pin-input" aria-label="Admin-PIN bestätigen" type="password" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} placeholder="••••" value={confirmPin} onChange={(event) => setConfirmPin(event.target.value.replace(/\D/g, "").slice(0, 4))} /><button className="primary compact" type="submit" disabled={busy}>PIN speichern</button></div>
      </form>}

      <GameAdminControls adminPin={adminSessionPin} currentRole={currentRole} pinReady={Boolean(pinStatus?.has_pin)} pinLocked={pinLocked} onPinRejected={expireAdminAccess} />

      <div className="admin-credit-head"><div><strong>{removingCoins ? "Coins von einem Benutzer entfernen" : pinStatus?.has_pin ? "Coins aus der Admin-Reserve gutschreiben" : "2. Coins gutschreiben"}</strong><p>{removingCoins ? currentRole === "super_admin" ? "Als Owner kannst du Coins von deinem eigenen und von fremden Konten entziehen. Andere Admins können dein Owner-Guthaben nicht verändern. Kein Guthaben fällt unter null und jeder Abzug wird protokolliert." : "Als Admin kannst du Coins von deinem eigenen und von anderen Benutzerkonten entziehen. Das Owner-Konto bleibt geschützt, kein Guthaben fällt unter null und jeder Abzug wird protokolliert." : currentRole === "super_admin" ? "Als Owner darfst du auch deinem eigenen Konto Coins gutschreiben. Jede Gutschrift wird protokolliert." : "Nur an andere Konten. Eigengutschriften sind serverseitig gesperrt und jede erlaubte Gutschrift wird protokolliert."}</p></div><span>{pinStatus?.has_pin ? "PIN geschützt" : "PIN fehlt"}</span></div>
      <div className="admin-adjust-tabs" role="tablist" aria-label="Coin-Aktion"><button type="button" role="tab" aria-selected={!removingCoins} className={!removingCoins ? "active" : ""} onClick={() => chooseAdjustmentMode("credit")}>Coins geben</button><button type="button" role="tab" aria-selected={removingCoins} className={removingCoins ? "active remove" : ""} onClick={() => chooseAdjustmentMode("remove")}>Coins entfernen</button></div>
      <form className={`admin-adjust-form ${!pinStatus?.has_pin ? "awaiting-pin" : ""}`} onSubmit={requestAdjustment}>
        <div className="field"><label htmlFor="admin-user-search">Benutzer suchen</label><input className="input" id="admin-user-search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Name oder Benutzername" /></div>
        <div className="field"><label htmlFor="admin-target">{removingCoins ? "Benutzer" : "Empfänger"}</label><select className="input" id="admin-target" value={targetId} onChange={(event) => setTargetId(event.target.value)}><option value="">Benutzer auswählen …</option>{adjustmentUsers.map((item) => <option key={item.user_id} value={item.user_id}>{item.user_id === currentUserId ? "Ich · " : ""}{item.display_name} (@{item.username}) · {item.balance} GIBB</option>)}</select></div>
        <div className="field"><label htmlFor="admin-amount">{removingCoins ? "Coins entfernen" : "Coins gutschreiben"}</label><input className="input" id="admin-amount" type="number" inputMode="numeric" min="1" step="1" value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="100" /></div>
        <div className="field"><label htmlFor="admin-reason">Grund</label><input className="input" id="admin-reason" value={reason} onChange={(event) => setReason(event.target.value)} maxLength={120} placeholder="z. B. Projektpreis" /></div>
        <button className={removingCoins ? "admin-danger" : "primary"} type="submit" disabled={busy}>{pinStatus?.has_pin ? removingCoins ? "Coins sicher entfernen" : "Coins gutschreiben" : "PIN einrichten & freischalten"}</button>
      </form>

      {changePinOpen && <form className="change-pin-form" id="admin-pin-manager" onSubmit={savePin}>
        <div className="pin-manager-copy"><strong>{ownerPinRecovery ? "Owner-PIN zurücksetzen" : "Admin-PIN ändern"}</strong><p>{ownerPinRecovery ? "Lege einen neuen persönlichen PIN fest. Der alte PIN und die Sperre werden sicher ersetzt." : "Bestätige die Änderung mit deinem bisherigen PIN."}</p></div>
        {!ownerPinRecovery && <div className="field"><label htmlFor="current-admin-pin">Bisheriger PIN</label><input className="input pin-input" id="current-admin-pin" type="password" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} value={currentPin} onChange={(event) => { setCurrentPin(event.target.value.replace(/\D/g, "").slice(0, 4)); setPinFormError(""); }} /></div>}
        <div className="field"><label htmlFor="new-admin-pin">Neuer PIN</label><input className="input pin-input" id="new-admin-pin" type="password" inputMode="numeric" maxLength={4} value={newPin} onChange={(event) => setNewPin(event.target.value.replace(/\D/g, "").slice(0, 4))} /></div>
        <div className="field"><label htmlFor="confirm-admin-pin">Neuen PIN bestätigen</label><input className="input pin-input" id="confirm-admin-pin" type="password" inputMode="numeric" maxLength={4} value={confirmPin} onChange={(event) => setConfirmPin(event.target.value.replace(/\D/g, "").slice(0, 4))} /></div>
        <div className="pin-manager-actions"><button className="secondary" type="button" disabled={busy} onClick={() => { setChangePinOpen(false); setOwnerPinRecovery(false); setPinFormError(""); }}>Abbrechen</button><button className="primary compact" type="submit" disabled={busy || newPin.length !== 4 || confirmPin.length !== 4 || (!ownerPinRecovery && pinStatus?.has_pin && currentPin.length !== 4)}>{busy ? "Wird gespeichert …" : ownerPinRecovery ? "Owner-PIN zurücksetzen" : "Neuen PIN speichern"}</button></div>
        {pinFormError && <p className="pin-form-error" role="alert">{pinFormError}</p>}
      </form>}

      <div className="admin-users-head">
        <div><strong>Konten, Rollen, Banns und Passwort-Reset</strong><p>{currentRole === "super_admin" ? "Als Owner kannst du Benutzer und Admins bannen, Rollen verwalten, Reset-Links senden und alle fremden Konten dauerhaft löschen. Dein Owner-Konto ist systemweit gegen Löschung geschützt." : "Admins können normale Benutzer bannen, ihr Passwort zurücksetzen und ihre Konten dauerhaft löschen. Owner- und andere Admin-Konten bleiben geschützt."}<br /><span className="admin-demo-disclaimer">Fun-Ränge sind nur visuell und geben niemals Rechte.</span></p></div>
        <span>{filteredUsers.length} Konten</span>
      </div>
      <div className="admin-user-list">
        {filteredUsers.map((item) => {
          const ownAccount = item.user_id === currentUserId;
          const protectedAccount = item.role === "super_admin";
          const peerAdmin = currentRole === "admin" && item.role === "admin";
          const deleteProtected = ownAccount || protectedAccount || peerAdmin;
          const roleBusy = actionBusy === `role:${item.user_id}`;
          const statusBusy = actionBusy === `status:${item.user_id}`;
          const passwordBusy = actionBusy === `password:${item.user_id}`;
          const deleteBusy = actionBusy === `delete:${item.user_id}`;
          return <article className="admin-user" key={item.user_id}>
            <div className="admin-user-main">
              <strong>{item.display_name}</strong>
              <span>@{item.username} · {item.balance} GIBB</span>
            </div>
            <div className="admin-user-badges">
              <span className={`admin-badge role-${item.role}`}>{item.role === "super_admin" ? "Owner" : item.role === "admin" ? "Admin" : "Benutzer"}</span>
              <span className={`admin-badge status-${item.wallet_status}`}>{item.wallet_status === "locked" ? "Gebannt" : "Aktiv"}</span>
              {item.visual_role && <span className="admin-badge visual-role-demo">{visualRoleLabel(item.visual_role)}</span>}
            </div>
            <div className="admin-user-actions">
              {currentRole === "super_admin" ? <button className="secondary compact" type="button" disabled={ownAccount || protectedAccount || actionBusy !== ""} onClick={() => void changeRole(item)}>{roleBusy ? "Speichert …" : item.role === "admin" ? "Admin entfernen" : "Admin geben"}</button> : <span className="owner-only-note">Nur Owner</span>}
              {currentRole !== "user" && !protectedAccount && !ownAccount && <div className="admin-demo-actions" aria-label={`Fun-Rang für ${item.display_name}`}><button className="secondary compact" type="button" disabled={!adminAccessGranted || actionBusy !== ""} onClick={() => void setVisualRole(item, "demo_admin")}>{actionBusy === `visual:${item.user_id}:demo_admin` ? "Speichert …" : "Admin 1 · Anzeige"}</button><button className="secondary compact" type="button" disabled={!adminAccessGranted || actionBusy !== ""} onClick={() => void setVisualRole(item, "demo_owner")}>{actionBusy === `visual:${item.user_id}:demo_owner` ? "Speichert …" : "Owner 1 · Anzeige"}</button>{item.visual_role && <button className="secondary compact" type="button" disabled={!adminAccessGranted || actionBusy !== ""} onClick={() => void setVisualRole(item, null)}>{actionBusy === `visual:${item.user_id}:none` ? "Entfernt …" : "Entfernen"}</button>}</div>}
              <button className="secondary compact" type="button" disabled={ownAccount || protectedAccount || peerAdmin || actionBusy !== ""} onClick={() => void sendPasswordReset(item)}>{passwordBusy ? "Sendet …" : "Passwort-Reset"}</button>
              <button className={item.wallet_status === "locked" ? "secondary compact" : "admin-danger compact"} type="button" disabled={ownAccount || protectedAccount || peerAdmin || actionBusy !== ""} onClick={() => void changeAccountStatus(item)}>{statusBusy ? "Speichert …" : item.wallet_status === "locked" ? "Entbannen" : "Bannen"}</button>
              <button className="account-delete compact" type="button" disabled={deleteProtected || actionBusy !== ""} title={protectedAccount ? "Das Owner-Konto ist geschützt" : peerAdmin ? "Admins können keine anderen Admins löschen" : ownAccount ? "Das eigene Konto kann nicht gelöscht werden" : undefined} onClick={() => openAccountDeletion(item)}>{deleteBusy ? "Löscht …" : "Löschen"}</button>
            </div>
          </article>;
        })}
      </div>

      {message && <p className="message" role="status">{message}</p>}
      {error && <p className="message error" role="alert">{error}</p>}

      {statsResetOpen && <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && actionBusy !== "stats-reset") { setStatsResetOpen(false); setStatsResetError(""); } }}><section className="pin-modal" role="dialog" aria-modal="true" aria-labelledby="stats-reset-title"><div className="pin-lock" aria-hidden="true">±</div><h3 id="stats-reset-title">Plus/Minus auf 0 setzen?</h3><p>Nur deine persönlichen Zähler werden neu gestartet. Guthaben, Konten, Transaktionen und das Admin-Protokoll bleiben vollständig erhalten. Deine PIN-Freigabe für diesen Adminpanel-Besuch wird verwendet.</p><form onSubmit={resetCoinStats}>{statsResetError && <p className="pin-modal-error" role="alert">{statsResetError}</p>}<div className="modal-actions"><button className="secondary" type="button" disabled={actionBusy === "stats-reset"} onClick={() => { setStatsResetOpen(false); setStatsResetError(""); }}>Abbrechen</button><button className="admin-danger compact" type="submit" disabled={actionBusy === "stats-reset"}>{actionBusy === "stats-reset" ? "Setzt zurück …" : "Sicher zurücksetzen"}</button></div></form></section></div>}

      {deleteTarget && <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !actionBusy) { setDeleteTarget(null); setDeletePromptError(""); } }}><section className="pin-modal account-delete-modal" role="dialog" aria-modal="true" aria-labelledby="account-delete-title"><div className="delete-warning" aria-hidden="true">!</div><h3 id="account-delete-title">Account dauerhaft löschen?</h3><p>Der Zugang von <strong>{deleteTarget.display_name}</strong> wird unwiderruflich entfernt. Das Profil, Wallet und persönliche App-Daten verschwinden. Frühere Buchungen bleiben anonymisiert als Nachweis erhalten. Deine PIN-Freigabe für diesen Adminpanel-Besuch wird verwendet.</p><form onSubmit={deleteAccount}><div className="field"><label htmlFor="delete-account-confirmation">Zur Bestätigung „{deleteTarget.display_name}“ eingeben</label><input className="input" id="delete-account-confirmation" autoComplete="off" value={deleteConfirmation} onChange={(event) => { setDeleteConfirmation(event.target.value); setDeletePromptError(""); }} /></div>{deletePromptError && <p className="pin-modal-error" role="alert">{deletePromptError}</p>}<div className="modal-actions"><button className="secondary" type="button" disabled={Boolean(actionBusy)} onClick={() => { setDeleteTarget(null); setDeleteConfirmation(""); setDeletePromptError(""); }}>Abbrechen</button><button className="account-delete confirm-delete" type="submit" disabled={Boolean(actionBusy) || deleteConfirmation.trim().length === 0}>{actionBusy ? "Wird gelöscht …" : "Account endgültig löschen"}</button></div></form></section></div>}

      {(adminAccessPending || adminAccessRequired) && <div className="modal-backdrop admin-access-backdrop" role="presentation">
        <section className="pin-modal" role="dialog" aria-modal="true" aria-labelledby="admin-access-title">
          <div className="pin-lock" aria-hidden="true">••••</div>
          <h3 id="admin-access-title">{ownerPinRecovery ? "Owner-PIN zurücksetzen" : "Adminpanel entsperren"}</h3>
          {adminAccessPending ? <><div className="loader" aria-hidden="true" /><p>Dein geschützter Admin-Zugang wird vorbereitet …</p></> : ownerPinRecovery ? <>
            <p>Lege einen neuen persönlichen Owner-PIN fest. Nach dem sicheren Zurücksetzen ist das Adminpanel für diesen Besuch direkt freigeschaltet.</p>
            <form onSubmit={savePin}>
              <div className="field"><label htmlFor="entry-owner-pin">Neuer PIN</label><input className="input pin-modal-input" id="entry-owner-pin" type="password" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} autoComplete="off" placeholder="0000" value={newPin} onChange={(event) => { setNewPin(event.target.value.replace(/\D/g, "").slice(0, 4)); setPinFormError(""); }} /></div>
              <div className="field"><label htmlFor="entry-owner-pin-confirm">Neuen PIN bestätigen</label><input className="input pin-modal-input" id="entry-owner-pin-confirm" type="password" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} autoComplete="off" placeholder="0000" value={confirmPin} onChange={(event) => { setConfirmPin(event.target.value.replace(/\D/g, "").slice(0, 4)); setPinFormError(""); }} /></div>
              {pinFormError && <p className="pin-modal-error" role="alert">{pinFormError}</p>}
              <div className="modal-actions"><button className="secondary" type="button" disabled={busy} onClick={() => { setOwnerPinRecovery(false); setNewPin(""); setConfirmPin(""); setPinFormError(""); }}>Zurück</button><button className="primary compact" type="submit" disabled={busy || newPin.length !== 4 || confirmPin.length !== 4}>{busy ? "Wird gespeichert …" : "Owner-PIN zurücksetzen"}</button></div>
            </form>
          </> : <>
            <p>Gib deinen persönlichen vierstelligen PIN einmal ein. Die Freigabe gilt nur, solange du im Adminpanel bleibst, und wird beim Verlassen sofort gelöscht.</p>
            <form onSubmit={unlockAdminPanel}>
              <input className="input pin-modal-input" aria-label="Vierstelliger PIN zum Entsperren des Adminpanels" aria-invalid={Boolean(entryPinError)} aria-describedby={entryPinError ? "admin-access-error" : undefined} type="password" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} autoComplete="off" placeholder="0000" value={entryPin} onChange={(event) => { setEntryPin(event.target.value.replace(/\D/g, "").slice(0, 4)); setEntryPinError(""); }} />
              {entryPinError && <p className="pin-modal-error" id="admin-access-error" role="alert">{entryPinError}</p>}
              {currentRole === "super_admin" && entryPinError && <button className="pin-recovery-link" type="button" onClick={() => openPinManager(true)}>PIN vergessen oder gesperrt? Jetzt zurücksetzen</button>}
              <div className="modal-actions"><button className="secondary" type="button" disabled={busy} onClick={onExit}>Zurück zum Wallet</button><button className="primary compact" type="submit" disabled={busy || entryPin.length !== 4}>{busy ? "Wird geprüft …" : "Adminpanel öffnen"}</button></div>
            </form>
          </>}
        </section>
      </div>}
    </section>
  );
}
