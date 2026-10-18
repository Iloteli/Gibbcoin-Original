"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

// "Made by"-Fusszeile; der Text wird auf der Chain-Seite unter Einstellungen bearbeitet.
export function SiteFooter() {
  const [text, setText] = useState("Made by Ilja");
  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    let alive = true;
    void supabase.rpc("get_site_features").then(({ data }) => {
      const value = (data as { footer_text?: string } | null)?.footer_text;
      if (alive && typeof value === "string") setText(value);
    });
    return () => { alive = false; };
  }, []);
  if (!text.trim()) return null;
  return (
    <footer className="site-footer">
      <span className="site-footer-line" aria-hidden="true" />
      <p>{text}</p>
    </footer>
  );
}
