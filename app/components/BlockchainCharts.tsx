"use client";

import type { Block } from "../lib/types";

type Miner = { user_id: string; label: string; blocks: number; reward: number };

// Kleines SVG-Liniendiagramm ohne Bibliothek. Werte von alt nach neu.
export function LineChart({ values, label, unit, target }: { values: number[]; label: string; unit: string; target?: number | null }) {
  const width = 320;
  const height = 96;
  const pad = 6;
  if (values.length < 2) {
    return <div className="chain-chart empty"><span>{label}</span><small>Noch zu wenige Blöcke für ein Diagramm.</small></div>;
  }
  const max = Math.max(...values, target ?? 0) * 1.1 || 1;
  const min = Math.min(...values, target ?? Infinity, 0);
  const x = (i: number) => pad + (i / (values.length - 1)) * (width - pad * 2);
  const y = (v: number) => height - pad - ((v - min) / (max - min || 1)) * (height - pad * 2);
  const points = values.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const area = `${pad},${height - pad} ${points} ${width - pad},${height - pad}`;
  const last = values[values.length - 1];
  const avg = values.reduce((sum, v) => sum + v, 0) / values.length;
  return (
    <figure className="chain-chart">
      <figcaption><span>{label}</span><strong>{formatValue(last)} {unit}</strong><small>Ø {formatValue(avg)} {unit}</small></figcaption>
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${label}: zuletzt ${formatValue(last)} ${unit}, Durchschnitt ${formatValue(avg)} ${unit}`} preserveAspectRatio="none">
        {target ? <line className="chain-chart-target" x1={pad} x2={width - pad} y1={y(target)} y2={y(target)} /> : null}
        <polygon className="chain-chart-area" points={area} />
        <polyline className="chain-chart-line" points={points} />
        <circle className="chain-chart-dot" cx={x(values.length - 1)} cy={y(last)} r="3.5" />
      </svg>
      {target ? <small className="chain-chart-legend">gestrichelt = Ziel {formatValue(target)} {unit}</small> : null}
    </figure>
  );
}

function formatValue(value: number) {
  return value >= 100 ? Math.round(value).toLocaleString("de-CH") : value.toLocaleString("de-CH", { maximumFractionDigits: 1 });
}

export function BlockchainCharts({ blocks, targetSeconds }: { blocks: Block[]; targetSeconds: number | null | undefined }) {
  // blocks kommen neu → alt; für die Diagramme alt → neu, ohne Genesis.
  const ordered = blocks.filter((block) => block.height > 0).slice().sort((a, b) => a.height - b.height);
  const difficulty = ordered.map((block) => block.difficulty_bits);
  const blockTimes: number[] = [];
  for (let i = 1; i < ordered.length; i += 1) {
    const seconds = (new Date(ordered[i].mined_at).getTime() - new Date(ordered[i - 1].mined_at).getTime()) / 1000;
    if (seconds >= 0 && Number.isFinite(seconds)) blockTimes.push(seconds);
  }
  const txPerBlock = ordered.map((block) => block.tx_count);
  return (
    <section className="card card-pad chain-charts" aria-label="Verlauf">
      <div className="card-head"><h2>Verlauf</h2><span>letzte {ordered.length} Blöcke</span></div>
      <div className="chain-chart-grid">
        <LineChart values={blockTimes} label="Blockzeit" unit="s" target={targetSeconds ?? null} />
        <LineChart values={difficulty} label="Schwierigkeit" unit="Bit" />
        <LineChart values={txPerBlock} label="Transaktionen pro Block" unit="Tx" />
      </div>
    </section>
  );
}

export function MinerLeaderboard({ miners, userId, myBlocks }: { miners: Miner[]; userId: string; myBlocks: number | null | undefined }) {
  const total = miners.reduce((sum, miner) => sum + miner.blocks, 0) || 1;
  const me = miners.find((miner) => miner.user_id === userId);
  const myRank = me ? miners.indexOf(me) + 1 : null;
  return (
    <div className="chain-leaderboard">
      <div className="chain-me">
        <div><span>Deine Blöcke</span><strong>{myBlocks ?? 0}</strong></div>
        <div><span>Dein Rang</span><strong>{myRank ? `#${myRank}` : "–"}</strong></div>
        <div><span>Verdient</span><strong>{me ? `${me.reward.toLocaleString("de-CH")} GIBB` : "0 GIBB"}</strong></div>
      </div>
      {miners.length === 0 ? <div className="empty">Noch niemand hat einen Block gefunden – sei die erste Person!</div> : (
        <ol className="chain-ranks">
          {miners.map((miner, index) => (
            <li key={miner.user_id} className={miner.user_id === userId ? "you" : ""}>
              <span className={`rank rank-${index + 1}`}>{index < 3 ? ["🥇", "🥈", "🥉"][index] : index + 1}</span>
              <div className="chain-rank-main">
                <strong>{miner.label}{miner.user_id === userId ? " (du)" : ""}</strong>
                <i style={{ width: `${Math.max(4, Math.round((miner.blocks / total) * 100))}%` }} aria-hidden="true" />
              </div>
              <span className="chain-rank-stats"><b>{miner.blocks}</b> Blöcke · {miner.reward.toLocaleString("de-CH")} GIBB</span>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
