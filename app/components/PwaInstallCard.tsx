"use client";

import { useEffect, useState } from "react";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

function isStandalone() {
  return window.matchMedia("(display-mode: standalone)").matches
    || ("standalone" in window.navigator && Boolean((window.navigator as Navigator & { standalone?: boolean }).standalone));
}

export function PwaInstallCard() {
  const [prompt, setPrompt] = useState<InstallPromptEvent | null>(null);
  const [installed, setInstalled] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    const installedCheck = window.setTimeout(() => setInstalled(isStandalone()), 0);
    if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
    const handlePrompt = (event: Event) => { event.preventDefault(); setPrompt(event as InstallPromptEvent); };
    const handleInstalled = () => { setInstalled(true); setPrompt(null); setMessage("GIBB Coin wurde installiert."); };
    window.addEventListener("beforeinstallprompt", handlePrompt);
    window.addEventListener("appinstalled", handleInstalled);
    return () => { window.clearTimeout(installedCheck); window.removeEventListener("beforeinstallprompt", handlePrompt); window.removeEventListener("appinstalled", handleInstalled); };
  }, []);

  async function install() {
    if (!prompt) { setMessage("Öffne das Browser-Menü und wähle «Zum Home-Bildschirm» oder «App installieren». "); return; }
    await prompt.prompt();
    const choice = await prompt.userChoice;
    if (choice.outcome === "accepted") setInstalled(true);
    setPrompt(null);
  }

  return <section className="card pwa-card" id="install-app"><div className="pwa-icon"><span className="coin-mark">G</span></div><div><span className="eyebrow">Handy-App</span><h2>GIBB Coin installieren</h2><p>Lege die Wallet wie eine App auf deinen Home-Bildschirm. Anmeldung und geschützte Daten bleiben weiterhin online.</p>{message && <small>{message}</small>}</div><button className="secondary" type="button" disabled={installed} onClick={() => void install()}>{installed ? "Installiert" : "App installieren"}</button></section>;
}
