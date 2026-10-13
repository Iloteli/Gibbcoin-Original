"use client";

import type { Transaction } from "../lib/types";

// Credits aus Verkäufen an die Bank: Stand und letzte Verkäufe (aus den eigenen Transaktionen).
const chf = (rappen: number) => `CHF ${(rappen / 100).toFixed(2)}`;
const rappenFromNote = (note?: string | null) => {
  const match = /für\s+(\d+)\s*Rp/i.exec(note ?? "");
  return match ? Number(match[1]) : null;
};

export function CreditsSummary({ credits, transactions, userId }: { credits: number; transactions: Transaction[]; userId: string }) {
  const sales = transactions.filter((t) => t.type === "MARKET_SELL" && t.sender_user_id === userId).slice(0, 10);
  const buys = transactions.filter((t) => t.type === "MARKET_BUY" && t.receiver_user_id === userId).slice(0, 10);
  return (
    <details className="credits-summary">
      <summary>
        <span>Credits aus Verkäufen</span>
        <strong>{credits.toLocaleString("de-CH")} Rp <small>= {chf(credits)}</small></strong>
      </summary>
      <p className="field-hint">Credits bekommst du, wenn du GIBB an die Bank verkaufst. Du kannst damit wieder GIBB kaufen – sie werden nicht in echtem Geld ausbezahlt.</p>
      {sales.length === 0 && buys.length === 0 && <p className="field-hint">Noch keine Verkäufe.</p>}
      <ul>
        {sales.map((t) => {
          const rp = rappenFromNote(t.note);
          return <li key={t.id}><span>{new Date(t.created_at).toLocaleDateString("de-CH")} · {t.amount} GIBB verkauft</span><b className="plus">{rp !== null ? `+${rp} Rp` : "Credits"}</b></li>;
        })}
        {buys.map((t) => {
          const rp = rappenFromNote(t.note);
          return <li key={t.id}><span>{new Date(t.created_at).toLocaleDateString("de-CH")} · {t.amount} GIBB mit Credits gekauft</span><b className="minus">{rp !== null ? `−${rp} Rp` : "Credits"}</b></li>;
        })}
      </ul>
    </details>
  );
}
