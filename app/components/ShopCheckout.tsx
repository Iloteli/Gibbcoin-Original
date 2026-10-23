"use client";

import { QRCodeSVG } from "qrcode.react";
import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabase } from "../lib/supabase";

type Sale = { id: string; amount: number; note: string | null; paid_at: string; payer: string | null };
type InvoiceState = { id: string; amount: number; expiresAt: number; status: "open" | "paid" | "expired" | "cancelled"; payer?: string | null };

const PAY_EVENT = "gibb-shop-pay";
// Link im QR-Code: öffnet die Hauptseite und das Bezahlen-Fenster
export const payLink = (id: string) => `${window.location.origin}/#pay=${id}`;
export const payIdFromText = (text: string) => /[#?&]pay=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i.exec(text)?.[1] ?? null;
export function openShopPayment(id: string) { window.dispatchEvent(new CustomEvent(PAY_EVENT, { detail: { id } })); }

// Kurzer "Kassen-Ton", wenn bezahlt wurde
function chime() {
  try {
    const ctx = new AudioContext();
    [660, 880].forEach((freq, i) => {
      const osc = ctx.createOscillator(); const gain = ctx.createGain();
      osc.frequency.value = freq; osc.connect(gain); gain.connect(ctx.destination);
      const t = ctx.currentTime + i * 0.14;
      gain.gain.setValueAtTime(0.0001, t); gain.gain.exponentialRampToValueAtTime(0.25, t + 0.02); gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.35);
      osc.start(t); osc.stop(t + 0.4);
    });
  } catch { /* ohne Ton */ }
}

