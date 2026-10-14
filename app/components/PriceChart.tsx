"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabase } from "../lib/supabase";

export type PricePoint = { t: string; p: number; k?: string; n?: number };
type Range = "24h" | "7d" | "all";

const RANGES: Array<{ key: Range; label: string; ms: number }> = [
  { key: "24h", label: "24 h", ms: 86_400_000 },
  { key: "7d", label: "7 Tage", ms: 7 * 86_400_000 },
  { key: "all", label: "Alles", ms: Infinity },
];
const rp = (v: number) => `${v.toLocaleString("de-CH", { minimumFractionDigits: 2, maximumFractionDigits: 3 })} Rp`;
const when = (t: number) => new Date(t).toLocaleString("de-CH", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });

// Kursverlauf mit Zeitraum-Auswahl und Anzeige beim Überfahren/Antippen.
export function PriceChart({ history, price, height = 180 }: { history: PricePoint[]; price: number; height?: number }) {
  const [range, setRange] = useState<Range>("7d");
  const [hover, setHover] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement | null>(null);
  const boxRef = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(600);
  // Echte Breite messen, damit Punkte rund bleiben und die Linie nicht verzerrt wird
  useEffect(() => {
    const el = boxRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(([entry]) => { const w = Math.round(entry.contentRect.width); if (w > 0) setWidth(w); });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const points = useMemo(() => {
    const all = history.map((h) => ({ t: new Date(h.t).getTime(), p: Number(h.p), k: h.k, n: h.n })).filter((h) => Number.isFinite(h.t) && Number.isFinite(h.p));
    const ms = RANGES.find((r) => r.key === range)?.ms ?? Infinity;
    const now = Date.now();
    const inRange = all.filter((h) => now - h.t <= ms);
    // Kurs am Anfang des Zeitraums (letzter Handel davor) und jetzt, damit die Linie den ganzen Zeitraum zeigt
    const before = all.filter((h) => now - h.t > ms).slice(-1)[0];
    const list = [...(before && ms !== Infinity ? [{ ...before, t: now - ms }] : []), ...inRange];
    if (list.length) list.push({ t: now, p: price, k: "now", n: 0 });
    return list;
  }, [history, range, price]);

  const pad = { l: 8, r: 8, t: 14, b: 14 };
  const enough = points.length >= 2;
  const minT = enough ? points[0].t : 0;
  const maxT = enough ? points[points.length - 1].t : 1;
  const ps = points.map((p) => p.p);
  const lo = enough ? Math.min(...ps) : 0;
  const hi = enough ? Math.max(...ps) : 1;
  const span = hi - lo || Math.max(hi * 0.1, 0.01);
  const x = (t: number) => pad.l + ((t - minT) / (maxT - minT || 1)) * (width - pad.l - pad.r);
  const y = (v: number) => pad.t + (1 - (v - (lo - span * 0.15)) / (span * 1.3)) * (height - pad.t - pad.b);
  // Stufenlinie: der Kurs bleibt bis zum nächsten Handel gleich
  const line = points.map((p, i) => (i === 0 ? `M${x(p.t).toFixed(1)},${y(p.p).toFixed(1)}` : `H${x(p.t).toFixed(1)}V${y(p.p).toFixed(1)}`)).join("");
  const area = enough ? `${line}V${height - pad.b}H${x(minT).toFixed(1)}Z` : "";
  const first = points[0]?.p ?? price;
  const change = first ? ((price - first) / first) * 100 : 0;
  const trend = change > 0.0001 ? "up" : change < -0.0001 ? "down" : "flat";

  useEffect(() => setHover(null), [range]);

  const onMove = (clientX: number) => {
    const svg = svgRef.current;
    if (!svg || !enough) return;
    const box = svg.getBoundingClientRect();
    const t = minT + ((clientX - box.left) / box.width * width - pad.l) / (width - pad.l - pad.r) * (maxT - minT);
    let best = 0;
    for (let i = 0; i < points.length; i += 1) if (points[i].t <= t) best = i;
    setHover(best);
  };
  const hp = hover !== null ? points[hover] : null;

  return (
    <figure className={`price-chart trend-${trend}`}>
      <div className="price-chart-head">
        <div>
          <strong>{rp(hp ? hp.p : price)}</strong>
          <small className={`price-chart-change ${trend}`}>{hp ? when(hp.t) : `${trend === "up" ? "▲" : trend === "down" ? "▼" : "■"} ${Math.abs(change).toFixed(2)} % · ${RANGES.find((r) => r.key === range)?.label}`}</small>
        </div>
        <div className="price-chart-ranges" role="group" aria-label="Zeitraum">
          {RANGES.map((r) => <button key={r.key} type="button" className={range === r.key ? "active" : ""} aria-pressed={range === r.key} onClick={() => setRange(r.key)}>{r.label}</button>)}
        </div>
      </div>
      <div ref={boxRef} className="price-chart-box">
      {enough ? (
        <svg
          ref={svgRef}
          key={range}
          viewBox={`0 0 ${width} ${height}`}
          style={{ height }}
          preserveAspectRatio="none"
          role="img"
          aria-label={`Kursverlauf ${RANGES.find((r) => r.key === range)?.label}: von ${rp(first)} auf ${rp(price)}`}
          onMouseMove={(e) => onMove(e.clientX)}
          onMouseLeave={() => setHover(null)}
          onTouchStart={(e) => onMove(e.touches[0].clientX)}
          onTouchMove={(e) => onMove(e.touches[0].clientX)}
          onTouchEnd={() => setHover(null)}
        >
          <defs>
            <linearGradient id="priceFill" x1="0" x2="0" y1="0" y2="1">
              <stop offset="0%" className="price-chart-stop-top" />
              <stop offset="100%" className="price-chart-stop-bottom" />
            </linearGradient>
          </defs>
          <path className="price-chart-area" d={area} fill="url(#priceFill)" />
          <path className="price-chart-line" d={line} pathLength={1} />
          {hp && <line className="price-chart-cursor" x1={x(hp.t)} x2={x(hp.t)} y1={pad.t} y2={height - pad.b} />}
          <circle className="price-chart-dot" cx={x(hp ? hp.t : maxT)} cy={y(hp ? hp.p : price)} r="5" />
        </svg>
      ) : (
        <div className="price-chart-empty" style={{ height }}>In diesem Zeitraum gab es noch keinen Handel.</div>
      )}
      </div>
      <figcaption className="price-chart-foot"><span>Tief {enough ? rp(lo) : "–"}</span><span>Hoch {enough ? rp(hi) : "–"}</span><span>{Math.max(points.length - 1, 0)} Kurspunkte</span></figcaption>
    </figure>
  );
}

type MarketSnapshot = { price: number; price_24h_ago: number; volume_24h: number; history: PricePoint[] };

// Kurs-Karte für Home: lädt den Markt selbst und führt zum Markt-Tab.
export function HomePriceCard({ onOpenMarket }: { onOpenMarket?: () => void }) {
  const [state, setState] = useState<MarketSnapshot | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let alive = true;
    const load = async () => {
      const supabase = getSupabase();
      if (!supabase) return;
      const { data, error } = await supabase.rpc("get_market_state");
      if (!alive) return;
      if (error || !data) { setFailed(true); return; }
      setFailed(false);
      setState(data as MarketSnapshot);
    };
    void load();
    const timer = window.setInterval(() => { if (document.visibilityState === "visible") void load(); }, 60_000);
    return () => { alive = false; window.clearInterval(timer); };
  }, []);

  if (failed && !state) return null;
  return (
    <section className="card card-pad home-price-card" aria-labelledby="home-price-title">
      <div className="card-head">
        <h2 id="home-price-title">GIBB-Kurs</h2>
        <span>{state ? `Volumen 24 h: ${Number(state.volume_24h ?? 0).toLocaleString("de-CH")} GIBB` : "Wird geladen …"}</span>
      </div>
      {state ? <PriceChart history={state.history ?? []} price={Number(state.price)} height={150} /> : <div className="price-chart-empty skeleton" style={{ height: 150 }} />}
      {onOpenMarket && <button type="button" className="secondary compact home-price-open" onClick={onOpenMarket}>Zum Markt →</button>}
    </section>
  );
}
