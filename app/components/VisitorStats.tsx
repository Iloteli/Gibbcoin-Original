"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { SITE_LABELS, type SiteKey } from "../lib/visitor-tracking";

type DayPoint = { day: string; unique_visitors: number; page_views: number };
type SiteRow = { site: SiteKey; unique_visitors: number; page_views: number };
type PageRow = { path: string; unique_visitors: number; page_views: number };

type VisitorStatsPayload = {
  range_days: number;
  first_visit_at: string | null;
  range_unique_visitors: number;
  range_page_views: number;
  total_unique_visitors: number;
  total_page_views: number;
  daily: DayPoint[];
  sites: SiteRow[];
  pages: PageRow[];
};

type RangeKey = "7" | "30" | "all";

const RANGE_DAYS: Record<RangeKey, number> = { "7": 7, "30": 30, all: 365 };
const numberFormat = new Intl.NumberFormat("de-CH");

function formatDay(day: string) {
  const parsed = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return day;
  return parsed.toLocaleDateString("de-CH", { day: "numeric", month: "short", timeZone: "UTC" });
}

function buildLine(points: number[], max: number, width: number, height: number) {
  if (points.length === 0) return "";
  if (points.length === 1) return `M 0 ${height - (max > 0 ? (points[0]! / max) * height : 0)} L ${width} ${height - (max > 0 ? (points[0]! / max) * height : 0)}`;
  const step = width / (points.length - 1);
  return points
    .map((value, index) => {
      const y = height - (max > 0 ? (value / max) * height : 0);
      return `${index === 0 ? "M" : "L"} ${(index * step).toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(" ");
}

export function VisitorStats({ active }: { active: boolean }) {
  const [range, setRange] = useState<RangeKey>("30");
  const [stats, setStats] = useState<VisitorStatsPayload | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    if (!active) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setLoading(true);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("admin_visitor_stats", { p_days: RANGE_DAYS[range] });
    setLoading(false);
    if (rpcError || !data) {
      setError(
        rpcError?.message?.includes("admin_required")
          ? "Für die Besucherstatistik fehlen dir die Adminrechte."
          : "Die Besucherstatistik ist noch nicht verfügbar. Wurde die Datenbank-Migration bereits ausgeführt?",
      );
      return;
    }
    setStats(data as VisitorStatsPayload);
  }, [active, range]);

  useEffect(() => {
    // Der Ladevorgang startet ausserhalb des Render-Durchlaufs.
    const start = globalThis.setTimeout(() => { void load(); }, 0);
    return () => globalThis.clearTimeout(start);
  }, [load]);

  const chart = useMemo(() => {
    const daily = stats?.daily ?? [];
    const views = daily.map((point) => Number(point.page_views) || 0);
    const visitors = daily.map((point) => Number(point.unique_visitors) || 0);
    const max = Math.max(1, ...views, ...visitors);
    return {
      daily,
      max,
      viewsPath: buildLine(views, max, 600, 160),
      visitorsPath: buildLine(visitors, max, 600, 160),
    };
  }, [stats]);

  const uniqueVisitors = range === "all" ? stats?.total_unique_visitors ?? 0 : stats?.range_unique_visitors ?? 0;
  const pageViews = range === "all" ? stats?.total_page_views ?? 0 : stats?.range_page_views ?? 0;

  return (
    <div className="visitor-stats">
      <div className="visitor-stats-head">
        <div>
          <strong>Besucher beider Webadressen</strong>
          <p>
            {stats?.first_visit_at
              ? `Gezählt seit ${new Date(stats.first_visit_at).toLocaleString("de-CH", { dateStyle: "short", timeStyle: "short" })}.`
              : "Die Zählung startet mit der ersten Veröffentlichung dieser Version."}{" "}
            Gezählt werden Browser je Adresse – dieselbe Person kann auf beiden Seiten erscheinen.
          </p>
        </div>
        <div className="visitor-range" role="tablist" aria-label="Zeitraum">
          <button type="button" role="tab" aria-selected={range === "7"} className={range === "7" ? "active" : ""} onClick={() => setRange("7")}>7 T.</button>
          <button type="button" role="tab" aria-selected={range === "30"} className={range === "30" ? "active" : ""} onClick={() => setRange("30")}>30 T.</button>
          <button type="button" role="tab" aria-selected={range === "all"} className={range === "all" ? "active" : ""} onClick={() => setRange("all")}>Gesamt</button>
        </div>
      </div>

      {error && <p className="visitor-error" role="alert">{error}</p>}

      <div className="visitor-kpis">
        <div><span>Eindeutige Besucher:innen</span><strong>{numberFormat.format(uniqueVisitors)}</strong></div>
        <div><span>Seitenaufrufe</span><strong>{numberFormat.format(pageViews)}</strong></div>
        <div><span>Gesamt seit Start</span><strong>{numberFormat.format(stats?.total_page_views ?? 0)}</strong></div>
      </div>

      <figure className="visitor-chart">
        <figcaption><strong>Traffic im Zeitverlauf</strong><small>Täglich</small></figcaption>
        <svg viewBox="0 0 600 180" role="img" aria-label="Verlauf der Besuche" preserveAspectRatio="none">
          <path d={chart.viewsPath} fill="none" stroke="#c084fc" strokeWidth="2" />
          <path d={chart.visitorsPath} fill="none" stroke="#38bdf8" strokeWidth="2" />
        </svg>
        <div className="visitor-axis">
          <span>{chart.daily[0] ? formatDay(chart.daily[0].day) : "–"}</span>
          <span>Maximum {numberFormat.format(chart.max)}</span>
          <span>{chart.daily.length > 0 ? formatDay(chart.daily[chart.daily.length - 1]!.day) : "–"}</span>
        </div>
        <div className="visitor-legend">
          <span className="visitors">Eindeutige Besucher:innen</span>
          <span className="views">Seitenaufrufe</span>
        </div>
      </figure>

      <table className="visitor-table">
        <thead><tr><th>Webadresse</th><th>Eindeutige Besucher:innen</th><th>Seitenaufrufe</th></tr></thead>
        <tbody>
          {(stats?.sites ?? []).map((row) => (
            <tr key={row.site}>
              <td>{SITE_LABELS[row.site] ?? row.site}</td>
              <td>{numberFormat.format(Number(row.unique_visitors) || 0)}</td>
              <td>{numberFormat.format(Number(row.page_views) || 0)}</td>
            </tr>
          ))}
          {(stats?.sites?.length ?? 0) === 0 && !loading && (
            <tr><td colSpan={3}>Noch keine Besuche erfasst.</td></tr>
          )}
        </tbody>
      </table>

      {(stats?.pages?.length ?? 0) > 0 && (
        <table className="visitor-table">
          <thead><tr><th>Top-Seiten</th><th>Eindeutige Besucher:innen</th><th>Seitenaufrufe</th></tr></thead>
          <tbody>
            {(stats?.pages ?? []).map((row) => (
              <tr key={row.path}>
                <td>{row.path}</td>
                <td>{numberFormat.format(Number(row.unique_visitors) || 0)}</td>
                <td>{numberFormat.format(Number(row.page_views) || 0)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <div className="visitor-actions">
        <button className="secondary compact" type="button" disabled={loading} onClick={() => void load()}>
          {loading ? "Lädt …" : "Aktualisieren"}
        </button>
      </div>
    </div>
  );
}
