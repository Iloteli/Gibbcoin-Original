"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { createCheckoutSession, getSupabase } from "../lib/supabase";
import { LineChart } from "./BlockchainCharts";

type MarketState = {
  price: number; enabled: boolean; sell_fee: number; max_trade: number; min_price: number; max_price: number;
  price_24h_ago: number; volume_24h: number;
  history: Array<{ t: string; p: number; k: string; n: number }>;
  my_gibb: number; my_credits: number;
  buy_enabled?: boolean; sell_enabled?: boolean; daily_sell_limit?: number; my_sold_24h?: number;
  settings?: MarketSettings | null;
};
type MarketSettings = {
  price: number; step: number; min_price: number; max_price: number; sell_fee: number; max_trade: number;
  enabled: boolean; buy_enabled: boolean; sell_enabled: boolean; daily_sell_limit: number;
};
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
  purchases_disabled: "Kauf mit echtem Geld ist noch nicht freigeschaltet.",
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
  const [form, setForm] = useState<MarketSettings | null>(null);
  const [pin, setPin] = useState("");
  const [savingSettings, setSavingSettings] = useState(false);
  const [settingsMessage, setSettingsMessage] = useState("");

  const load = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const { data, error: rpcError } = await supabase.rpc("get_market_state");
    if (rpcError) { setLoadError("Der Markt ist noch nicht verfügbar (Datenbank-Update fehlt)."); return; }
    setLoadError("");
    const next = data as MarketState;
    setState(next);
    if (next.settings) setForm((current) => current ?? next.settings ?? null);
  }, []);

  const saveSettings = async () => {
    const supabase = getSupabase();
    if (!supabase || !form) return;
    setSavingSettings(true); setSettingsMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_update_market_settings", { p_value: form, p_pin: pin });
    setSavingSettings(false);
    const result = data as { ok?: boolean; error?: string; settings?: MarketSettings } | null;
    if (rpcError || !result?.ok) {
      const code = result?.error ?? "";
      setSettingsMessage(code === "owner_required" ? "Dafür fehlen dir die Rechte." : code.startsWith("admin_pin_") ? "Admin-PIN ungültig oder Freigabe abgelaufen." : code === "invalid_price_range" ? "Der Mindestkurs darf nicht über dem Höchstkurs liegen." : "Die Einstellungen konnten nicht gespeichert werden.");
      return;
    }
    if (result.settings) setForm(result.settings);
    setPin("");
    setSettingsMessage("Markt-Einstellungen gespeichert.");
    await load();
  };
  const num = (key: keyof MarketSettings) => (event: { target: { value: string } }) => form && setForm({ ...form, [key]: Number(event.target.value) });
  const flag = (key: keyof MarketSettings) => (event: { target: { value: string } }) => form && setForm({ ...form, [key]: event.target.value === "1" });

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
            <button className="primary" type="button" disabled={!!busy || !stripeOk || state?.buy_enabled === false} onClick={() => void act("stripe")}>{busy === "stripe" ? "Weiter zu Stripe …" : "Mit Karte / TWINT kaufen"}</button>
            <button className="secondary" type="button" disabled={!!busy || state?.buy_enabled === false || !quote?.ok || !quote.buy_possible || (state?.my_credits ?? 0) < (quote.buy_rappen ?? 0)} onClick={() => void act("credits")}>{busy === "credits" ? "Kauft …" : "Mit Credits kaufen"}</button>
            {quote?.ok && (quote.buy_rappen ?? 0) < 50 && <small className="field-hint">Mit Karte erst ab CHF 0.50.</small>}
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
        <small className="field-hint">Verkäufe werden nicht in echtem Geld ausbezahlt, sondern als Credits gutgeschrieben – damit kannst du später wieder GIBB kaufen.</small>
      </section>

      {form && (
        <section className="card card-pad blockchain-admin" aria-label="Markt-Einstellungen">
          <div className="card-head"><h2>Admin · Coinwert</h2><span>Kurs, Grenzen, Gebühren, Handel</span></div>
          <div className="blockchain-admin-grid">
            <label className="field"><span>Kurs jetzt (Rp pro GIBB)</span><input className="input" type="number" step="0.01" min={0.01} value={form.price} onChange={num("price")} /></label>
            <label className="field"><span>Mindestkurs (Rp)</span><input className="input" type="number" step="0.01" min={0.01} value={form.min_price} onChange={num("min_price")} /></label>
            <label className="field"><span>Höchstkurs (Rp)</span><input className="input" type="number" step="0.01" min={0.01} value={form.max_price} onChange={num("max_price")} /></label>
            <label className="field"><span>Kursänderung pro GIBB (%)</span><input className="input" type="number" step="0.001" min={0} max={5} value={Number((Number(form.step) * 100).toFixed(4))} onChange={(e) => setForm({ ...form, step: Number(e.target.value) / 100 })} /></label>
            <label className="field"><span>Verkaufsgebühr (%)</span><input className="input" type="number" step="0.1" min={0} max={90} value={Number((Number(form.sell_fee) * 100).toFixed(2))} onChange={(e) => setForm({ ...form, sell_fee: Number(e.target.value) / 100 })} /></label>
            <label className="field"><span>Max. GIBB pro Handel</span><input className="input" type="number" min={1} max={100000} value={form.max_trade} onChange={num("max_trade")} /></label>
            <label className="field"><span>Verkaufslimit pro Person / 24 h (0 = keins)</span><input className="input" type="number" min={0} value={form.daily_sell_limit} onChange={num("daily_sell_limit")} /></label>
            <label className="field"><span>Markt aktiv</span><select className="input" value={form.enabled ? "1" : "0"} onChange={flag("enabled")}><option value="1">Ja</option><option value="0">Nein</option></select></label>
            <label className="field"><span>Kaufen erlaubt</span><select className="input" value={form.buy_enabled ? "1" : "0"} onChange={flag("buy_enabled")}><option value="1">Ja</option><option value="0">Nein</option></select></label>
            <label className="field"><span>Verkaufen erlaubt</span><select className="input" value={form.sell_enabled ? "1" : "0"} onChange={flag("sell_enabled")}><option value="1">Ja</option><option value="0">Nein</option></select></label>
            <label className="field"><span>Admin-PIN</span><input className="input" type="password" autoComplete="off" inputMode="numeric" value={pin} onChange={(e) => setPin(e.target.value)} placeholder="PIN zur Freigabe" /></label>
          </div>
          <div className="blockchain-actions">
            <button className="primary compact" type="button" disabled={savingSettings || !pin} onClick={() => void saveSettings()}>{savingSettings ? "Speichert …" : "Einstellungen speichern"}</button>
            {settingsMessage && <span className={`message ${settingsMessage.includes("gespeichert") ? "" : "error"}`}>{settingsMessage}</span>}
          </div>
          <small className="field-hint">Kaufen hebt den Kurs pro GIBB um die eingestellte Kursänderung, Verkaufen senkt ihn. Der Kurs bleibt immer zwischen Mindest- und Höchstkurs.</small>
        </section>
      )}
    </div>
  );
}
