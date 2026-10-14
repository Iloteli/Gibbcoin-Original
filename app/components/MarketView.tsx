"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { createCheckoutSession, getSupabase } from "../lib/supabase";
import { LineChart } from "./BlockchainCharts";
import { SwissQrBill } from "./SwissQrBill";

type MarketState = {
  price: number; enabled: boolean; sell_fee: number; max_trade: number; min_price: number; max_price: number;
  price_24h_ago: number; volume_24h: number;
  history: Array<{ t: string; p: number; k: string; n: number }>;
  my_gibb: number; my_credits: number;
  buy_enabled?: boolean; sell_enabled?: boolean; daily_sell_limit?: number; my_sold_24h?: number;
};
type BankDetails = { enabled: boolean; iban: string; holder: string; street?: string | null; zip?: string | null; city?: string | null; verified?: boolean; qr_allowed?: boolean; card_enabled?: boolean; credits_enabled?: boolean };
type BankOrder = { id: string; gibb: number; rappen: number; reference: string; status: "pending" | "paid" | "cancelled" | "rejected"; created_at: string };
type Quote = {
  ok: boolean; error?: string; gibb?: number; price?: number; buy_rappen?: number; buy_possible?: boolean;
  sell_rappen?: number; sell_possible?: boolean; price_after_buy?: number; price_after_sell?: number; max_trade?: number;
};

const errors: Record<string, string> = {
  insufficient_funds: "Du hast nicht genug GIBB.",
  insufficient_credits: "Du hast nicht genug Credits.",
  invalid_amount: "Bitte eine ganze Zahl zwischen 1 und dem Maximum eingeben.",
  price_limit: "Dieser Handel würde den Kurs über die Grenze bewegen – bitte eine kleinere Menge.",
  market_disabled: "Der Markt ist gerade pausiert.",
  buy_disabled: "Kaufen ist gerade pausiert.",
  sell_disabled: "Verkaufen ist gerade pausiert.",
  daily_sell_limit: "Dein Verkaufslimit für die letzten 24 Stunden ist erreicht.",
  amount_too_small: "Mit Karte/TWINT sind mindestens CHF 0.50 nötig – bitte mehr GIBB wählen.",
  bank_amount_too_small: "Per Überweisung sind mindestens CHF 1.00 nötig – bitte mehr GIBB wählen.",
  bank_disabled: "Kauf per Überweisung ist gerade nicht verfügbar.",
  credits_disabled: "Kaufen mit Credits ist gerade ausgeschaltet.",
  too_many_open_orders: "Du hast schon 3 offene Überweisungen. Bitte warte, bis sie bestätigt sind, oder storniere eine.",
  purchases_disabled: "Kartenzahlung ist noch nicht eingerichtet – bitte per Banküberweisung kaufen.",
  payment_not_configured: "Zahlungen sind noch nicht eingerichtet (Stripe).",
  not_authenticated: "Bitte melde dich erneut an.",
};

const chf = (rappen: number) => `CHF ${(rappen / 100).toFixed(2)}`;
const rp = (value: number) => `${Number(value).toLocaleString("de-CH", { maximumFractionDigits: 3 })} Rp`;

