"use client";

import type { User } from "@supabase/supabase-js";
import Image from "next/image";
import { useCallback, useEffect, useMemo, useState } from "react";
import { createCheckoutSession, getSupabase, getUsableSupabaseSession, isSupabaseAuthError, waitForSupabaseAuthRetry } from "../lib/supabase";
import type { Profile, Recipient, Transaction, Wallet } from "../lib/types";
import { AbuseReports } from "./AbuseReports";
import { AdminPanel } from "./AdminPanel";
import { AdminSecurityCenter } from "./AdminSecurityCenter";
import { BlockchainOverview } from "./BlockchainOverview";
import { BrowserMinerCard } from "./BrowserMinerCard";
import { LocalMinerCard } from "./LocalMinerCard";
import { GroupWallets } from "./GroupWallets";
import { GameCenter } from "./GameCenter";
import { NotificationCenter } from "./NotificationCenter";
import { PaymentsHub } from "./PaymentsHub";
import { PwaInstallCard } from "./PwaInstallCard";
import { PlayerSafetyPanel } from "./PlayerSafetyPanel";
import { ProfileEditor } from "./ProfileEditor";
import { SupportPrivacyCenter } from "./SupportPrivacyCenter";
import { QrWallet } from "./QrWallet";
import { RewardsHub } from "./RewardsHub";
import { UserProfileModal } from "./UserProfileModal";

type Props = { user: User };
type TransactionFilter = "all" | "received" | "sent";
type DashboardView = "home" | "send" | "games" | "community" | "activity" | "chain" | "account" | "admin";
type OfflineSnapshot = { profile: Profile; wallet: Wallet; transactions: Transaction[]; savedAt: string; statsResetAt?: string | null };

const dashboardViews: Array<{ key: Exclude<DashboardView, "admin">; label: string; icon: string }> = [
  { key: "home", label: "Home", icon: "⌂" },
  { key: "send", label: "Senden", icon: "↗" },
  { key: "games", label: "Spiele", icon: "◆" },
  { key: "community", label: "Community", icon: "◎" },
  { key: "activity", label: "Aktivität", icon: "≡" },
  { key: "chain", label: "Blockchain", icon: "⛓" },
  { key: "account", label: "Konto", icon: "●" },
];

function viewFromHash(hash: string): DashboardView {
  if (["#home", "#wallet", "#top", ""].includes(hash)) return "home";
  if (hash === "#send") return "send";
  if (hash === "#games") return "games";
  if (hash === "#community") return "community";
  if (hash === "#activity") return "activity";
  if (["#chain", "#blockchain", "#mining"].includes(hash)) return "chain";
  if (hash === "#account") return "account";
  if (hash === "#admin") return "admin";
  if (["#send-coins", "#qr-code", "#requests", "#buy-coins"].includes(hash)) return "send";
  if (hash === "#game-center") return "games";
  if (["#group-wallets", "#reports"].includes(hash)) return "community";
  if (["#transactions", "#notifications"].includes(hash)) return "activity";
  if (["#profile", "#install-app"].includes(hash)) return "account";
  if (["#security", "#admin-panel"].includes(hash)) return "admin";
  return "home";
}

// Auf false bleibt die Kauf-Funktion unsichtbar. Für eine spätere Aktivierung
// muss nur dieser Schalter geändert und ein Zahlungsanbieter verbunden werden.
const COIN_PURCHASES_ENABLED = false;

const coinPacks = [
  { id: "small", coins: 100, price: "CHF 1.00", label: "Starter" },
  { id: "medium", coins: 300, price: "CHF 3.00", label: "Beliebt" },
  { id: "large", coins: 750, price: "CHF 7.50", label: "Power" },
] as const;

const quickAmounts = [10, 25, 50, 100];
const MAX_TRANSFER_AMOUNT = 100_000;

function safeMessage(message?: string) {
  if (message?.includes("insufficient_funds") || message?.includes("insufficient_balance")) return "Dein Guthaben reicht für diese Zahlung nicht aus.";
  if (message?.includes("recipient_not_found")) return "Der Empfänger wurde nicht gefunden.";
  if (message?.includes("invalid_amount")) return "Bitte gib einen positiven, ganzen Betrag ein.";
  if (message?.includes("same_user") || message?.includes("self_transfer_not_allowed")) return "Du kannst keine Coins an dich selbst senden.";
  if (message?.includes("transaction_limit_exceeded")) return "Pro Transaktion sind maximal 100’000 GIBB möglich.";
  if (message?.includes("wallet_locked")) return "Dein Konto ist gesperrt. Die Zahlung wurde nicht ausgeführt.";
  if (message?.includes("recipient_wallet_locked")) return "Das Empfängerkonto ist aktuell gesperrt.";
  return "Die Transaktion konnte nicht abgeschlossen werden. Versuche es gleich nochmals.";
}

function checkoutMessage(code?: string) {
  if (code === "not_authenticated") return "Bitte melde dich erneut an und starte den Kauf danach nochmals.";
  if (code === "purchases_disabled") return "Käufe sind momentan nicht verfügbar.";
  if (code === "payment_not_configured") return "Die Zahlungsverbindung ist noch nicht vollständig eingerichtet.";
  if (code === "stripe_authentication_error") return "Der Stripe-Zugang muss neu verbunden werden.";
  if (code === "stripe_invalid_request_error") return "Stripe muss zuerst vollständig aktiviert werden, bevor Zahlungen möglich sind.";
  if (code === "network_error") return "Die Zahlungsseite ist gerade nicht erreichbar. Prüfe die Verbindung und versuche es nochmals.";
  return "Der sichere Checkout konnte nicht gestartet werden. Versuche es später erneut.";
}

function transactionTypeLabel(type: string) {
  if (type === "TRANSFER") return "Transfer";
  if (type === "PURCHASE") return "Kauf";
  if (type === "ADMIN_MINT") return "Admin-Gutschrift";
  if (type === "GAME_ENTRY") return "Spieleinsatz";
  if (type === "GAME_REWARD") return "Spielgewinn";
  if (type === "MINING_REWARD") return "Mining-Belohnung";
  if (type === "WELCOME") return "Startguthaben";
  return type.replaceAll("_", " ").toLocaleLowerCase("de-CH");
}

function downloadText(filename: string, content: string, type = "text/plain;charset=utf-8") {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const anchor = document.createElement("a"); anchor.href = url; anchor.download = filename; anchor.click(); URL.revokeObjectURL(url);
}

