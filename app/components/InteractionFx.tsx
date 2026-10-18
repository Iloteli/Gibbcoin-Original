"use client";

import { useEffect } from "react";

const CARD_SELECTOR = ".card, .stat-card, .home-shortcuts button";
const RIPPLE_SELECTOR = ".primary, .secondary, a.primary-link, a.secondary-link, .dashboard-tabs button, .home-shortcuts button, .price-chart-ranges button";

// Lichtschein folgt der Maus, Karten leuchten unter der Maus auf und neigen sich leicht,
// Knöpfe senden beim Klicken eine Welle aus. Aus bei "Bewegung reduzieren"; am Handy nur die Welle.
export function InteractionFx() {
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const root = document.documentElement;
    const fine = window.matchMedia("(pointer: fine)").matches;
    let frame = 0;
    let last: PointerEvent | null = null;
    let tilted: HTMLElement | null = null;

    const resetTilt = () => {
      if (!tilted) return;
      tilted.style.removeProperty("--rx");
      tilted.style.removeProperty("--ry");
      tilted.classList.remove("fx-tilt");
      tilted = null;
    };
    const paint = () => {
      frame = 0;
      const e = last;
      if (!e) return;
      root.style.setProperty("--mx", `${e.clientX}px`);
      root.style.setProperty("--my", `${e.clientY}px`);
      const card = (e.target as HTMLElement | null)?.closest<HTMLElement>(CARD_SELECTOR) ?? null;
      if (card !== tilted) resetTilt();
      if (!card) return;
      const r = card.getBoundingClientRect();
      const px = (e.clientX - r.left) / r.width;
      const py = (e.clientY - r.top) / r.height;
      card.style.setProperty("--cx", `${(px * 100).toFixed(1)}%`);
      card.style.setProperty("--cy", `${(py * 100).toFixed(1)}%`);
      // Grosse Karten nur leicht neigen
      const strength = r.width > 700 ? 1.2 : 3.5;
      card.style.setProperty("--rx", `${((0.5 - py) * strength).toFixed(2)}deg`);
      card.style.setProperty("--ry", `${((px - 0.5) * strength).toFixed(2)}deg`);
      card.classList.add("fx-tilt");
      tilted = card;
    };
    const onMove = (e: PointerEvent) => { last = e; if (!frame) frame = window.requestAnimationFrame(paint); };
    const onLeave = () => resetTilt();
    const onDown = (e: PointerEvent) => {
      const target = (e.target as HTMLElement | null)?.closest<HTMLElement>(RIPPLE_SELECTOR);
      if (!target || target.hasAttribute("disabled")) return;
      const rect = target.getBoundingClientRect();
      const size = Math.max(rect.width, rect.height) * 2.2;
      const ripple = document.createElement("span");
      ripple.className = "fx-ripple";
      ripple.style.width = ripple.style.height = `${size}px`;
      ripple.style.left = `${e.clientX - rect.left - size / 2}px`;
      ripple.style.top = `${e.clientY - rect.top - size / 2}px`;
      if (getComputedStyle(target).position === "static") target.classList.add("fx-host");
      target.appendChild(ripple);
      window.setTimeout(() => ripple.remove(), 700);
    };
    // Einblenden beim Scrollen: Karten unterhalb des Bildschirms erscheinen weich, sobald sie sichtbar werden
    const seen = new WeakSet<Element>();
    const io = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add("is-visible"); io?.unobserve(entry.target); }
    }, { rootMargin: "0px 0px -6% 0px" }) : null;
    const scan = () => {
      if (!io) return;
      document.querySelectorAll(".dashboard-view .card, .dashboard-view .stat-card, .dashboard-view .home-launchpad").forEach((el) => {
        if (seen.has(el)) return;
        seen.add(el);
        const r = el.getBoundingClientRect();
        if (r.top < window.innerHeight && r.bottom > 0) return; // schon sichtbar: nicht verstecken
        el.classList.add("fx-reveal");
        io.observe(el);
      });
    };
    scan();
    let scanQueued = 0;
    const mo = new MutationObserver(() => { if (!scanQueued) scanQueued = window.setTimeout(() => { scanQueued = 0; scan(); }, 250); });
    mo.observe(document.body, { childList: true, subtree: true });
    if (fine) {
      root.classList.add("fx-glow");
      window.addEventListener("pointermove", onMove, { passive: true });
      document.addEventListener("pointerleave", onLeave);
    }
    window.addEventListener("pointerdown", onDown, { passive: true });
    return () => {
      mo.disconnect();
      io?.disconnect();
      if (scanQueued) window.clearTimeout(scanQueued);
      root.classList.remove("fx-glow");
      resetTilt();
      window.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerleave", onLeave);
      window.removeEventListener("pointerdown", onDown);
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, []);
  return null;
}
