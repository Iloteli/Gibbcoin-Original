"use client";

import { getSupabase } from "./supabase";

const VISITOR_STORAGE_KEY = "gibb-coin-visitor-id";

export type SiteKey = "chatgpt-site" | "workers-dev" | "other";

export const SITE_LABELS: Record<SiteKey, string> = {
  "chatgpt-site": "gibb-coin-schulwallet.pxfyvkgcs6.chatgpt.site",
  "workers-dev": "gibb-coin.kbb8vy5sjy.workers.dev",
  other: "Andere Adresse",
};

export function detectSite(host: string): SiteKey {
  const normalized = host.toLocaleLowerCase("en-US");
  if (normalized.includes("chatgpt.site")) return "chatgpt-site";
  if (normalized.includes("workers.dev")) return "workers-dev";
  return "other";
}

function readVisitorId(): string | null {
  try {
    const existing = window.localStorage.getItem(VISITOR_STORAGE_KEY);
    if (existing && existing.length >= 8) return existing;
    const created = globalThis.crypto?.randomUUID?.()
      ?? `v-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
    window.localStorage.setItem(VISITOR_STORAGE_KEY, created);
    return created;
  } catch {
    // Ohne Speicher (z. B. blockierte Cookies) wird der Besuch nicht gezaehlt,
    // damit niemand doppelt als neuer Besucher erscheint.
    return null;
  }
}

/** Meldet genau einen Seitenaufruf der aktuellen Adresse an die Datenbank. */
export async function recordVisit(): Promise<void> {
  if (typeof window === "undefined") return;
  const visitorId = readVisitorId();
  if (!visitorId) return;
  const supabase = getSupabase();
  if (!supabase) return;

  try {
    await supabase.rpc("record_site_visit", {
      p_visitor_id: visitorId,
      p_site: detectSite(window.location.host),
      p_path: window.location.pathname || "/",
    });
  } catch {
    // Die Zaehlung darf die App nie blockieren.
  }
}
