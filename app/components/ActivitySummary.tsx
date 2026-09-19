"use client";

import { useMemo } from "react";
import type { Transaction } from "../lib/types";

type Props = {
  transactions: Transaction[];
  userId: string;
  offline: boolean;
};

export function ActivitySummary({ transactions, userId, offline }: Props) {
  const summary = useMemo(() => {
    const sent = transactions.filter((transaction) => transaction.sender_user_id === userId);
    const received = transactions.filter((transaction) => transaction.receiver_user_id === userId);
    const days = new Set(transactions.map((transaction) => transaction.created_at.slice(0, 10))).size;
    return {
      sentAmount: sent.reduce((total, transaction) => total + transaction.amount, 0),
      receivedAmount: received.reduce((total, transaction) => total + transaction.amount, 0),
      transactionCount: transactions.length,
      activeDays: days,
    };
  }, [transactions, userId]);
  const number = new Intl.NumberFormat("de-CH");

  return (
    <section className="card card-pad activity-summary" aria-labelledby="activity-summary-title">
      <div className="section-heading compact-heading">
        <div><span className="section-number">REPORT</span><h2 id="activity-summary-title">Deine Zusammenfassung</h2></div>
        <span className="summary-source">{offline ? "Gespeicherter Stand" : "Aktueller Verlauf"}</span>
      </div>
      <div className="activity-summary-grid">
        <div><span>Bewegungen</span><strong>{number.format(summary.transactionCount)}</strong><small>insgesamt geladen</small></div>
        <div><span>Ausgänge</span><strong>{number.format(summary.sentAmount)} GIBB</strong><small>in {number.format(transactions.filter((transaction) => transaction.sender_user_id === userId).length)} Buchungen</small></div>
        <div><span>Eingänge</span><strong>{number.format(summary.receivedAmount)} GIBB</strong><small>in {number.format(transactions.filter((transaction) => transaction.receiver_user_id === userId).length)} Buchungen</small></div>
        <div><span>Aktive Tage</span><strong>{number.format(summary.activeDays)}</strong><small>mit mindestens einer Bewegung</small></div>
      </div>
      {offline && <p className="home-stats-note" role="note">Diese Werte stammen aus dem zuletzt gespeicherten Verlauf und können unvollständig sein.</p>}
    </section>
  );
}
