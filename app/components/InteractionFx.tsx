"use client";

import { useEffect } from "react";

// Lichtschein folgt der Maus und Klick-Welle auf Knöpfen. Aus bei "Bewegung reduzieren" und auf Touch-Geräten (nur Welle).
export function InteractionFx() {
  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce) return;
    const root = document.documentElement;
    const fine = window.matchMedia("(pointer: fine)").matches;
    let frame = 0;
    const onMove = (e: PointerEvent) => {
      if (frame) return;
      frame = window.requestAnimationFrame(() => {
        frame = 0;
        root.style.setProperty("--mx", `${e.clientX}px`);
        root.style.setProperty("--my", `${e.clientY}px`);
      });
    };
    const onDown = (e: PointerEvent) => {
      const target = (e.target as HTMLElement | null)?.closest<HTMLElement>(".primary, .secondary, a.primary-link, a.secondary-link, .dashboard-tabs button, .home-shortcuts button, .price-chart-ranges button");
      if (!target || target.hasAttribute("disabled")) return;
      const rect = target.getBoundingClientRect();
      const size = Math.max(rect.width, rect.height) * 2;
      const ripple = document.createElement("span");
      ripple.className = "fx-ripple";
      ripple.style.width = ripple.style.height = `${size}px`;
      ripple.style.left = `${e.clientX - rect.left - size / 2}px`;
      ripple.style.top = `${e.clientY - rect.top - size / 2}px`;
      if (getComputedStyle(target).position === "static") target.classList.add("fx-host");
      target.appendChild(ripple);
      window.setTimeout(() => ripple.remove(), 650);
    };
    if (fine) { root.classList.add("fx-glow"); window.addEventListener("pointermove", onMove, { passive: true }); }
    window.addEventListener("pointerdown", onDown, { passive: true });
    return () => {
      root.classList.remove("fx-glow");
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerdown", onDown);
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, []);
  return null;
}
