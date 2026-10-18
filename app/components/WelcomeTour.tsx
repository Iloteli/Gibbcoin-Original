"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

// Kurzer Rundgang beim ersten Login: hebt nacheinander die wichtigsten Stellen hervor.
// Erneut starten: window.dispatchEvent(new Event("gibb:start-tour"))
const DONE_KEY = "gibb-tour-done";

type Step = { selector: string; title: string; text: string };
const STEPS: Step[] = [
  { selector: "#wallet", title: "Dein Guthaben", text: "Hier siehst du, wie viele GIBB du hast. Alles – Senden, Spiele, Markt – nutzt genau dieses eine Guthaben." },
  { selector: "#dashboard-view-top", title: "Die Bereiche", text: "Über diese Leiste wechselst du zwischen Home, Senden, Spielen, Community, Markt und mehr." },
  { selector: ".home-price-card", title: "Der GIBB-Kurs", text: "So viel ist ein GIBB gerade wert. Fahre über den Chart, um frühere Kurse zu sehen." },
  { selector: ".notification-bell", title: "Mitteilungen", text: "Hier erfährst du, wenn du GIBB bekommst oder jemand etwas von dir anfordert." },
  { selector: ".theme-toggle", title: "Hell oder dunkel", text: "Mit diesem Knopf wechselst du zwischen hellem und dunklem Design." },
  { selector: ".profile-button", title: "Dein Konto", text: "Im Menü findest du dein Profil, deinen QR-Code und die Abmeldung. Viel Spass mit GIBB Coin!" },
];

type Box = { top: number; left: number; width: number; height: number };

const visibleTarget = (selector: string) => {
  const el = document.querySelector<HTMLElement>(selector);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0 ? el : null;
};

export function WelcomeTour() {
  const [steps, setSteps] = useState<Step[]>([]);
  const [index, setIndex] = useState(0);
  const [box, setBox] = useState<Box | null>(null);
  const open = steps.length > 0;
  const nextRef = useRef<HTMLButtonElement | null>(null);
  // Tastatur: Fokus auf "Weiter", sobald ein Schritt erscheint
  useEffect(() => { if (open) nextRef.current?.focus({ preventScroll: true }); }, [open, index]);

  const start = useCallback(() => {
    const available = STEPS.filter((s) => visibleTarget(s.selector));
    if (!available.length) return;
    setIndex(0);
    setSteps(available);
  }, []);

  const finish = useCallback(() => {
    setSteps([]);
    setBox(null);
    try { window.localStorage.setItem(DONE_KEY, "1"); } catch { /* privates Fenster */ }
  }, []);

  // Beim ersten Besuch automatisch, sonst nur auf Wunsch
  useEffect(() => {
    let done = false;
    try { done = window.localStorage.getItem(DONE_KEY) === "1"; } catch { done = true; }
    const timer = done ? undefined : window.setTimeout(start, 1400);
    const onStart = () => start();
    window.addEventListener("gibb:start-tour", onStart);
    return () => { if (timer) window.clearTimeout(timer); window.removeEventListener("gibb:start-tour", onStart); };
  }, [start]);

  // Ziel hervorheben und mitführen, wenn gescrollt oder die Grösse geändert wird
  useLayoutEffect(() => {
    if (!open) return;
    const step = steps[index];
    const el = visibleTarget(step.selector);
    if (!el) {
      // Ziel gerade nicht sichtbar: Schritt überspringen
      const skip = window.setTimeout(() => { if (index < steps.length - 1) setIndex(index + 1); else finish(); }, 0);
      return () => window.clearTimeout(skip);
    }
    el.scrollIntoView({ behavior: "smooth", block: "center" });
    const measure = () => { const r = el.getBoundingClientRect(); setBox({ top: r.top, left: r.left, width: r.width, height: r.height }); };
    const first = window.requestAnimationFrame(measure);
    const timer = window.setInterval(measure, 120);
    window.addEventListener("resize", measure);
    window.addEventListener("scroll", measure, true);
    return () => { window.cancelAnimationFrame(first); window.clearInterval(timer); window.removeEventListener("resize", measure); window.removeEventListener("scroll", measure, true); };
  }, [open, index, steps, finish]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") finish();
      if (e.key === "ArrowRight") setIndex((i) => Math.min(i + 1, steps.length - 1));
      if (e.key === "ArrowLeft") setIndex((i) => Math.max(i - 1, 0));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, steps.length, finish]);

  if (!open || !box) return null;
  const step = steps[index];
  const last = index === steps.length - 1;
  const pad = 8;
  const vw = typeof window !== "undefined" ? window.innerWidth : 1024;
  const vh = typeof window !== "undefined" ? window.innerHeight : 768;
  const cardWidth = Math.min(340, vw - 32);
  const below = box.top + box.height + pad + 190 < vh;
  const above = box.top - pad - 12 - 190 >= 16;
  // Kein Platz über oder unter dem Ziel (z. B. hohe Karte auf dem Handy): Erklärung unten am Rand
  const cardPos = below ? { top: box.top + box.height + pad + 12 } : above ? { top: box.top - pad - 12 - 190 } : { bottom: 16 };
  const cardLeft = Math.min(Math.max(16, box.left + box.width / 2 - cardWidth / 2), vw - cardWidth - 16);

  return (
    <div className="tour-layer" role="dialog" aria-modal="true" aria-labelledby="tour-title">
      <div className="tour-spot" style={{ top: box.top - pad, left: box.left - pad, width: box.width + pad * 2, height: box.height + pad * 2 }} />
      <div className="tour-card" key={index} style={{ ...cardPos, left: cardLeft, width: cardWidth }}>
        <span className="tour-step">Schritt {index + 1} von {steps.length}</span>
        <h2 id="tour-title">{step.title}</h2>
        <p>{step.text}</p>
        <div className="tour-dots" aria-hidden="true">{steps.map((s, i) => <i key={s.selector} className={i === index ? "active" : ""} />)}</div>
        <div className="tour-actions">
          <button type="button" className="tour-skip" onClick={finish}>Überspringen</button>
          <span>
            {index > 0 && <button type="button" className="secondary compact" onClick={() => setIndex(index - 1)}>Zurück</button>}
            <button type="button" className="primary compact" ref={nextRef} onClick={() => (last ? finish() : setIndex(index + 1))}>{last ? "Los geht's" : "Weiter"}</button>
          </span>
        </div>
      </div>
    </div>
  );
}
