"use client";

import { useEffect } from "react";
import { getSupabase } from "../lib/supabase";

// Wartungsmodus (sudo gibb-wartung an): Wer die Website offen hat, wird abgemeldet
// und sieht nach dem Neuladen die Wartungsseite. Der Status kommt vom Gateway (/__status).
const CHECK_MS = 5_000;

export function MaintenanceWatch() {
  useEffect(() => {
    let stopped = false;
    const check = async () => {
      try {
        const res = await fetch(`/__status?t=${Date.now()}`, { cache: "no-store" });
        if (!res.ok) return;
        const status = (await res.json()) as { maintenance?: boolean };
        if (!status.maintenance || stopped) return;
        stopped = true;
        const supabase = getSupabase();
        if (supabase) await supabase.auth.signOut({ scope: "local" }).catch(() => undefined);
        window.location.replace(window.location.href);
      } catch {
        // Kein Gateway (z. B. lokale Entwicklung): nichts tun.
      }
    };
    const first = window.setTimeout(() => void check(), 0);
    const timer = window.setInterval(() => void check(), CHECK_MS);
    const onVisible = () => { if (document.visibilityState === "visible") void check(); };
    const onFocus = () => void check();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onFocus);
    window.addEventListener("online", onFocus);
    return () => {
      stopped = true;
      window.clearTimeout(first);
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onFocus);
      window.removeEventListener("online", onFocus);
    };
  }, []);
  return null;
}