// Kasse für Läden: Betrag eingeben → QR-Code → Kunde scannt → "Bezahlt"
export function ShopCheckout({ onChanged }: { onChanged?: () => void }) {
  const [shopName, setShopName] = useState<string | null>(null);
  const [amount, setAmount] = useState("");
  const [note, setNote] = useState("");
  const [invoice, setInvoice] = useState<InvoiceState | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [sales, setSales] = useState<Sale[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const onChangedRef = useRef(onChanged);
  useEffect(() => { onChangedRef.current = onChanged; });

  const loadSales = useCallback(async () => {
    const supabase = getSupabase(); if (!supabase) return;
    const { data } = await supabase.rpc("shop_list_sales", { p_limit: 10 });
    setSales(Array.isArray(data) ? data as Sale[] : []);
  }, []);

  useEffect(() => {
    const supabase = getSupabase(); if (!supabase) return;
    let alive = true;
    void supabase.rpc("shop_status").then(({ data }) => {
      const s = data as { is_merchant?: boolean; shop_name?: string | null } | null;
      if (!alive || !s?.is_merchant) return;
      setShopName(s.shop_name ?? "Laden");
      void loadSales();
    });
    return () => { alive = false; };
  }, [loadSales]);

  // Offene Rechnung: alle 2 Sekunden nachsehen, ob bezahlt wurde
  useEffect(() => {
    if (!invoice || invoice.status !== "open") return;
    const supabase = getSupabase(); if (!supabase) return;
    const timer = window.setInterval(async () => {
      setNow(Date.now());
      const { data } = await supabase.rpc("shop_invoice_status", { p_id: invoice.id });
      const s = data as { ok?: boolean; status?: InvoiceState["status"]; payer?: string | null } | null;
      if (!s?.ok || !s.status || s.status === "open") return;
      setInvoice((cur) => (cur && cur.id === invoice.id ? { ...cur, status: s.status!, payer: s.payer } : cur));
      if (s.status === "paid") { chime(); void loadSales(); onChangedRef.current?.(); }
    }, 2000);
    return () => window.clearInterval(timer);
  }, [invoice, loadSales]);

  if (!shopName) return null;

  async function create(event: React.FormEvent) {
    event.preventDefault();
    const value = Math.floor(Number(amount));
    if (!Number.isFinite(value) || value < 1 || value > 100000) { setError("Betrag zwischen 1 und 100’000 GIBB eingeben."); return; }
    const supabase = getSupabase(); if (!supabase) return;
    setBusy(true); setError("");
    const { data, error: rpcError } = await supabase.rpc("shop_create_invoice", { p_amount: value, p_note: note.trim() || null });
    setBusy(false);
    const r = data as { ok?: boolean; id?: string; amount?: number; expires_at?: string; error?: string } | null;
    if (rpcError || !r?.ok || !r.id) { setError(r?.error === "not_a_shop" ? "Dieses Konto ist kein Laden mehr." : "Die Zahlung konnte nicht erstellt werden."); return; }
    setNow(Date.now());
    setInvoice({ id: r.id, amount: r.amount ?? value, expiresAt: new Date(r.expires_at ?? Date.now() + 600000).getTime(), status: "open" });
  }

  async function cancel() {
    const supabase = getSupabase();
    if (supabase && invoice?.status === "open") await supabase.rpc("shop_cancel_invoice", { p_id: invoice.id });
    setInvoice(null); setAmount(""); setNote("");
  }

  const secondsLeft = invoice ? Math.max(0, Math.round((invoice.expiresAt - now) / 1000)) : 0;
  const expired = invoice?.status === "expired" || (invoice?.status === "open" && secondsLeft === 0);

  return <section className="card card-pad shop-checkout" id="kasse">
    <div className="card-head"><h2>🏪 Kasse · {shopName}</h2><span>Kunden bezahlen per QR-Code</span></div>
    {!invoice && <form className="shop-form" onSubmit={create}>
      <div className="field"><label htmlFor="shop-amount">Betrag (GIBB)</label><input id="shop-amount" className="input shop-amount" inputMode="numeric" type="number" min={1} max={100000} value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0" autoComplete="off" /></div>
      <div className="shop-quick">{[5, 10, 20, 50, 100].map((n) => <button key={n} type="button" className="secondary compact" onClick={() => setAmount(String(n))}>{n}</button>)}</div>
      <div className="field"><label htmlFor="shop-note">Was wird gekauft? <span>optional</span></label><input id="shop-note" className="input" maxLength={80} value={note} onChange={(e) => setNote(e.target.value)} placeholder="z. B. Brötli und Getränk" /></div>
      <button className="primary" type="submit" disabled={busy}>{busy ? "Erstellt …" : "QR-Code zum Bezahlen anzeigen"}</button>
    </form>}
    {invoice && invoice.status === "paid" && <div className="shop-paid" role="status">
      <span className="shop-paid-icon" aria-hidden="true">✓</span>
      <strong>{invoice.amount} GIBB bezahlt</strong>
      <small>{invoice.payer ? `von @${invoice.payer}` : ""}</small>
      <button className="primary" type="button" onClick={() => { setInvoice(null); setAmount(""); setNote(""); }}>Nächster Kunde</button>
    </div>}
    {invoice && invoice.status !== "paid" && <div className="shop-qr">
      {expired || invoice.status === "cancelled" ? <p className="message error">Dieser QR-Code ist abgelaufen.</p> : <>
        <div className="shop-qr-code"><QRCodeSVG value={payLink(invoice.id)} size={240} level="M" bgColor="#ffffff" fgColor="#07100d" title={`${invoice.amount} GIBB bezahlen`} /></div>
        <strong className="shop-qr-amount">{invoice.amount} GIBB</strong>
        <small>Kunde scannt den Code mit der GIBB-Coin-Seite (Senden → QR scannen) oder der Handy-Kamera. Gültig noch {Math.floor(secondsLeft / 60)}:{String(secondsLeft % 60).padStart(2, "0")}</small>
        <span className="shop-waiting">Warte auf Zahlung …</span>
      </>}
      <button className="secondary" type="button" onClick={() => void cancel()}>{expired ? "Neue Zahlung" : "Abbrechen"}</button>
    </div>}
    {error && <p className="message error" role="alert">{error}</p>}
    {sales.length > 0 && <div className="shop-sales"><h3>Letzte Verkäufe</h3>{sales.map((s) => <div key={s.id} className="shop-sale"><span>{new Date(s.paid_at).toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit" })}</span><span>{s.payer ? `@${s.payer}` : "–"}{s.note ? ` · ${s.note}` : ""}</span><b>+{s.amount} GIBB</b></div>)}</div>}
  </section>;
}

type PayInfo = { ok?: boolean; error?: string; shop_name?: string; amount?: number; note?: string | null; status?: string; own?: boolean };
const payErrors: Record<string, string> = {
  insufficient_balance: "Dein Guthaben reicht nicht.", already_paid: "Diese Rechnung wurde schon bezahlt.", invoice_expired: "Dieser QR-Code ist abgelaufen – bitte an der Kasse einen neuen zeigen lassen.",
  own_invoice: "Das ist deine eigene Kasse.", not_a_shop: "Dieser Laden ist nicht mehr aktiv.", not_found: "Diese Zahlung gibt es nicht.", wallet_locked: "Dein Wallet ist gesperrt.",
  shop_payment_needs_approval: "Dieser Betrag braucht die Freigabe deiner erziehungsberechtigten Person – an der Kasse bitte kleiner bezahlen.",
};

// Kunde: Bezahlen-Fenster (nach dem Scannen oder über den Link #pay=…)
export function ShopPayModal({ onPaid }: { onPaid?: () => void }) {
  const [id, setId] = useState<string | null>(null);
  const [info, setInfo] = useState<PayInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<"" | "paid">("");
  const [error, setError] = useState("");

  const open = useCallback(async (next: string) => {
    setId(next); setInfo(null); setResult(""); setError("");
    const supabase = getSupabase(); if (!supabase) { setError("Offline – bitte später nochmals."); return; }
    const { data } = await supabase.rpc("shop_invoice_info", { p_id: next });
    setInfo((data as PayInfo | null) ?? { ok: false, error: "not_found" });
  }, []);

  useEffect(() => {
    const onEvent = (e: Event) => { const next = (e as CustomEvent<{ id?: string }>).detail?.id; if (next) void open(next); };
    window.addEventListener(PAY_EVENT, onEvent);
    // Link #pay=… beim Öffnen der Seite
    const fromHash = payIdFromText(window.location.hash);
    if (fromHash) { history.replaceState(null, "", `${window.location.pathname}${window.location.search}#send`); window.dispatchEvent(new HashChangeEvent("hashchange")); window.setTimeout(() => void open(fromHash), 0); }
    return () => window.removeEventListener(PAY_EVENT, onEvent);
  }, [open]);

  if (!id) return null;
  const close = () => { setId(null); setInfo(null); };

  async function pay() {
    const supabase = getSupabase(); if (!supabase || !id) return;
    setBusy(true); setError("");
    const { data, error: rpcError } = await supabase.rpc("shop_pay_invoice", { p_id: id });
    setBusy(false);
    const r = data as { ok?: boolean; error?: string } | null;
    if (rpcError || !r?.ok) {
      const key = r?.error ?? Object.keys(payErrors).find((k) => rpcError?.message?.includes(k)) ?? "";
      setError(payErrors[key] ?? "Die Zahlung hat nicht geklappt.");
      return;
    }
    setResult("paid");
    onPaid?.();
  }

  const status = info?.status;
  return <div className="modal-backdrop" role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}>
    <section className="shop-pay-modal" role="dialog" aria-modal="true" aria-labelledby="shop-pay-title">
      <h2 id="shop-pay-title">🏪 {info?.shop_name ?? "Bezahlen"}</h2>
      {!info && !error && <p className="muted">Wird geladen …</p>}
      {info && !info.ok && <p className="message error">{payErrors[info.error ?? ""] ?? "Diese Zahlung gibt es nicht."}</p>}
      {info?.ok && result !== "paid" && <>
        <strong className="shop-qr-amount">{info.amount} GIBB</strong>
        {info.note && <p className="muted">{info.note}</p>}
        {status !== "open" ? <p className="message error">{payErrors[status === "paid" ? "already_paid" : "invoice_expired"]}</p>
          : info.own ? <p className="message error">{payErrors.own_invoice}</p>
          : <button className="primary" type="button" disabled={busy} onClick={() => void pay()}>{busy ? "Bezahlt …" : `${info.amount} GIBB bezahlen`}</button>}
      </>}
      {result === "paid" && <div className="shop-paid"><span className="shop-paid-icon" aria-hidden="true">✓</span><strong>Bezahlt!</strong><small>{info?.amount} GIBB an {info?.shop_name}</small></div>}
      {error && <p className="message error" role="alert">{error}</p>}
      <button className="secondary" type="button" onClick={close}>{result === "paid" ? "Fertig" : "Abbrechen"}</button>
    </section>
  </div>;
}
