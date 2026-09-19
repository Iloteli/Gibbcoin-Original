"use client";

import { useState } from "react";
import type { Transaction } from "../lib/types";

type Props = {
  transaction: Transaction;
  userId: string;
  onClose: () => void;
  onReceipt: (transaction: Transaction) => void;
};

export function TransactionDetails({ transaction, userId, onClose, onReceipt }: Props) {
  const [copied, setCopied] = useState("");
  const sent = transaction.sender_user_id === userId;
  const date = new Date(transaction.created_at);

  async function copy(value: string, label: string) {
    if (!navigator.clipboard) return;
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      setCopied("Kopieren ist in diesem Browser nicht verfügbar");
      return;
    }
    setCopied(label);
    window.setTimeout(() => setCopied(""), 1800);
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section className="pin-modal transaction-details-modal" role="dialog" aria-modal="true" aria-labelledby="transaction-details-title">
        <div className="section-heading compact-heading"><div><span className="section-number">DETAIL</span><h2 id="transaction-details-title">Transaktionsdetails</h2></div><button className="secondary compact" type="button" onClick={onClose}>Schließen</button></div>
        <div className="transaction-detail-summary"><strong className={sent ? "negative" : "positive"}>{sent ? "−" : "+"}{transaction.amount} GIBB</strong><span>{sent ? "Ausgang" : "Eingang"} · {date.toLocaleString("de-CH")}</span></div>
        <dl className="transaction-detail-list">
          <div><dt>Von</dt><dd>{transaction.sender_label}</dd></div>
          <div><dt>An</dt><dd>{transaction.receiver_label}</dd></div>
          <div><dt>Typ</dt><dd>{transaction.type.replaceAll("_", " ")}</dd></div>
          <div><dt>Notiz</dt><dd>{transaction.note || "–"}</dd></div>
          <div><dt>Transaktions-ID</dt><dd><code>{transaction.id}</code><button className="secondary compact" type="button" onClick={() => void copy(transaction.id, "ID kopiert")}>Kopieren</button></dd></div>
          <div><dt>Hash</dt><dd><code>{transaction.hash}</code><button className="secondary compact" type="button" onClick={() => void copy(transaction.hash, "Hash kopiert")}>Kopieren</button></dd></div>
        </dl>
        <div className="modal-actions"><button className="secondary" type="button" onClick={onClose}>Fertig</button><button className="primary compact" type="button" onClick={() => onReceipt(transaction)}>Beleg herunterladen</button></div>
        {copied && <p className="message success-message" role="status">✓ {copied}</p>}
      </section>
    </div>
  );
}
