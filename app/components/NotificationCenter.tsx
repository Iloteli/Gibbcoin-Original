"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabase, getUsableSupabaseSession, isSupabaseAuthError } from "../lib/supabase";

type NotificationItem = {
  id: string;
  user_id: string;
  kind: string;
  title: string;
  message: string;
  is_read: boolean;
  created_at: string;
};

type NotificationPreferences = {
  notifications_enabled: boolean;
  coins_received_enabled: boolean;
  browser_notifications_enabled: boolean;
};

type Props = {
  userId: string;
  onNotification: () => Promise<void>;
  onUnreadChange?: (count: number) => void;
};

const defaultPreferences: NotificationPreferences = {
  notifications_enabled: true,
  coins_received_enabled: true,
  browser_notifications_enabled: false,
};

function iconFor(kind: string) {
  if (kind === "transfer_received") return "↓";
  if (kind === "transfer_sent") return "↑";
  if (kind === "account_status" || kind === "wallet_status") return "!";
  if (kind === "admin_adjustment" || kind === "daily_reward") return "+";
  if (kind === "payment_request") return "?";
  if (kind === "request_declined") return "×";
  return "•";
}

export function NotificationCenter({ userId, onNotification, onUnreadChange }: Props) {
  const [items, setItems] = useState<NotificationItem[]>([]);
  const [preferences, setPreferences] = useState(defaultPreferences);
  const [toast, setToast] = useState<NotificationItem | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [collapsed, setCollapsed] = useState(true);
  const preferencesRef = useRef(preferences);
  const toastTimerRef = useRef<number | null>(null);

  useEffect(() => {
    preferencesRef.current = preferences;
  }, [preferences]);

  useEffect(() => {
    const maybeSupabase = getSupabase();
    if (!maybeSupabase) return;
    const supabase = maybeSupabase;
    let active = true;

    async function loadNotifications() {
      const fetchNotifications = () => Promise.all([
        supabase.from("notification_preferences").select("notifications_enabled,coins_received_enabled,browser_notifications_enabled").eq("user_id", userId).maybeSingle(),
        supabase.from("notifications").select("id,user_id,kind,title,message,is_read,created_at").eq("user_id", userId).order("created_at", { ascending: false }).limit(30),
      ] as const);
      let results = await fetchNotifications();
      for (let attempt = 0; attempt < 3 && results.some((result) => isSupabaseAuthError(result.error)); attempt += 1) {
        const restoredSession = await getUsableSupabaseSession();
        if (!restoredSession) break;
        await new Promise((resolve) => window.setTimeout(resolve, 150 * (attempt + 1)));
        results = await fetchNotifications();
      }
      if (results.some((result) => isSupabaseAuthError(result.error))) {
        if (active) {
          setError("Die Nachrichten konnten gerade nicht aktualisiert werden. Deine Anmeldung bleibt gespeichert.");
          setLoading(false);
        }
        return;
      }
      const [{ data: preferenceData }, { data: notificationData }] = results;
      if (!active) return;

      if (preferenceData) {
        setPreferences(preferenceData as NotificationPreferences);
      } else {
        const { data: created } = await supabase.from("notification_preferences").insert({ user_id: userId }).select("notifications_enabled,coins_received_enabled,browser_notifications_enabled").single();
        if (created && active) setPreferences(created as NotificationPreferences);
      }
      setItems((notificationData ?? []) as NotificationItem[]);
      setError("");
      setLoading(false);
    }

    void loadNotifications();

    const channel = supabase
      .channel(`user-notifications-${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "notifications", filter: `user_id=eq.${userId}` },
        (payload) => {
          const item = payload.new as NotificationItem;
          setItems((current) => [item, ...current.filter((entry) => entry.id !== item.id)].slice(0, 30));
          setToast(item);
          if (toastTimerRef.current) window.clearTimeout(toastTimerRef.current);
          toastTimerRef.current = window.setTimeout(() => setToast(null), 6500);
          void onNotification();

          if (
            preferencesRef.current.browser_notifications_enabled
            && typeof Notification !== "undefined"
            && Notification.permission === "granted"
            && document.visibilityState !== "visible"
          ) {
            new Notification(item.title, { body: item.message, tag: item.id });
          }
        },
      )
      .subscribe();

    return () => {
      active = false;
      if (toastTimerRef.current) window.clearTimeout(toastTimerRef.current);
      void supabase.removeChannel(channel);
    };
  }, [onNotification, userId]);

  const unreadCount = useMemo(() => items.filter((item) => !item.is_read).length, [items]);

  useEffect(() => {
    onUnreadChange?.(unreadCount);
  }, [onUnreadChange, unreadCount]);

  async function updatePreference(key: keyof NotificationPreferences, value: boolean) {
    setError("");
    if (key === "browser_notifications_enabled" && value) {
      if (typeof Notification === "undefined") {
        setError("Dieser Browser unterstützt keine Browser-Benachrichtigungen.");
        return;
      }
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setError("Browser-Benachrichtigungen wurden nicht erlaubt.");
        return;
      }
    }

    const supabase = getSupabase();
    if (!supabase) return;
    setSaving(true);
    const { error: updateError } = await supabase.from("notification_preferences").update({ [key]: value }).eq("user_id", userId);
    setSaving(false);
    if (updateError) {
      setError("Die Benachrichtigungseinstellung konnte nicht gespeichert werden.");
      return;
    }
    setPreferences((current) => ({ ...current, [key]: value }));
  }

  async function markRead(id: string) {
    const supabase = getSupabase();
    if (!supabase) return;
    const { error: updateError } = await supabase.from("notifications").update({ is_read: true }).eq("id", id).eq("user_id", userId);
    if (updateError) { setError("Die Nachricht konnte nicht als gelesen markiert werden."); return; }
    setItems((current) => current.map((item) => item.id === id ? { ...item, is_read: true } : item));
  }

  async function markAllRead() {
    const supabase = getSupabase();
    if (!supabase) return;
    const { error: updateError } = await supabase.from("notifications").update({ is_read: true }).eq("user_id", userId).eq("is_read", false);
    if (updateError) { setError("Die Nachrichten konnten nicht als gelesen markiert werden."); return; }
    setItems((current) => current.map((item) => ({ ...item, is_read: true })));
  }

  return <>
    <section className={`card card-pad notification-center ${collapsed ? "collapsed" : ""}`} id="notifications">
      <div className="card-head notification-head">
        <div><h2>Benachrichtigungen</h2><p>Bestimme selbst, welche Nachrichten du erhältst.</p></div>
        <div className="notification-head-actions"><span>{unreadCount} ungelesen</span><button className="notification-collapse" type="button" aria-expanded={!collapsed} aria-controls="notification-content" onClick={() => setCollapsed((current) => !current)}><span>{collapsed ? "Öffnen" : "Minimieren"}</span><b aria-hidden="true">{collapsed ? "+" : "−"}</b></button></div>
      </div>

      <div id="notification-content" hidden={collapsed}>
        <div className="notification-settings" aria-label="Benachrichtigungseinstellungen">
          <div className="notification-setting">
            <span id="notifications-enabled-label"><strong>Benachrichtigungen</strong><small>Alle In-App-Nachrichten ein- oder ausschalten</small></span>
            <input aria-labelledby="notifications-enabled-label" id="notifications-enabled" type="checkbox" role="switch" checked={preferences.notifications_enabled} disabled={saving} onChange={(event) => void updatePreference("notifications_enabled", event.target.checked)} />
          </div>
          <div className="notification-setting">
            <span id="coins-received-enabled-label"><strong>Coins erhalten</strong><small>Nachricht, wenn dir jemand GIBB Coins sendet</small></span>
            <input aria-labelledby="coins-received-enabled-label" id="coins-received-enabled" type="checkbox" role="switch" checked={preferences.coins_received_enabled} disabled={saving || !preferences.notifications_enabled} onChange={(event) => void updatePreference("coins_received_enabled", event.target.checked)} />
          </div>
          <div className="notification-setting">
            <span id="browser-notifications-enabled-label"><strong>Browser-Meldungen</strong><small>Auch benachrichtigen, wenn der Tab im Hintergrund ist</small></span>
            <input aria-labelledby="browser-notifications-enabled-label" id="browser-notifications-enabled" type="checkbox" role="switch" checked={preferences.browser_notifications_enabled} disabled={saving || !preferences.notifications_enabled} onChange={(event) => void updatePreference("browser_notifications_enabled", event.target.checked)} />
          </div>
        </div>

        <div className="notification-list-head">
          <strong>Letzte Nachrichten</strong>
          {unreadCount > 0 && <button className="secondary compact" type="button" onClick={() => void markAllRead()}>Alle gelesen</button>}
        </div>
        <div className="notification-list">
          {loading && <div className="empty">Nachrichten werden geladen …</div>}
          {!loading && items.length === 0 && <div className="empty">Noch keine Benachrichtigungen vorhanden.</div>}
          {items.map((item) => <button className={`notification-item ${item.is_read ? "read" : "unread"}`} type="button" key={item.id} onClick={() => void markRead(item.id)}>
            <span className="notification-icon" aria-hidden="true">{iconFor(item.kind)}</span>
            <span className="notification-copy"><strong>{item.title}</strong><span>{item.message}</span></span>
            <time dateTime={item.created_at}>{new Date(item.created_at).toLocaleDateString("de-CH", { day: "2-digit", month: "2-digit" })}</time>
          </button>)}
        </div>
        {error && <p className="message error" role="alert">{error}</p>}
      </div>
    </section>

    {toast && <button className="notification-toast" type="button" onClick={() => { void markRead(toast.id); setToast(null); }}>
      <span className="notification-icon" aria-hidden="true">{iconFor(toast.kind)}</span>
      <span><strong>{toast.title}</strong><small>{toast.message}</small></span>
    </button>}
  </>;
}
