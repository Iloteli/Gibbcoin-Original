"use client";

import { useState } from "react";

type Theme = "dark" | "light";
const KEY = "gibb-theme";

// Liest das gespeicherte Design; ohne Wahl gilt das dunkle Design.
export function readTheme(): Theme {
  try { return window.localStorage.getItem(KEY) === "light" ? "light" : "dark"; } catch { return "dark"; }
}

export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  root.classList.add("theme-switching");
  if (theme === "light") root.dataset.theme = "light"; else delete root.dataset.theme;
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", theme === "light" ? "#f3f6f4" : "#06090a");
  window.setTimeout(() => root.classList.remove("theme-switching"), 400);
}

// Knopf oben rechts: wechselt zwischen hellem und dunklem Design und merkt sich die Wahl.
export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>(() => (typeof window === "undefined" ? "dark" : readTheme()));
  const toggle = () => {
    const next: Theme = theme === "light" ? "dark" : "light";
    setTheme(next);
    applyTheme(next);
    try { window.localStorage.setItem(KEY, next); } catch { /* privates Fenster */ }
  };
  return (
    <button type="button" className="theme-toggle" onClick={toggle} aria-label={theme === "light" ? "Dunkles Design einschalten" : "Helles Design einschalten"} title={theme === "light" ? "Dunkles Design" : "Helles Design"}>
      <span aria-hidden="true" suppressHydrationWarning>{theme === "light" ? "🌙" : "☀️"}</span>
    </button>
  );
}