// PostgREST meldet eine fehlende Datenbankfunktion mit PGRST202.
function isMissingFunction(error: { code?: string } | null | undefined) {
  return error?.code === "PGRST202";
}

// Solange die Datenbankfunktion fehlt, merkt sich der Browser den Reset-Zeitpunkt.
// Sobald die Migration angewendet ist, gewinnt der Serverwert automatisch.
const statsResetKey = (userId: string) => `gibb-stats-reset:${userId}`;

function readLocalStatsReset(userId: string) {
  try {
    return localStorage.getItem(statsResetKey(userId));
  } catch {
    return null;
  }
}

function writeLocalStatsReset(userId: string, value: string) {
  try {
    localStorage.setItem(statsResetKey(userId), value);
  } catch {
    // Privater Modus ohne Speicher: der Reset gilt dann nur für diese Sitzung.
  }
}

export function Dashboard({ user }: Props) {
  const [profile, setProfile] = useState<Profile | null>(null);
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [transactionHasMore, setTransactionHasMore] = useState(false);
  const [transactionLoadingMore, setTransactionLoadingMore] = useState(false);
  const [chainValid, setChainValid] = useState<boolean | null>(null);
  const [query, setQuery] = useState("");
  const [recipients, setRecipients] = useState<Recipient[]>([]);
  const [selected, setSelected] = useState<Recipient | null>(null);
  const [amount, setAmount] = useState("");
  const [note, setNote] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [dataError, setDataError] = useState("");
  const [sending, setSending] = useState(false);
  const [refreshing, setRefreshing] = useState(true);
  const [recipientSearching, setRecipientSearching] = useState(false);
  const [checkoutPack, setCheckoutPack] = useState<string | null>(null);
  const [purchaseMessage, setPurchaseMessage] = useState("");
  const [purchaseError, setPurchaseError] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [transactionFilter, setTransactionFilter] = useState<TransactionFilter>("all");
  const [transactionQuery, setTransactionQuery] = useState("");
  const [showAllTransactions, setShowAllTransactions] = useState(false);
  const [transactionsCollapsed, setTransactionsCollapsed] = useState(true);
  const [unreadNotifications, setUnreadNotifications] = useState(0);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [activeView, setActiveView] = useState<DashboardView>("home");
  const [offlineMode, setOfflineMode] = useState(false);
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [minAmount, setMinAmount] = useState("");
  const [maxAmount, setMaxAmount] = useState("");
  const [statsResetAt, setStatsResetAt] = useState<string | null>(null);
  const [statsResetBusy, setStatsResetBusy] = useState(false);
  const [statsMessage, setStatsMessage] = useState("");
  const [statsError, setStatsError] = useState("");
  const [statsServerBacked, setStatsServerBacked] = useState(true);
  const [adminNotice, setAdminNotice] = useState<{ maintenance?: { enabled?: boolean; message?: string }; announcement?: { enabled?: boolean; title?: string; message?: string } } | null>(null);

  const loadData = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    setRefreshing(true);
    const snapshotKey = `gibb-offline-snapshot:${user.id}`;
    const restoreCachedSnapshot = () => {
      try {
        const cached = JSON.parse(localStorage.getItem(snapshotKey) ?? "null") as OfflineSnapshot | null;
        if (!cached) return false;
        setProfile(cached.profile);
        setWallet(cached.wallet);
        setTransactions(cached.transactions);
        setStatsResetAt(cached.statsResetAt ?? null);
        setLastUpdated(new Date(cached.savedAt));
        setOfflineMode(true);
        setDataError("Offline-Ansicht: letzter sicher gespeicherter Stand. Senden und Spielen benötigen Internet.");
        setRefreshing(false);
        return true;
      } catch {
        return false;
      }
    };

    if (!navigator.onLine && restoreCachedSnapshot()) return;
    if (navigator.onLine) await supabase.rpc("refresh_my_wallet_status");

    const fetchWalletData = () => Promise.all([
      supabase.from("profiles").select("id,display_name,username,email,avatar_url,role,bio,profile_color,equipped_title").eq("id", user.id).single(),
      supabase.from("wallets").select("*").eq("user_id", user.id).single(),
      supabase.from("transactions").select("id,sender_user_id,receiver_user_id,sender_label,receiver_label,amount,type,note,previous_hash,hash,created_at").order("created_at", { ascending: false }).range(0, 249),
      supabase.rpc("verify_hash_chain"),
      supabase.rpc("get_my_visual_role"),
      supabase.rpc("my_wallet_stats_reset"),
    ] as const);

    let results = await fetchWalletData();
    for (let attempt = 0; attempt < 3 && results.some((result) => isSupabaseAuthError(result.error)); attempt += 1) {
      const retryError = results.map((result) => result.error).find(isSupabaseAuthError);
      if (!await waitForSupabaseAuthRetry(retryError, attempt)) break;
      const restoredSession = await getUsableSupabaseSession();
      if (!restoredSession) break;
      results = await fetchWalletData();
    }

    const [profileResult, walletResult, transactionResult, chainResult, visualRoleResult, statsResetResult] = results;
    const retryAuthError = results.map((result) => result.error).find(isSupabaseAuthError);
    if (retryAuthError) {
      if (restoreCachedSnapshot()) return;
      setRefreshing(false);
      setDataError("Die Wallet-Verbindung konnte nicht aktualisiert werden. Deine Anmeldung bleibt gespeichert.");
      return;
    }

    const loadFailed = profileResult.error || walletResult.error || transactionResult.error;
    if (loadFailed && (!profileResult.data || !walletResult.data)) {
      if (restoreCachedSnapshot()) return;
    }
    setDataError(loadFailed ? "Einige Wallet-Daten konnten gerade nicht aktualisiert werden." : "");
    const nextProfile = profileResult.data ? {
      ...(profileResult.data as Profile),
      visual_role: visualRoleResult.error ? null : visualRoleResult.data as Profile["visual_role"],
    } : null;
    const nextWallet = walletResult.data as Wallet | null;
    const nextTransactions = (transactionResult.data ?? []) as Transaction[];
    setTransactionHasMore(nextTransactions.length === 250);
    if (nextProfile) setProfile(nextProfile);
    if (nextWallet) setWallet(nextWallet);
    if (transactionResult.data) setTransactions(nextTransactions);
    const chain = (chainResult.data as Array<{ valid: boolean }> | null)?.[0];
    setChainValid(chainResult.error ? null : chain?.valid ?? false);
    // Fehlt die RPC (noch nicht migrierte Datenbank), bleibt die Statistik ungefiltert.
    const statsRpcMissing = isMissingFunction(statsResetResult.error);
    const nextStatsResetAt = statsResetResult.error
      ? (statsRpcMissing ? readLocalStatsReset(user.id) : null)
      : (statsResetResult.data as { since?: string | null } | null)?.since ?? null;
    setStatsResetAt(nextStatsResetAt);
    setStatsServerBacked(!statsRpcMissing);
    setLastUpdated(new Date());
    setOfflineMode(false);
    if (nextProfile && nextWallet && transactionResult.data) {
      const snapshot: OfflineSnapshot = { profile: nextProfile, wallet: nextWallet, transactions: nextTransactions.slice(0, 40), savedAt: new Date().toISOString(), statsResetAt: nextStatsResetAt };
      localStorage.setItem(snapshotKey, JSON.stringify(snapshot));
    }
    setRefreshing(false);
  }, [user.id]);

  const loadMoreTransactions = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase || transactionLoadingMore || !transactionHasMore) return;
    setTransactionLoadingMore(true);
    const { data, error: transactionError } = await supabase.from("transactions")
      .select("id,sender_user_id,receiver_user_id,sender_label,receiver_label,amount,type,note,previous_hash,hash,created_at")
      .order("created_at", { ascending: false }).range(transactions.length, transactions.length + 249);
    setTransactionLoadingMore(false);
    if (transactionError) { setDataError("Weitere Transaktionen konnten nicht geladen werden."); return; }
    const next = (data ?? []) as Transaction[];
    setTransactions((current) => [...current, ...next.filter((item) => !current.some((existing) => existing.id === item.id))]);
    setTransactionHasMore(next.length === 250);
  }, [transactionHasMore, transactionLoadingMore, transactions.length]);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadData(), 0);
    const refreshOnFocus = () => void loadData();
    const interval = window.setInterval(() => void loadData(), 60_000);
    window.addEventListener("focus", refreshOnFocus);
    window.addEventListener("online", refreshOnFocus);
    window.addEventListener("offline", refreshOnFocus);
    return () => {
      window.clearTimeout(timer);
      window.clearInterval(interval);
      window.removeEventListener("focus", refreshOnFocus);
      window.removeEventListener("online", refreshOnFocus);
      window.removeEventListener("offline", refreshOnFocus);
    };
  }, [loadData]);

  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    let cancelled = false;
    const loadNotice = async () => {
      const { data } = await supabase.rpc("get_public_admin_notice");
      if (!cancelled && data) setAdminNotice(data as typeof adminNotice);
    };
    void loadNotice();
    const timer = window.setInterval(() => void loadNotice(), 60_000);
    return () => { cancelled = true; window.clearInterval(timer); };
  }, []);

  useEffect(() => {
    if (!COIN_PURCHASES_ENABLED) return;
    const timer = window.setTimeout(() => {
      const result = new URLSearchParams(window.location.search).get("purchase");
      if (result === "success") setPurchaseMessage("Zahlung bestätigt. Deine GIBB Coins werden automatisch gutgeschrieben.");
      if (result === "cancelled") setPurchaseError("Der Kauf wurde abgebrochen. Es wurde nichts belastet.");
      if (result) window.history.replaceState({}, "", window.location.pathname);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (!menuOpen) return;
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === "Escape") setMenuOpen(false); };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [menuOpen]);

  useEffect(() => {
    const syncViewWithHash = () => setActiveView(viewFromHash(window.location.hash));
    syncViewWithHash();
    window.addEventListener("hashchange", syncViewWithHash);
    return () => window.removeEventListener("hashchange", syncViewWithHash);
  }, []);

  // Meldet das angemeldete Konto beim lokalen Blockchain-Node an, damit jeder
  // Nutzer der Website automatisch auch auf der Blockchain-Website erscheint.
  // Bestmöglich und still: läuft der Node nicht, passiert einfach nichts.
  useEffect(() => {
    if (!profile) return;
    let node = "http://localhost:8787";
    try { node = localStorage.getItem("gibb-node-url") || node; } catch { /* ignore */ }
    const controller = new AbortController();
    fetch(`${node}/api/register`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ supabaseId: user.id, name: profile.username || profile.display_name || "Konto", balance: wallet?.balance ?? 0 }),
      signal: controller.signal,
    }).catch(() => { /* Node offline: ignorieren */ });
    return () => controller.abort();
  }, [profile, user.id, wallet?.balance]);

  const openView = useCallback((view: DashboardView, target?: string) => {
    setActiveView(view);
    setMenuOpen(false);
    const nextHash = target ? `#${target}` : view === "home" ? "#home" : `#${view}`;
    window.history.replaceState({}, "", nextHash);
    window.setTimeout(() => document.getElementById(target ?? "dashboard-view-top")?.scrollIntoView({ behavior: "smooth", block: "start" }), 0);
  }, []);

  useEffect(() => {
    const supabase = getSupabase();
    const needle = query.trim();
    if (!supabase || selected || needle.length < 2) return;
    let active = true;
    const timer = window.setTimeout(async () => {
      setRecipientSearching(true);
      const { data, error: searchError } = await supabase.rpc("search_users", { p_query: needle });
      if (!active) return;
      if (searchError) {
        setRecipients([]);
        setRecipientSearching(false);
        return;
      }
      setRecipients(((data ?? []) as Array<{ user_id: string; username: string; display_name: string }>).map((item) => ({
        id: item.user_id,
        display_name: item.display_name,
        email_hint: `@${item.username}`,
        avatar_url: null,
      })));
      setRecipientSearching(false);
    }, 250);
    return () => { active = false; window.clearTimeout(timer); };
  }, [query, selected]);

  const selectQrRecipient = useCallback((recipient: Recipient) => {
    setSelected(recipient);
    setQuery(recipient.display_name);
    setRecipients([]);
    setRecipientSearching(false);
    setMessage("");
    setError("");
    setActiveView("send");
    window.setTimeout(() => {
      document.getElementById("send-coins")?.scrollIntoView({ behavior: "smooth", block: "start" });
      document.getElementById("amount")?.focus();
    }, 0);
  }, []);

  const activity = useMemo(() => {
    // Der Reset blendet ältere Buchungen nur aus der Statistik aus. Verlauf,
    // Guthaben und Hash-Kette bleiben vollständig erhalten.
    const since = statsResetAt ? new Date(statsResetAt).getTime() : null;
    const counted = since === null ? transactions : transactions.filter((tx) => new Date(tx.created_at).getTime() >= since);
    const sent = counted.filter((tx) => tx.sender_user_id === user.id);
    const received = counted.filter((tx) => tx.receiver_user_id === user.id);
    return {
      sentCount: sent.length,
      receivedCount: received.length,
      sentAmount: sent.reduce((sum, tx) => sum + tx.amount, 0),
      receivedAmount: received.reduce((sum, tx) => sum + tx.amount, 0),
    };
  }, [statsResetAt, transactions, user.id]);

  const resetHomeStats = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    setStatsMessage(""); setStatsError("");
    if (offlineMode) {
      setStatsError("Im Offline-Modus lässt sich die Statistik nicht zurücksetzen.");
      return;
    }
    if (!window.confirm("Plus/Minus-Statistik auf 0 setzen? Guthaben, Transaktionsverlauf und Hash-Kette bleiben unverändert.")) return;
    setStatsResetBusy(true);
    const { data, error: rpcError } = await supabase.rpc("reset_my_wallet_stats");
    setStatsResetBusy(false);
    const result = data as { ok?: boolean; since?: string | null } | null;
    if (isMissingFunction(rpcError)) {
      const localSince = new Date().toISOString();
      writeLocalStatsReset(user.id, localSince);
      setStatsResetAt(localSince);
      setStatsServerBacked(false);
      setStatsMessage("Statistik auf 0 gesetzt. Der Reset gilt vorerst nur in diesem Browser.");
      return;
    }
    if (rpcError || !result?.ok) {
      setStatsError("Der Reset hat nicht geklappt. Deine Statistik ist unverändert.");
      return;
    }
    setStatsResetAt(result.since ?? new Date().toISOString());
    setStatsMessage("Deine Plus/Minus-Statistik wurde auf 0 gesetzt. Guthaben und Verlauf blieben unverändert.");
    await loadData();
  }, [loadData, offlineMode, user.id]);

  const filteredTransactions = useMemo(() => {
    const needle = transactionQuery.trim().toLocaleLowerCase("de-CH");
    return transactions.filter((tx) => {
      const sent = tx.sender_user_id === user.id;
      if (transactionFilter === "sent" && !sent) return false;
      if (transactionFilter === "received" && sent) return false;
      const created = new Date(tx.created_at).getTime();
      if (dateFrom && created < new Date(`${dateFrom}T00:00:00`).getTime()) return false;
      if (dateTo && created > new Date(`${dateTo}T23:59:59.999`).getTime()) return false;
      if (minAmount && tx.amount < Number(minAmount)) return false;
      if (maxAmount && tx.amount > Number(maxAmount)) return false;
      if (!needle) return true;
      return `${tx.sender_label} ${tx.receiver_label} ${tx.hash} ${tx.type} ${tx.note ?? ""}`.toLocaleLowerCase("de-CH").includes(needle);
    });
  }, [dateFrom, dateTo, maxAmount, minAmount, transactionFilter, transactionQuery, transactions, user.id]);

  const visibleTransactions = showAllTransactions ? filteredTransactions : filteredTransactions.slice(0, 8);
  const parsedAmount = Number(amount);
  const accountLocked = wallet?.status === "locked";
  const amountValid = Number.isInteger(parsedAmount) && parsedAmount > 0 && parsedAmount <= MAX_TRANSFER_AMOUNT;
  const canSend = Boolean(selected && amountValid && !sending && !accountLocked && !offlineMode && parsedAmount <= (wallet?.balance ?? 0));

  async function sendCoins(event: React.FormEvent) {
    event.preventDefault();
    setMessage(""); setError("");
    if (!selected) { setError("Wähle zuerst einen Empfänger aus."); return; }
    if (!amountValid) { setError("Gib einen ganzen Betrag zwischen 1 und 100’000 GIBB ein."); return; }
    if (parsedAmount > (wallet?.balance ?? 0)) { setError("Dein Guthaben reicht für diese Zahlung nicht aus."); return; }
    const supabase = getSupabase();
    if (!supabase) return;
    setSending(true);
    const { error: transferError } = await supabase.rpc("transfer_coins", {
      p_receiver_user_id: selected.id,
      p_amount: parsedAmount,
      p_note: note.trim() || null,
    });
    setSending(false);
    if (transferError) { setError(safeMessage(transferError.message)); return; }
    setMessage(`${parsedAmount} GIBB wurden sicher an ${selected.display_name} gesendet.`);
    setAmount(""); setNote(""); setQuery(""); setSelected(null); setRecipients([]);
    await loadData();
  }

  async function logout() {
    const supabase = getSupabase();
    if (supabase) await supabase.auth.signOut({ scope: "local" });
    localStorage.removeItem(`gibb-offline-snapshot:${user.id}`);
  }

  function exportTransactions() {
    const escape = (value: unknown) => `"${String(value ?? "").replaceAll('"', '""')}"`;
    const rows = [["Datum", "Typ", "Von", "An", "Betrag", "Notiz", "Hash"], ...filteredTransactions.map((tx) => [tx.created_at, transactionTypeLabel(tx.type), tx.sender_label, tx.receiver_label, tx.amount, tx.note ?? "", tx.hash])];
    downloadText(`gibb-transaktionen-${new Date().toISOString().slice(0, 10)}.csv`, "\uFEFF" + rows.map((row) => row.map(escape).join(";")).join("\n"), "text/csv;charset=utf-8");
  }

  function downloadReceipt(tx: Transaction) {
    const sent = tx.sender_user_id === user.id;
    const receipt = ["GIBB COIN · TRANSAKTIONSBELEG", "", `ID: ${tx.id}`, `Datum: ${new Date(tx.created_at).toLocaleString("de-CH")}`, `Typ: ${transactionTypeLabel(tx.type)}`, `Von: ${tx.sender_label}`, `An: ${tx.receiver_label}`, `Betrag: ${tx.amount} GIBB`, `Richtung: ${sent ? "Ausgang" : "Eingang"}`, `Notiz: ${tx.note || "–"}`, `Hash: ${tx.hash}`, `Vorheriger Hash: ${tx.previous_hash}`, "", "Dieser Beleg dokumentiert virtuelle GIBB Coins und ist kein Echtgeld-Zahlungsbeleg."].join("\n");
    downloadText(`gibb-beleg-${tx.id.slice(0, 8)}.txt`, receipt);
  }

  async function buyCoins(packId: (typeof coinPacks)[number]["id"]) {
    if (!COIN_PURCHASES_ENABLED) return;
    setCheckoutPack(packId);
    setPurchaseMessage("");
    setPurchaseError("");
    const result = await createCheckoutSession(packId);
    if (!result.url) {
      setCheckoutPack(null);
      setPurchaseError(checkoutMessage(result.error));
      return;
    }
    window.location.assign(result.url);
  }

  const displayName = profile?.display_name || user.user_metadata?.full_name || "GIBB Benutzer";
  const firstName = displayName.split(" ")[0];
  const avatar = profile?.avatar_url || user.user_metadata?.avatar_url;
  const roleLabel = profile?.role === "super_admin" ? "Owner" : profile?.role === "admin" ? "Admin" : profile?.equipped_title || "Mitglied";
  const visualRoleLabel = profile?.visual_role === "demo_owner" ? "Owner 1 · nur Anzeige" : profile?.visual_role === "demo_admin" ? "Admin 1 · nur Anzeige" : null;
  const formattedBalance = wallet ? new Intl.NumberFormat("de-CH").format(wallet.balance) : "—";

  return (
    <div className="app-shell">
      <header className="header">
        <div className="container header-inner">
          <a className="brand" href="#top" aria-label="GIBB Coin Startseite">
            <span className="coin-mark">G</span>
            <span className="brand-copy"><strong>GIBB Coin</strong><span>Campus Wallet</span></span>
          </a>
          <nav className="desktop-nav" aria-label="Hauptnavigation">
            {dashboardViews.slice(0, 5).map((view) => <button className={activeView === view.key ? "active" : ""} type="button" key={view.key} onClick={() => openView(view.key)}>{view.label}</button>)}
          </nav>
          <div className="header-actions">
            <button className="notification-bell" type="button" onClick={() => openView("activity", "notifications")} aria-label={`${unreadNotifications} ungelesene Benachrichtigungen`}><span aria-hidden="true">◎</span>{unreadNotifications > 0 && <b>{Math.min(unreadNotifications, 99)}</b>}</button>
            <div className="menu-wrap">
              <button className="profile-button" type="button" onClick={() => setMenuOpen((open) => !open)} aria-expanded={menuOpen} aria-haspopup="menu">
                {avatar ? <Image className="avatar" src={avatar} alt="" width={40} height={40} unoptimized referrerPolicy="no-referrer" style={{ borderColor: profile?.profile_color }} /> : <span className="avatar" style={{ background: profile?.profile_color }}>{displayName[0]}</span>}
                <span className="profile-meta"><strong>{displayName}</strong><span>{formattedBalance} GIBB</span></span><span aria-hidden="true">⌄</span>
              </button>
              {menuOpen && <nav className="menu" aria-label="Benutzermenü"><button type="button" onClick={() => openView("home", "wallet")}>Mein Wallet</button><button type="button" onClick={() => openView("games", "game-center")}>Game Center</button><button type="button" onClick={() => openView("send", "requests")}>Anfragen & Kontakte</button><button type="button" onClick={() => openView("send", "qr-code")}>Mein QR-Code</button><button type="button" onClick={() => openView("community", "group-wallets")}>Gruppen-Wallets</button><button type="button" onClick={() => openView("community", "reports")}>Sicherheit & Meldungen</button><button type="button" onClick={() => openView("activity", "transactions")}>Transaktionen</button><button type="button" onClick={() => openView("activity", "notifications")}>Benachrichtigungen</button>{profile?.role !== "user" && <><button type="button" onClick={() => openView("admin", "security")}>2FA-Sicherheit</button><button type="button" onClick={() => openView("admin", "admin-panel")}>Adminpanel</button></>}<button type="button" onClick={() => openView("account", "profile")}>Profil</button><button className="danger" type="button" onClick={logout}>Abmelden</button></nav>}
            </div>
          </div>
        </div>
      </header>

      <main className="container main" id="top">
        {adminNotice?.maintenance?.enabled && <div className="global-alert" role="alert"><strong>Wartungsmodus</strong><span>{adminNotice.maintenance.message || "Einige Funktionen sind vorübergehend pausiert."}</span></div>}
        {adminNotice?.announcement?.enabled && <div className="global-alert" role="status"><strong>{adminNotice.announcement.title || "Wichtiger Hinweis"}</strong><span>{adminNotice.announcement.message}</span></div>}
        {offlineMode && <div className="offline-banner" role="status"><strong>Offline-Modus</strong><span>Du siehst den zuletzt gespeicherten Stand. Schreibende Aktionen sind pausiert.</span><button type="button" onClick={() => void loadData()}>Neu verbinden</button></div>}
        {dataError && <div className="global-alert" role="alert"><span>{dataError}</span><button type="button" onClick={() => void loadData()}>Erneut laden</button></div>}
        <nav className="dashboard-tabs" id="dashboard-view-top" aria-label="Wallet-Bereiche">
          {dashboardViews.map((view) => <button className={activeView === view.key ? "active" : ""} type="button" key={view.key} onClick={() => openView(view.key)}><span aria-hidden="true">{view.icon}</span>{view.label}</button>)}
          {profile?.role !== "user" && <button className={activeView === "admin" ? "active" : ""} type="button" onClick={() => openView("admin")}><span aria-hidden="true">⚙</span>Admin</button>}
        </nav>

        <div className="dashboard-view" hidden={activeView !== "home"} aria-label="Home">
        <section className="hero">
          <div className="hero-copy"><div className="hero-kicker"><span>Persönliches Campus-Wallet</span><b>{roleLabel}</b>{visualRoleLabel && <em className="visual-role-badge">{visualRoleLabel}</em>}</div><h1>Bereit, {firstName}?</h1><p>Sende GIBB Coins in Sekunden, behalte jede Bewegung im Blick und entscheide selbst über deine Benachrichtigungen.</p><div className="hero-actions"><a className="primary-link" href="#send-coins">Coins senden</a><a className="secondary-link" href={COIN_PURCHASES_ENABLED ? "#buy-coins" : "#requests"}>{COIN_PURCHASES_ENABLED ? "Guthaben kaufen" : "Coins anfordern"}</a></div></div>
          <div className="status-stack"><div className={`chain-status ${chainValid === false ? "invalid" : ""}`}><i aria-hidden="true" />{chainValid === null ? "Prüfung läuft" : chainValid ? "Hash-Kette verifiziert" : "Hash-Kette prüfen"}</div><div className="sync-status"><i className={refreshing ? "syncing" : ""} aria-hidden="true" />{refreshing ? "Wird aktualisiert …" : lastUpdated ? `Aktuell · ${lastUpdated.toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit" })}` : "Live verbunden"}</div></div>
        </section>

        <section className="overview-grid" aria-label="Wallet-Übersicht">
          <article className="card balance-card premium-balance" id="wallet"><div className="balance-top"><span>Verfügbares Guthaben</span><b className={accountLocked ? "locked" : "active"}>{accountLocked ? "Gesperrt" : "Aktiv"}</b></div><div className="balance">{formattedBalance} <small>GIBB</small></div><p>Dein Guthaben ist serverseitig geschützt und sofort einsatzbereit.</p><div className="balance-actions"><a href="#send-coins">Senden <span aria-hidden="true">↗</span></a><a href={COIN_PURCHASES_ENABLED ? "#buy-coins" : "#requests"}>{COIN_PURCHASES_ENABLED ? "Aufladen" : "Anfordern"} <span aria-hidden="true">＋</span></a></div></article>
          <article className="stat-card"><span>Erhalten</span><strong>+{new Intl.NumberFormat("de-CH").format(activity.receivedAmount)}</strong><small>{activity.receivedCount} Eingänge</small></article>
          <article className="stat-card"><span>Gesendet</span><strong className="negative">−{new Intl.NumberFormat("de-CH").format(activity.sentAmount)}</strong><small>{activity.sentCount} Ausgänge</small></article>
          <div className="home-stats-reset">
            <p>{statsResetAt ? `Gezählt seit ${new Date(statsResetAt).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })}.` : "Gezählt seit deiner ersten Buchung."} Der Reset verändert weder dein Guthaben noch den Verlauf.</p>
            <button className="secondary compact" type="button" disabled={statsResetBusy || offlineMode} onClick={() => void resetHomeStats()}>{statsResetBusy ? "Wird zurückgesetzt …" : "Statistik zurücksetzen"}</button>
          </div>
          {!statsServerBacked && <p className="home-stats-note">Hinweis: Der Reset wird nur in diesem Browser gespeichert, bis die Datenbank-Migration angewendet ist.</p>}
          {statsMessage && <p className="home-stats-note" role="status">{statsMessage}</p>}
          {statsError && <p className="home-stats-note error" role="alert">{statsError}</p>}
        </section>

        <section className="home-launchpad card" aria-labelledby="home-launchpad-title">
          <div className="home-launchpad-copy"><span>ALLES AN EINEM ORT</span><h2 id="home-launchpad-title">Was möchtest du machen?</h2><p>Dein Home zeigt das echte Wallet. Jede Aktion und jedes Spiel verwendet genau dieses eine Guthaben.</p></div>
          <div className="home-shortcuts">
            <button type="button" onClick={() => openView("send", "send-coins")}><span>↗</span><strong>Coins senden</strong><small>Sicher übertragen</small></button>
            <button type="button" onClick={() => openView("games", "game-center")}><span>◆</span><strong>Spielen</strong><small>Mit Wallet-Guthaben</small></button>
            <button type="button" onClick={() => openView("activity", "transactions")}><span>≡</span><strong>Aktivität</strong><small>Verlauf & Meldungen</small></button>
            <button type="button" onClick={() => openView("community", "group-wallets")}><span>◎</span><strong>Community</strong><small>Gruppen & Sicherheit</small></button>
          </div>
        </section>
        </div>

        <div className="dashboard-view" hidden={activeView !== "send"} aria-label="Senden und Anfragen">
          <div className="view-heading"><span>ZAHLEN & EMPFANGEN</span><h1>Senden</h1><p>Coins übertragen, anfordern und per QR-Code teilen.</p></div>
        <div className={`workspace-grid ${COIN_PURCHASES_ENABLED ? "" : "purchases-disabled"}`}>
          <section className="card card-pad send-card" id="send-coins">
            <div className="section-heading"><div><span className="section-number">01</span><h2>Coins senden</h2></div><small>Maximal 100’000 GIBB pro Transfer</small></div>
            <form onSubmit={sendCoins}>
              <div className="field"><label htmlFor="recipient">Empfänger</label><div className={`search-control ${selected ? "has-selection" : ""}`}><input className="input" id="recipient" value={query} onChange={(event) => { setQuery(event.target.value); setSelected(null); setRecipients([]); setRecipientSearching(false); }} placeholder="Name oder Benutzername suchen …" autoComplete="off" />{selected && <button type="button" aria-label="Empfänger entfernen" onClick={() => { setSelected(null); setQuery(""); setRecipientSearching(false); }}>×</button>}</div>{recipientSearching && <div className="search-hint">Suche läuft …</div>}{!recipientSearching && query.trim().length >= 2 && !selected && recipients.length === 0 && <div className="search-hint">Kein passendes Konto gefunden.</div>}{recipients.length > 0 && <div className="recipient-list">{recipients.map((item) => <button type="button" key={item.id} className="recipient" onClick={() => { setSelected(item); setQuery(item.display_name); setRecipients([]); setRecipientSearching(false); }}><span className="recipient-avatar" aria-hidden="true">{item.display_name[0]}</span><span><strong>{item.display_name}</strong><small>{item.email_hint}</small></span><b aria-hidden="true">→</b></button>)}</div>}</div>
              <div className="field"><label htmlFor="amount">Betrag</label><div className="amount-control"><input className="input" id="amount" value={amount} onChange={(event) => setAmount(event.target.value)} inputMode="numeric" min="1" max={MAX_TRANSFER_AMOUNT} step="1" type="number" placeholder="0" /><span>GIBB</span></div><div className="quick-amounts" aria-label="Schnellbeträge">{quickAmounts.map((value) => <button type="button" key={value} className={parsedAmount === value ? "active" : ""} onClick={() => setAmount(String(value))}>+{value}</button>)}</div></div>
              <div className="field"><label htmlFor="transfer-note">Nachricht <span>optional</span></label><input className="input" id="transfer-note" value={note} onChange={(event) => setNote(event.target.value)} maxLength={160} placeholder="z. B. Danke fürs Mittagessen" /></div>
              <div className="transfer-summary"><span>Du sendest</span><strong>{amountValid ? parsedAmount : 0} GIBB</strong><small>{selected ? `an ${selected.display_name}` : "Empfänger auswählen"}</small></div>
              <button className="primary send-button" disabled={!canSend} type="submit">{sending ? "Wird sicher übertragen …" : canSend ? `${parsedAmount} GIBB senden` : "Transfer vorbereiten"}</button>
              {message && <p className="message success-message" role="status">✓ {message}</p>}{error && <p className="message error" role="alert">{error}</p>}
            </form>
          </section>

          {COIN_PURCHASES_ENABLED && <section className="card card-pad purchase-card" id="buy-coins">
            <div className="section-heading"><div><span className="section-number">02</span><h2>Coins kaufen</h2></div><small>TWINT + Karte</small></div>
            <div className="rate-banner"><span>Fixer Kurs</span><strong>CHF 1 = 100 GIBB</strong><small>Gutschrift erst nach bestätigter Zahlung</small></div>
            <div className="pack-list premium-packs">{coinPacks.map((pack) => <button className={`pack ${pack.id === "medium" ? "featured" : ""}`} type="button" key={pack.id} onClick={() => void buyCoins(pack.id)} disabled={checkoutPack !== null}><span className="pack-label">{pack.label}</span><span><strong>{pack.coins} GIBB</strong><small>Einmaliger Kauf</small></span><b>{checkoutPack === pack.id ? "Öffnet …" : pack.price}</b></button>)}</div>
            <div className="payment-methods"><span className="twint-badge">TWINT</span><span>Sicherer Checkout · CHF</span></div>{purchaseMessage && <p className="message success-message" role="status">✓ {purchaseMessage}</p>}{purchaseError && <p className="message error" role="alert">{purchaseError}</p>}<p className="purchase-terms">GIBB Coins können nicht in Geld zurückgetauscht oder ausgezahlt werden.</p>
          </section>}

        </div>

        {offlineMode ? <section className="card card-pad offline-placeholder"><strong>Nur Lesen im Offline-Modus</strong><p>QR-Zahlungen, Anfragen und Kontakte werden wieder aktiviert, sobald eine sichere Serververbindung besteht.</p></section> : <><QrWallet userId={user.id} walletId={wallet?.id} onRecipient={selectQrRecipient} /><PaymentsHub userId={user.id} onRecipient={selectQrRecipient} onChanged={loadData} /></>}
        </div>

        <div className="dashboard-view" hidden={activeView !== "games"} aria-label="Spiele">
        <div className="view-heading"><span>GAME CENTER</span><h1>Spiele</h1><p>Ein Wallet, echte Synchronisierung und serverseitig verbuchte Runden.</p></div>
        {offlineMode ? <section className="card card-pad offline-placeholder"><strong>Spiele sind offline pausiert</strong><p>Damit jeder Einsatz korrekt verbucht wird, startet das Game Center nur mit Serververbindung.</p></section> : <><PlayerSafetyPanel /><GameCenter walletBalance={wallet?.balance ?? 0} onChanged={loadData} /></>}
        </div>

        <div className="dashboard-view" hidden={activeView !== "community"} aria-label="Community">
        <div className="view-heading"><span>GEMEINSAM & SICHER</span><h1>Community</h1><p>Gruppen-Wallets verwalten und verdächtige Vorgänge melden.</p></div>
        {offlineMode ? <section className="card card-pad offline-placeholder"><strong>Community-Aktionen sind offline pausiert</strong><p>Belohnungen, Shop, Gruppen und Meldungen benötigen eine bestätigte Serververbindung.</p></section> : <><RewardsHub userId={user.id} walletBalance={wallet?.balance ?? 0} onChanged={loadData} /><GroupWallets onChanged={loadData} /><AbuseReports transactions={transactions} isAdmin={profile?.role === "admin" || profile?.role === "super_admin"} /></>}
        </div>

        <div className="dashboard-view" hidden={activeView !== "chain"} aria-label="Blockchain">
        <div className="view-heading"><span>PROOF OF WORK</span><h1>Blockchain</h1><p>{profile?.role === "super_admin" ? "Blöcke, Merkle-Roots und CPU-Mining – nachprüfbar für alle." : "Mine GIBB direkt im Browser – dein Rechner löst echte Blöcke."}</p></div>
        {activeView === "chain" && <BlockchainOverview userId={user.id} />}
        {/* Immer eingehängt: der Miner läuft weiter, auch wenn man den Tab wechselt – erst beim Schliessen der Website stoppt er. */}
        <BrowserMinerCard userId={user.id} name={profile?.username || profile?.display_name || "Konto"} balance={wallet?.balance ?? 0} />
        {profile?.role === "super_admin" && activeView === "chain" && <LocalMinerCard userId={user.id} name={profile?.username || profile?.display_name || "Konto"} balance={wallet?.balance ?? 0} isAdmin={true} />}
        </div>

        <div className="dashboard-view" hidden={activeView !== "activity"} aria-label="Aktivität">
        <div className="view-heading"><span>DEIN VERLAUF</span><h1>Aktivität</h1><p>Transaktionen und Benachrichtigungen starten übersichtlich minimiert.</p></div>
        <section className={`card card-pad transactions ${transactionsCollapsed ? "collapsed" : ""}`} id="transactions">
          <div className="section-heading transaction-heading"><div><span className="section-number">04</span><h2>Transaktionen</h2></div><div className="transaction-heading-actions"><span>{filteredTransactions.length} Ergebnisse</span><button className="transaction-collapse" type="button" aria-expanded={!transactionsCollapsed} aria-controls="transaction-content" onClick={() => setTransactionsCollapsed((collapsed) => !collapsed)}><span>{transactionsCollapsed ? "Öffnen" : "Minimieren"}</span><b aria-hidden="true">{transactionsCollapsed ? "+" : "−"}</b></button></div></div>
          <div id="transaction-content" hidden={transactionsCollapsed}>
            <div className="transaction-tools"><div className="filter-tabs" role="group" aria-label="Transaktionen filtern">{(["all", "received", "sent"] as const).map((filter) => <button type="button" key={filter} className={transactionFilter === filter ? "active" : ""} onClick={() => { setTransactionFilter(filter); setShowAllTransactions(false); }}>{filter === "all" ? "Alle" : filter === "received" ? "Eingänge" : "Ausgänge"}</button>)}</div><input className="input transaction-search" aria-label="Transaktionen durchsuchen" value={transactionQuery} onChange={(event) => { setTransactionQuery(event.target.value); setShowAllTransactions(false); }} placeholder="Name, Notiz oder Hash …" /><button className="secondary compact" type="button" disabled={!filteredTransactions.length} onClick={exportTransactions}>CSV exportieren</button></div>
            <div className="transaction-range"><label>Von<input className="input" type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} /></label><label>Bis<input className="input" type="date" value={dateTo} onChange={(event) => setDateTo(event.target.value)} /></label><label>Mindestens<input className="input" type="number" min={0} value={minAmount} onChange={(event) => setMinAmount(event.target.value)} placeholder="0 GIBB" /></label><label>Höchstens<input className="input" type="number" min={0} value={maxAmount} onChange={(event) => setMaxAmount(event.target.value)} placeholder="beliebig" /></label><button className="secondary compact" type="button" onClick={() => { setDateFrom(""); setDateTo(""); setMinAmount(""); setMaxAmount(""); setTransactionQuery(""); }}>Filter löschen</button></div>
            <div className="transaction-list">{visibleTransactions.length === 0 && <div className="empty">Keine passenden Transaktionen gefunden.</div>}{visibleTransactions.map((tx) => { const sent = tx.sender_user_id === user.id; const date = new Date(tx.created_at); return <article className={`tx ${sent ? "sent" : "received"}`} key={tx.id}><div className="tx-icon" aria-hidden="true">{sent ? "↗" : "↙"}</div><div className="tx-main"><div><strong>{sent ? tx.receiver_label : tx.sender_label}</strong><span className="tx-type">{transactionTypeLabel(tx.type)}</span></div><span title={tx.hash}>#{tx.hash.slice(0, 12)}</span>{tx.note && <small>{tx.note}</small>}</div><div className="tx-value"><strong>{sent ? "−" : "+"}{tx.amount} GIBB</strong><span>{date.toLocaleDateString("de-CH", { day: "2-digit", month: "short" })} · {date.toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit" })}</span><button className="receipt-button" type="button" onClick={() => downloadReceipt(tx)}>Beleg ↓</button></div></article>; })}</div>
            {filteredTransactions.length > 8 && <button className="show-more" type="button" onClick={() => setShowAllTransactions((current) => !current)}>{showAllTransactions ? "Weniger anzeigen" : `Alle ${filteredTransactions.length} anzeigen`}</button>}
            {showAllTransactions && transactionHasMore && <button className="show-more" type="button" disabled={transactionLoadingMore} onClick={() => void loadMoreTransactions()}>{transactionLoadingMore ? "Weitere werden geladen …" : "Weitere Transaktionen laden"}</button>}
          </div>
        </section>

        {!offlineMode && <NotificationCenter userId={user.id} onNotification={loadData} onUnreadChange={setUnreadNotifications} />}
        </div>

        <div className="dashboard-view" hidden={activeView !== "account"} aria-label="Konto">
        <div className="view-heading"><span>DEIN KONTO</span><h1>Profil & App</h1><p>Kontostatus prüfen und GIBB Coin auf deinem Gerät installieren.</p></div>
        <section className="card card-pad profile-card" id="profile" style={{ borderColor: profile?.profile_color }}><div className="profile-identity">{avatar ? <Image className="profile-avatar" src={avatar} alt="Profilbild" width={64} height={64} unoptimized referrerPolicy="no-referrer" style={{ borderColor: profile?.profile_color }} /> : <span className="profile-avatar" style={{ background: profile?.profile_color }}>{displayName[0]}</span>}<div><span>Angemeldet als</span><h2>{displayName}</h2><p>{profile?.bio || "Dein persönliches GIBB Coin Profil"}</p></div></div><div className="profile-facts"><div><span>Rolle / Titel</span><strong>{roleLabel}</strong></div>{visualRoleLabel && <div><span>Fun-Rang</span><strong className="visual-role-text">{visualRoleLabel}</strong></div>}<div><span>Kontostatus</span><strong className={accountLocked ? "danger-text" : "success-text"}>{accountLocked ? wallet?.locked_until ? `Gesperrt bis ${new Date(wallet.locked_until).toLocaleString("de-CH")}` : "Gesperrt" : "Aktiv & geschützt"}</strong></div><div><span>Anmeldung</span><strong>{user.app_metadata?.provider === "google" ? "Google" : "E-Mail"}</strong></div></div></section>
        {profile && !offlineMode && <ProfileEditor userId={user.id} profile={profile} onChanged={loadData} />}
        {!offlineMode && <SupportPrivacyCenter />}
        <PwaInstallCard />
        </div>

        {(profile?.role === "admin" || profile?.role === "super_admin") && <div className="dashboard-view" hidden={activeView !== "admin"} aria-label="Admin"><div className="view-heading"><span>GESCHÜTZTER BEREICH</span><h1>Admin</h1><p>Sicherheit, Rollen und Wallet-Verwaltung an einem Ort.</p></div>{offlineMode ? <section className="card card-pad offline-placeholder"><strong>Adminpanel offline gesperrt</strong><p>Administrative Aktionen benötigen immer eine aktuelle MFA- und Serverprüfung.</p></section> : <><AdminSecurityCenter />{activeView === "admin" && <AdminPanel currentRole={profile.role} currentUserId={user.id} onChanged={loadData} onExit={() => openView("home")} />}</>}</div>}
        <p className="disclaimer">GIBB Coin ist ein internes Schulprojekt. Coins können nicht mit echtem Geld gekauft werden, sind kein gesetzliches Zahlungsmittel, nicht auszahlbar und nur in der App nutzbar. Die dargestellte Hash-Kette ist serverseitig geprüft und keine öffentliche Blockchain.</p>
        <a className="creator-credit" href="https://robyn-projektportal.pxfyvkgcs6.chatgpt.site" target="_blank" rel="noopener noreferrer" aria-label="Alle Projekte von Robyn Rüfenacht öffnen">Diese Seite wurde von <strong>Robyn Rüfenacht</strong> erstellt.</a>
      </main>
      <UserProfileModal />
    </div>
  );
}
