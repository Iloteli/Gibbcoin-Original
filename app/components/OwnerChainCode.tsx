"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { preferredNodeUrl } from "../lib/node-url";

// Anmelde-Code (zweiter Faktor) für die Chain-Seite: nur für Full-Owner, wechselt alle 5 Minuten.
type CodeState = { code: string; validUntil: number; offset: number } | { error: string } | null;

const errorText: Record<string, string> = {
  not_full: "Nur Full-Konten brauchen einen Code. Ilja kann dich auf der Chain-Seite auf Full setzen.",
  not_owner: "Nur für Owner.",
  account_disabled: "Dein Zugang zur Chain-Seite ist deaktiviert.",
};

export function OwnerChainCode() {
  const [state, setState] = useState<CodeState>(null);
  const [now, setNow] = useState(() => Date.now());
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    const { data } = (await getSupabase()?.auth.getSession()) ?? { data: { session: null } };
    const token = data.session?.access_token;
    if (!token) return;
    try {
      const res = await fetch(`${preferredNodeUrl()}/api/owner-code`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ supabaseToken: token }) });
      const body = await res.json().catch(() => ({}));
      if (!res.ok || !body.code) { setState({ error: String(body.error ?? "unavailable") }); return; }
      setState({ code: String(body.code), validUntil: Number(body.validUntil), offset: Number(body.serverTime) - Date.now() });
    } catch {
      setState({ error: "unavailable" });
    }
  }, []);

  useEffect(() => {
    const first = window.setTimeout(() => void load(), 0);
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => { window.clearTimeout(first); window.clearInterval(tick); };
  }, [load]);

  // Neuen Code holen, sobald der alte abläuft
  const validUntil = state && "code" in state ? state.validUntil : 0;
  const offset = state && "code" in state ? state.offset : 0;
  const left = validUntil ? Math.max(0, Math.ceil((validUntil - (now + offset)) / 1000)) : 0;
  useEffect(() => {
    if (!validUntil) return;
    const wait = Math.max(1000, validUntil - (Date.now() + offset) + 1000);
    const timer = window.setTimeout(() => void load(), wait);
    return () => window.clearTimeout(timer);
  }, [validUntil, offset, load]);

  // Nur Full-Owner sehen die Karte
  if (state && "error" in state && ["not_owner", "not_full", "account_disabled"].includes(state.error)) return null;

  const copy = async (code: string) => {
    try { await navigator.clipboard.writeText(code); setCopied(true); window.setTimeout(() => setCopied(false), 1500); } catch { /* nicht erlaubt */ }
  };

  return (
    <section className="card card-pad owner-code-card" aria-live="polite">
      <div className="card-head"><h2>🔑 Code für die Chain-Seite</h2><span>zweiter Faktor · nur für dich</span></div>
      {state === null && <p className="field-hint">Code wird geladen …</p>}
      {state && "error" in state && <p className="field-hint">{errorText[state.error] ?? "Der Code ist gerade nicht verfügbar (Chain-Server nicht erreichbar)."}</p>}
      {state && "code" in state && (
        <>
          <div className="owner-code-row">
            <strong className="owner-code" aria-label={`Code ${state.code.split("").join(" ")}`}>{state.code.slice(0, 3)} {state.code.slice(3)}</strong>
            <button type="button" className="secondary compact" onClick={() => void copy(state.code)}>{copied ? "Kopiert" : "Kopieren"}</button>
          </div>
          <div className="owner-code-bar" aria-hidden="true"><i style={{ width: `${Math.min(100, (left / 300) * 100)}%` }} /></div>
          <p className="field-hint">Neuer Code in {Math.floor(left / 60)}:{String(left % 60).padStart(2, "0")} · Beim Anmelden auf der Chain-Seite ins Feld „Server-Code“ eintragen. Gib ihn niemandem weiter.</p>
        </>
      )}
    </section>
  );
}
