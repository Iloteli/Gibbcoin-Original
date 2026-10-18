"use client";

import { useEffect } from "react";
import { getSupabase } from "../lib/supabase";

type Design = { accent?: string; mode?: string; motion?: string };
const CACHE = "gibb-site-design";

function apply(d: Design) {
  const root = document.documentElement;
  root.dataset.accent = ["emerald", "violet", "gold"].includes(d.accent ?? "") ? d.accent : "neon";
  root.dataset.motion = ["reduced", "off"].includes(d.motion ?? "") ? d.motion : "full";
  // Standard-Modus nur, wenn die Person selbst nichts gewählt hat (☀️/🌙 hat Vorrang)
  let own: string | null = null;
  try { own = window.localStorage.getItem("gibb-theme"); } catch { /* privat */ }
  if (!own) { if (d.mode === "light") root.dataset.theme = "light"; else delete root.dataset.theme; }
}

// Übernimmt das Design, das der Owner auf der Chain-Seite für die Hauptseite eingestellt hat.
export function SiteDesign() {
  useEffect(() => {
    try { const cached = window.localStorage.getItem(CACHE); if (cached) apply(JSON.parse(cached) as Design); } catch { /* ohne Zwischenspeicher */ }
    const supabase = getSupabase();
    if (!supabase) return;
    let alive = true;
    const load = () => void supabase.rpc("get_site_features").then(({ data }) => {
      const design = (data as { design?: Design } | null)?.design;
      if (!alive || !design) return;
      apply(design);
      try { window.localStorage.setItem(CACHE, JSON.stringify(design)); } catch { /* privat */ }
    });
    load();
    const timer = window.setInterval(load, 120_000);
    return () => { alive = false; window.clearInterval(timer); };
  }, []);
  return null;
}