export function MarketView({ onChanged }: { onChanged: () => void }) {
  const [state, setState] = useState<MarketState | null>(null);
  const [amount, setAmount] = useState(100);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [loadError, setLoadError] = useState("");
  const [bank, setBank] = useState<BankDetails | null>(null);
  const [bankOrders, setBankOrders] = useState<BankOrder[]>([]);
  const [newOrder, setNewOrder] = useState<BankOrder | null>(null);
  const [cardUnavailable, setCardUnavailable] = useState(false);

  const load = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const { data, error: rpcError } = await supabase.rpc("get_market_state");
    if (rpcError) { setLoadError("Der Markt ist noch nicht verfügbar (Datenbank-Update fehlt)."); return; }
    setLoadError("");
    const next = data as MarketState;
    setState(next);
    // Banküberweisung (falls eingerichtet)
    const [{ data: bankData }, { data: orderData }] = await Promise.all([
      supabase.rpc("get_bank_details"),
      supabase.from("bank_orders").select("id,gibb,rappen,reference,status,created_at").order("created_at", { ascending: false }).limit(10),
    ]);
    setBank((bankData as BankDetails | null) ?? null);
    setBankOrders((orderData ?? []) as BankOrder[]);
  }, []);

  const orderBank = async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    setError(""); setMessage(""); setBusy("bank");
    try {
      const { data, error: rpcError } = await supabase.rpc("create_bank_order", { p_gibb: Math.floor(amount) });
      const result = data as ({ ok?: boolean; error?: string } & Partial<BankOrder>) | null;
      if (rpcError || !result?.ok) { setError(errors[result?.error ?? ""] ?? "Die Bestellung konnte nicht erstellt werden."); return; }
      setNewOrder({ id: result.id ?? "", gibb: result.gibb ?? 0, rappen: result.rappen ?? 0, reference: result.reference ?? "", status: "pending", created_at: new Date().toISOString() });
      await load();
    } finally {
      setBusy("");
    }
  };

  const cancelBank = async (id: string) => {
    const supabase = getSupabase();
    if (!supabase) return;
    await supabase.rpc("cancel_bank_order", { p_id: id });
    if (newOrder?.id === id) setNewOrder(null);
    await load();
  };

  const copy = (text: string) => { void navigator.clipboard?.writeText(text.replace(/\s+/g, text.startsWith("GIBB-") ? "" : " ")).catch(() => undefined); setMessage("Kopiert."); };


  useEffect(() => {
    const first = window.setTimeout(() => void load(), 0);
    const timer = window.setInterval(() => void load(), 15_000);
    return () => { window.clearTimeout(first); window.clearInterval(timer); };
  }, [load]);

  // Angebot für die eingegebene Menge (kurz verzögert, damit nicht jeder Tastendruck abfragt)
  useEffect(() => {
    const timer = window.setTimeout(async () => {
      const supabase = getSupabase();
      if (!supabase || !(amount >= 1)) { setQuote(null); return; }
      const { data } = await supabase.rpc("market_quote", { p_gibb: Math.floor(amount) });
      setQuote(data as Quote);
    }, 250);
    return () => window.clearTimeout(timer);
  }, [amount, state?.price]);

  // Rückkehr von Stripe
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const purchase = params.get("purchase");
    if (!purchase) return;
    const timer = window.setTimeout(() => {
      if (purchase === "success") setMessage("Danke! Die Zahlung ist eingegangen – deine GIBB werden in wenigen Sekunden gutgeschrieben.");
      if (purchase === "cancelled") setMessage("Kauf abgebrochen – es wurde nichts belastet.");
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  const change = useMemo(() => {
    if (!state || !state.price_24h_ago) return 0;
    return ((Number(state.price) - Number(state.price_24h_ago)) / Number(state.price_24h_ago)) * 100;
  }, [state]);

  const act = async (kind: "sell" | "credits" | "stripe") => {
    setError(""); setMessage(""); setBusy(kind);
    try {
      const gibb = Math.floor(amount);
      if (kind === "stripe") {
        const result = await createCheckoutSession(gibb);
        if (result.url) { window.location.assign(result.url); return; }
        if (result.error === "purchases_disabled" || result.error === "payment_not_configured") setCardUnavailable(true);
        setError(errors[result.error ?? ""] ?? "Der Kauf konnte nicht gestartet werden.");
        return;
      }
      const supabase = getSupabase();
      if (!supabase) return;
      const { data, error: rpcError } = await supabase.rpc(kind === "sell" ? "market_sell" : "market_buy_with_credits", { p_gibb: gibb });
      const result = data as { ok?: boolean; error?: string; rappen?: number } | null;
      if (rpcError || !result?.ok) { setError(errors[result?.error ?? ""] ?? "Der Handel ist fehlgeschlagen."); return; }
      setMessage(kind === "sell"
        ? `${gibb} GIBB verkauft – ${rp(result.rappen ?? 0)} Credits gutgeschrieben.`
        : `${gibb} GIBB für ${rp(result.rappen ?? 0)} Credits gekauft.`);
      onChanged();
      await load();
    } finally {
      setBusy("");
    }
  };

  const prices = (state?.history ?? []).map((h) => Number(h.p));
  const max = state?.max_trade ?? 1000;
  const stripeOk = Boolean(quote?.ok && quote.buy_possible && (quote.buy_rappen ?? 0) >= 50);

  return (
    <div className="market">
      {loadError && <div className="game-error">{loadError}</div>}
      {state && state.buy_enabled === false && state.sell_enabled === false && <div className="message">Kaufen und Verkaufen sind gerade pausiert.</div>}

      <section className="card card-pad market-hero">
        <div className="market-price">
          <span className="eyebrow">AKTUELLER KURS</span>
          <strong>{state ? rp(state.price) : "–"}<small> pro GIBB</small></strong>
          <span className={`market-change ${change > 0 ? "up" : change < 0 ? "down" : ""}`}>{change > 0 ? "▲" : change < 0 ? "▼" : "■"} {Math.abs(change).toFixed(2)} % in 24 h</span>
          <small className="field-hint">100 GIBB ≈ {state ? chf(Number(state.price) * 100) : "–"} · Handelsvolumen 24 h: {state?.volume_24h ?? 0} GIBB</small>
        </div>
        <div className="admin-stats market-mine">
          <div><span>Deine GIBB</span><strong>{state?.my_gibb ?? "–"}</strong></div>
          <div><span>Deine Credits</span><strong>{state ? rp(state.my_credits) : "–"}</strong></div>
        </div>
      </section>

      <section className="card card-pad">
        <div className="card-head"><h2>Kursverlauf</h2><span>letzte {prices.length} Handel</span></div>
        <LineChart values={prices} label="Kurs" unit="Rp" />
      </section>

      <section className="card card-pad market-trade">
        <div className="card-head"><h2>Handeln</h2><span>Kaufen hebt den Kurs, Verkaufen senkt ihn</span></div>
        <label className="field">
          <span>Menge (GIBB)</span>
          <input className="input" type="number" min={1} max={max} step={1} value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
        </label>
        <div className="market-quick">{[50, 100, 250, 500, 1000].filter((n) => n <= max).map((n) => <button key={n} type="button" className={amount === n ? "active" : ""} onClick={() => setAmount(n)}>{n}</button>)}</div>

        <div className="market-boxes">
          <article className="market-box buy">
            <h3>Kaufen</h3>
            <p className="market-sum">{quote?.ok ? rp(quote.buy_rappen ?? 0) : "–"}<small>{quote?.ok ? ` = ${chf(quote.buy_rappen ?? 0)}` : ""}</small></p>
            <small className="field-hint">Kurs danach: {quote?.ok ? rp(quote.price_after_buy ?? 0) : "–"}</small>
            {!cardUnavailable && bank?.card_enabled === true && <button className="primary" type="button" disabled={!!busy || !stripeOk || state?.buy_enabled === false} onClick={() => void act("stripe")}>{busy === "stripe" ? "Weiter zu Stripe …" : "Mit Karte / TWINT kaufen"}</button>}
            {bank?.credits_enabled !== false && <button className="secondary" type="button" disabled={!!busy || state?.buy_enabled === false || !quote?.ok || !quote.buy_possible || (state?.my_credits ?? 0) < (quote.buy_rappen ?? 0)} onClick={() => void act("credits")}>{busy === "credits" ? "Kauft …" : "Mit Credits kaufen"}</button>}
            {bank?.enabled && <button className={bank.card_enabled ? "secondary" : "primary"} type="button" disabled={!!busy || state?.buy_enabled === false || !quote?.ok || !quote.buy_possible || (quote.buy_rappen ?? 0) < 100} onClick={() => void orderBank()}>{busy === "bank" ? "Bestellung wird erstellt …" : "Per Banküberweisung kaufen"}</button>}
            {!cardUnavailable && bank?.card_enabled === true && quote?.ok && (quote.buy_rappen ?? 0) < 50 && <small className="field-hint">Mit Karte erst ab CHF 0.50.</small>}
            {bank?.enabled && quote?.ok && (quote.buy_rappen ?? 0) < 100 && <small className="field-hint">Per Überweisung erst ab CHF 1.00.</small>}
          </article>
          <article className="market-box sell">
            <h3>An die Bank verkaufen</h3>
            <p className="market-sum">{quote?.ok ? rp(quote.sell_rappen ?? 0) : "–"}<small> Credits</small></p>
            <small className="field-hint">inkl. {state ? Math.round(Number(state.sell_fee) * 100) : 2} % Gebühr · Kurs danach: {quote?.ok ? rp(quote.price_after_sell ?? 0) : "–"}{state?.daily_sell_limit ? ` · Tageslimit: noch ${Math.max(0, state.daily_sell_limit - (state.my_sold_24h ?? 0))} GIBB` : ""}</small>
            <button className="secondary" type="button" disabled={!!busy || state?.sell_enabled === false || !quote?.ok || !quote.sell_possible || (state?.my_gibb ?? 0) < amount} onClick={() => void act("sell")}>{busy === "sell" ? "Verkauft …" : `${Math.floor(amount) || 0} GIBB verkaufen`}</button>
          </article>
        </div>
        {error && <div className="message error">{error}</div>}
        {message && !error && <div className="message">{message}</div>}
        {newOrder && bank && (
          <div className="bank-transfer" role="status">
            <strong>Bitte überweise jetzt {chf(newOrder.rappen)}</strong>
            {bank.qr_allowed && bank.zip && bank.city ? <>
              <SwissQrBill iban={bank.iban} name={bank.holder} street={bank.street ?? ""} zip={bank.zip} city={bank.city} amountRappen={newOrder.rappen} message={newOrder.reference} />
              <small className="field-hint">Oder von Hand überweisen:</small>
            </> : <small className="field-hint qr-locked">🔒 QR-Rechnung zum Scannen gibt es für verifizierte Konten. Bitte den Owner, dein Konto zu verifizieren – bis dahin überweise von Hand:</small>}
            <dl>
              <dt>Empfänger</dt><dd>{bank.holder || "–"}</dd>
              <dt>IBAN</dt><dd><code>{bank.iban}</code> <button type="button" className="secondary compact" onClick={() => copy(bank.iban)}>Kopieren</button></dd>
              <dt>Betrag</dt><dd>{chf(newOrder.rappen)}</dd>
              <dt>Mitteilung an den Empfänger</dt><dd className="bank-message"><code>{newOrder.reference}</code> <button type="button" className="secondary compact" onClick={() => copy(newOrder.reference)}>Kopieren</button></dd>
            </dl>
            <p className="bank-important"><b>Wichtig:</b> Schreibe <code>{newOrder.reference}</code> in das Feld <b>„Mitteilung an den Empfänger“</b> (je nach Bank auch „Zusätzliche Informationen“ oder „Mitteilung“). <b>Nicht</b> ins Feld „Referenz“ – das ist nur für QR-Rechnungen.</p>
            <small className="field-hint">Ohne diesen Code können wir deine Zahlung nicht zuordnen. Sobald sie eingegangen ist (meist 1–2 Werktage), werden dir {newOrder.gibb} GIBB gutgeschrieben – du bekommst eine Mitteilung.</small>
          </div>
        )}
        <small className="field-hint">Verkäufe werden nicht in echtem Geld ausbezahlt, sondern als Credits gutgeschrieben – damit kannst du später wieder GIBB kaufen.</small>
      </section>

      {bankOrders.length > 0 && (
        <section className="card card-pad">
          <div className="card-head"><h2>Meine Überweisungen</h2><span>{bankOrders.filter((o) => o.status === "pending").length} offen</span></div>
          <div className="bank-orders">
            {bankOrders.map((o) => (
              <div key={o.id} className={`bank-order-row ${o.status}`}>
                <div><code>{o.reference}</code><small>{o.gibb} GIBB · {chf(o.rappen)} · {new Date(o.created_at).toLocaleDateString("de-CH")}</small></div>
                <span className="bank-status">{o.status === "pending" ? "wartet auf Zahlung" : o.status === "paid" ? "gutgeschrieben" : o.status === "cancelled" ? "storniert" : "abgelehnt"}</span>
                {o.status === "pending" && <button type="button" className="secondary compact" onClick={() => { setNewOrder(o); window.scrollTo({ top: 0, behavior: "smooth" }); }}>Zahlungsdaten</button>}
                {o.status === "pending" && <button type="button" className="secondary compact" onClick={() => void cancelBank(o.id)}>Stornieren</button>}
              </div>
            ))}
          </div>
          {bank?.enabled && <small className="field-hint">Empfänger: {bank.holder} · IBAN {bank.iban}</small>}
        </section>
      )}

    </div>
  );
}
