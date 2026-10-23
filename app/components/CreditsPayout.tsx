"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";

type PayoutRequest = { id: string; rappen: number; status: "pending" | "paid" | "rejected" | "cancelled"; created_at: string; iban_end: string };
type PayoutState = { enabled: boolean; min_rappen: number; credits: number; requests: PayoutRequest[] };

const chf = (rappen: number) => `CHF ${(rappen / 100).toLocaleString("de-CH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const statusLabel: Record<PayoutRequest["status"], string> = { pending: "wird überwiesen", paid: "überwiesen ✓", rejected: "abgelehnt", cancelled: "abgebrochen" };
const errors: Record<string, string> = {
  payouts_disabled: "Auszahlungen sind gerade ausgeschaltet.", below_minimum: "Der Betrag ist unter dem Mindestbetrag.", invalid_iban: "Bitte eine Schweizer IBAN eingeben (CH…).",
  invalid_holder: "Bitte den Namen der Kontoinhaberin / des Kontoinhabers eingeben.", payout_pending: "Du hast schon eine offene Auszahlung.", insufficient_credits: "So viele Credits hast du nicht.",
  wallet_locked: "Dein Wallet ist gesperrt.",
};

// Credits (aus GIBB-Verkäufen) als echtes Geld aufs eigene Bankkonto auszahlen lassen.
export function CreditsPayout({ onChanged }: { onChanged?: () => void }) {
  const [state, setState] = useState<PayoutState | null>(null);
  const [chfAmount, setChfAmount] = useState("");
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

  if (!state || (!state.enabled && state.requests.length === 0)) return null;
  const rappen = Math.round(Number(chfAmount.replace(",", ".")) * 100);

  async function request(event: React.FormEvent) {
    event.preventDefault();
    if (!Number.isFinite(rappen) || rappen <= 0) { setError("Betrag in CHF eingeben."); return; }
    const supabase = getSupabase(); if (!supabase) return;
    setBusy(true); setError(""); setMessage("");
    const { data, error: rpcError } = await supabase.rpc("request_payout", { p_rappen: rappen, p_iban: iban, p_holder: holder });
    setBusy(false);
    const r = data as { ok?: boolean; error?: string } | null;
    if (rpcError || !r?.ok) {
      const have = state?.credits ?? 0;
      setError(r?.error === "insufficient_credits" ? `So viele Credits hast du nicht – du hast ${chf(have)} (${have} Rp). Tipp auf „Alles“.`
        : r?.error === "below_minimum" ? `Mindestens ${chf(state?.min_rappen ?? 500)} pro Auszahlung – du wolltest ${chf(rappen)}.`
        : errors[r?.error ?? ""] ?? "Die Auszahlung konnte nicht angefordert werden.");
      return;
    }
    setMessage(`Auszahlung über ${chf(rappen)} angefordert – das Geld kommt per Überweisung, sobald sie bestätigt ist.`);
    setChfAmount("");
    await load(); onChanged?.();
  }

  async function cancel(id: string) {
    const supabase = getSupabase(); if (!supabase) return;
    await supabase.rpc("cancel_my_payout", { p_id: id });
    await load(); onChanged?.();
  }

  const pending = state.requests.some((r) => r.status === "pending");
  return <section className="card card-pad credits-payout">
    <div className="card-head"><h2>💸 Credits auszahlen</h2><span>als echtes Geld aufs Bankkonto</span></div>
    {state.enabled && !pending && <form className="payout-form" onSubmit={request}>
      <p className="muted">Du hast <b>{chf(state.credits ?? 0)}</b> Credits ({state.credits ?? 0} Rp = Rappen). Mindestens {chf(state.min_rappen)} pro Auszahlung. Die Credits werden sofort reserviert; wird die Auszahlung abgelehnt, bekommst du sie zurück.</p>
      <div className="payout-grid">
        <div className="field"><label htmlFor="payout-chf">Betrag (CHF)</label><div className="payout-amount"><input id="payout-chf" className="input" inputMode="decimal" value={chfAmount} onChange={(e) => setChfAmount(e.target.value)} placeholder={(state.min_rappen / 100).toFixed(2)} /><button type="button" className="secondary compact" onClick={() => setChfAmount(((state.credits ?? 0) / 100).toFixed(2))}>Alles</button></div><small className="field-hint">{Number.isFinite(rappen) && rappen > 0 ? `= ${rappen} Rp` : "in Franken, z. B. 5.50"}</small></div>
        <div className="field"><label htmlFor="payout-iban">IBAN</label><input id="payout-iban" className="input" autoComplete="off" value={iban} onChange={(e) => setIban(e.target.value.toUpperCase())} placeholder="CH00 0000 0000 0000 0000 0" /></div>
        <div className="field"><label htmlFor="payout-holder">Kontoinhaber/in</label><input id="payout-holder" className="input" autoComplete="name" value={holder} onChange={(e) => setHolder(e.target.value)} placeholder="Vorname Nachname" /></div>
      </div>
      <button className="primary" type="submit" disabled={busy}>{busy ? "Wird angefordert …" : "Auszahlung anfordern"}</button>
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
