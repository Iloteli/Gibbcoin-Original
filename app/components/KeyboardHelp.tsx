"use client";

import { useEffect, useState } from "react";

type DashboardView = "home" | "send" | "games" | "community" | "activity" | "chain" | "market" | "shop" | "account" | "admin";

type Props = {
  activeView: DashboardView;
  onNavigate: (view: Exclude<DashboardView, "admin">) => void;
};

const shortcuts: Array<{ key: string; label: string; view: Exclude<DashboardView, "admin"> }> = [
  { key: "1", label: "Home", view: "home" },
  { key: "2", label: "Senden", view: "send" },
  { key: "3", label: "Spiele", view: "games" },
  { key: "4", label: "Community", view: "community" },
  { key: "5", label: "Aktivitaet", view: "activity" },
  { key: "6", label: "Blockchain", view: "chain" },
  { key: "7", label: "Kaufen", view: "market" },
  { key: "8", label: "Konto", view: "account" },
];

export function KeyboardHelp({ activeView, onNavigate }: Props) {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      const target = event.target;
      if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement || (target instanceof HTMLElement && target.isContentEditable)) return;
      if (event.key === "?") {
        event.preventDefault();
        setOpen((current) => !current);
        return;
      }
      if (event.key === "Escape") {
        setOpen(false);
        return;
      }
      const shortcut = shortcuts.find((item) => item.key === event.key);
      if (shortcut) {
        event.preventDefault();
        onNavigate(shortcut.view);
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onNavigate]);

  return (
    <section className="keyboard-help" aria-label="Tastaturhilfe">
      <button className="secondary compact" type="button" aria-expanded={open} aria-controls="keyboard-help-content" onClick={() => setOpen((current) => !current)}>
        Tastaturhilfe <kbd>?</kbd>
      </button>
      {open && (
        <div id="keyboard-help-content" className="keyboard-help-content" role="dialog" aria-label="Tastaturkürzel">
          <strong>Schnell navigieren</strong>
          <p>Die Kürzel funktionieren ausserhalb von Eingabefeldern.</p>
          <div className="keyboard-shortcuts">
            {shortcuts.map((shortcut) => <button type="button" key={shortcut.key} className={activeView === shortcut.view ? "active" : ""} onClick={() => { onNavigate(shortcut.view); setOpen(false); }}><kbd>{shortcut.key}</kbd><span>{shortcut.label}</span></button>)}
          </div>
          <p><kbd>?</kbd> Hilfe öffnen · <kbd>Esc</kbd> schliessen</p>
        </div>
      )}
    </section>
  );
}
