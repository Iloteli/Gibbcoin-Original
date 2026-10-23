"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type PayoutRequest = { id: string; rappen: number; status: "pending" | "paid" | "rejected" | "cancelled"; created_at: string; iban_end: string };
type PayoutState = { enabled: boolean; min_rappen: number; credits: number; requests: PayoutRequest[] };
type Mode = "gibb" | "credits";

const chf = (rappen: number) => `CHF ${(rappen / 100).toLocaleString("de-CH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const statusLabel: Record<PayoutRequest["status"], string> = { pending: "wird überwiesen", paid: "überwiesen ✓", rejected: "abgelehnt", cancelled: "abgebrochen" };
const errors: Record<string, string> = {
  payouts_disabled: "Auszahlungen sind gerade ausgeschaltet.", invalid_iban: "Bitte eine Schweizer IBAN eingeben (CH…).",
  invalid_holder: "Bitte den Namen der Kontoinhaberin / des Kontoinhabers eingeben.", payout_pending: "Du hast schon eine offene Auszahlung.",
  wallet_locked: "Dein Wallet ist gesperrt.", insufficient_funds: "So viele GIBB hast du nicht.", sell_disabled: "Verkaufen ist gerade ausgeschaltet – darum geht Auszahlen aus GIBB nicht.",
  market_disabled: "Der Markt ist gerade ausgeschaltet.", price_limit: "Der Kurs ist am Mindestkurs – gerade kann nicht verkauft werden.", daily_sell_limit: "Dein Verkaufslimit für heute ist erreicht.",
  amount_too_small: "Der Betrag ist zu klein.", invalid_amount: "Bitte einen Betrag eingeben.",
};

// Auszahlen als echtes Geld aufs eigene Bankkonto: direkt aus GIBB (werden zum Kurs verkauft) oder aus Credits.
export function CreditsPayout({ onChanged }: { onChanged?: () => void }) {
  const [state, setState] = useState<PayoutState | null>(null);
  const [mode, setMode] = useState<Mode>("gibb");
  const [value, setValue] = useState("");
  const [quote, setQuote] = useState<number | null>(null);
  const [iban, setIban] = useState("");
  const [holder, setHolder] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    const supabase = getSupabase(); if (!supabase) return;
    const { data, error: rpcError } = await supabase.rpc("get_payout_state");
    if (!rpcError && data) setState(data as PayoutState);
  }, []);
  useEffect(() => {
    const supabase = getSupabase(); if (!supabase) return;
    let alive = true;
    void supabase.rpc("get_payout_state").then(({ data, error: rpcError }) => { if (alive && !rpcError && data) setState(data as PayoutState); });
    return () => { alive = false; };
  }, []);

  // Wie viel CHF gibt es für die eingegebenen GIBB? (aktueller Kurs inkl. Gebühr)
  const gibb = Math.floor(Number(value));
  useEffect(() => {
    if (mode !== "gibb" || !Number.isFinite(gibb) || gibb < 1) return;
    const supabase = getSupabase(); if (!supabase) return;
    let alive = true;
    const timer = window.setTimeout(() => {
      void supabase.rpc("market_quote", { p_gibb: gibb }).then(({ data }) => {
        const q = data as { ok?: boolean; sell_rappen?: number } | null;
        if (alive) setQuote(q?.ok ? Number(q.sell_rappen ?? 0) : null);
      });
    }, 300);
    return () => { alive = false; window.clearTimeout(timer); };
  }, [mode, gibb]);

  if (!state || (!state.enabled && state.requests.length === 0)) return null;
  const rappen = mode === "credits" ? Math.round(Number(value.replace(",", ".")) * 100) : (gibb >= 1 ? quote ?? 0 : 0);

  async function request(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase(); if (!supabase) return;
    if (mode === "gibb" && (!Number.isFinite(gibb) || gibb < 1)) { setError("Wie viele GIBB möchtest du auszahlen?"); return; }
    if (mode === "credits" && (!Number.isFinite(rappen) || rappen <= 0)) { setError("Betrag in CHF eingeben."); return; }
    if (rappen > 0 && rappen < (state?.min_rappen ?? 500)) { setError(`Mindestens ${chf(state?.min_rappen ?? 500)} pro Auszahlung – das wären nur ${chf(rappen)}.`); return; }
    setBusy(true); setError(""); setMessage("");
    const { data, error: rpcError } = mode === "gibb"
      ? await supabase.rpc("request_payout_gibb", { p_gibb: gibb, p_iban: iban, p_holder: holder })
      : await supabase.rpc("request_payout", { p_rappen: rappen, p_iban: iban, p_holder: holder });
    setBusy(false);
    const r = data as { ok?: boolean; error?: string; rappen?: number } | null;
    if (rpcError || !r?.ok) {
      // Fehler aus der Datenbank: "payout_failed:invalid_iban" usw.
      const key = r?.error ?? /payout_failed:(\w+)/.exec(rpcError?.message ?? "")?.[1] ?? (rpcError?.code === "PGRST202" ? "missing" : "");
      const have = state?.credits ?? 0;
      setError(key === "insufficient_credits" ? `So viele Credits hast du nicht – du hast ${chf(have)}. Wähle „aus GIBB“, um direkt aus deinen GIBB auszuzahlen.`
        : key === "below_minimum" ? `Mindestens ${chf(state?.min_rappen ?? 500)} pro Auszahlung.`
        : key === "missing" ? "Auszahlen aus GIBB ist auf dem Server noch nicht eingerichtet."
        : errors[key] ?? "Die Auszahlung konnte nicht angefordert werden.");
      return;
    }
    setMessage(`Auszahlung über ${chf(r.rappen ?? rappen)} angefordert – das Geld kommt per Überweisung, sobald sie bestätigt ist.`);
    setValue(""); setQuote(null);
    await load(); onChanged?.();
  }

  async function cancel(id: string) {
    const supabase = getSupabase(); if (!supabase) return;
    await supabase.rpc("cancel_my_payout", { p_id: id });
    await load(); onChanged?.();
  }

  const pending = state.requests.some((r) => r.status === "pending");
  return <section className="card card-pad credits-payout">
    <div className="card-head"><h2>💸 Auszahlen</h2><span>als echtes Geld aufs Bankkonto</span></div>
    {state.enabled && !pending && <form className="payout-form" onSubmit={request}>
      <div className="payout-mode" role="radiogroup" aria-label="Woraus auszahlen?">
        <button type="button" className={mode === "gibb" ? "active" : ""} aria-pressed={mode === "gibb"} onClick={() => { setMode("gibb"); setValue(""); setQuote(null); }}>🪙 aus GIBB</button>
        <button type="button" className={mode === "credits" ? "active" : ""} aria-pressed={mode === "credits"} onClick={() => { setMode("credits"); setValue(""); }}>💳 aus Credits ({chf(state.credits ?? 0)})</button>
      </div>
      <p className="muted">{mode === "gibb" ? "Deine GIBB werden zum aktuellen Kurs verkauft (inkl. Handelsgebühr), der Betrag wird dir überwiesen." : "Credits bekommst du, wenn du GIBB an die Bank verkaufst."} Mindestens {chf(state.min_rappen)}. Wird die Auszahlung abgelehnt, bekommst du den Betrag als Credits zurück.</p>
      <div className="payout-grid">
        {mode === "gibb"
          ? <div className="field"><label htmlFor="payout-value">Menge (GIBB)</label><input id="payout-value" className="input" inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value.replace(/[^0-9]/g, ""))} placeholder="z. B. 1000" /><small className="field-hint">{gibb >= 1 ? (quote != null ? `≈ ${chf(quote)}` : "Kurs wird berechnet …") : "wie viele GIBB auszahlen"}</small></div>
          : <div className="field"><label htmlFor="payout-value">Betrag (CHF)</label><div className="payout-amount"><input id="payout-value" className="input" inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} placeholder={(state.min_rappen / 100).toFixed(2)} /><button type="button" className="secondary compact" onClick={() => setValue(((state.credits ?? 0) / 100).toFixed(2))}>Alles</button></div><small className="field-hint">{rappen > 0 ? `= ${rappen} Rp` : "in Franken, z. B. 5.50"}</small></div>}
        <div className="field"><label htmlFor="payout-iban">IBAN</label><input id="payout-iban" className="input" autoComplete="off" value={iban} onChange={(e) => setIban(e.target.value.toUpperCase())} placeholder="CH00 0000 0000 0000 0000 0" /></div>
        <div className="field"><label htmlFor="payout-holder">Kontoinhaber/in</label><input id="payout-holder" className="input" autoComplete="name" value={holder} onChange={(e) => setHolder(e.target.value)} placeholder="Vorname Nachname" /></div>
      </div>
      <button className="primary" type="submit" disabled={busy}>{busy ? "Wird angefordert …" : rappen > 0 ? `${chf(rappen)} auszahlen` : "Auszahlung anfordern"}</button>
    </form>}
    {!state.enabled && <p className="muted">Auszahlungen sind gerade ausgeschaltet.</p>}
    {message && <p className="message success-message" role="status">{message}</p>}
    {error && <p className="message error" role="alert">{error}</p>}
    {state.requests.length > 0 && <div className="payout-list">{state.requests.map((r) => <div key={r.id} className={`payout-row ${r.status}`}>
      <span>{new Date(r.created_at).toLocaleDateString("de-CH")}</span><b>{chf(r.rappen)}</b><span>…{r.iban_end}</span><span className="payout-status">{statusLabel[r.status]}</span>
      {r.status === "pending" && <button type="button" className="secondary compact" onClick={() => void cancel(r.id)}>Abbrechen</button>}
    </div>)}</div>}
  </section>;
}
