// Gateway: führt Website, Blockchain-Node und die eigene Supabase-Instanz unter EINER Adresse zusammen.
//   /node/...  -> Blockchain-Node (NODE_TARGET, Präfix /node wird entfernt)
//   /sb/...    -> selbst gehostetes Supabase (SUPABASE_TARGET = Kong, Präfix /sb wird entfernt)
//   alles andere -> GibbCoin-Website (WEBSITE_TARGET)
// WebSockets (Supabase Realtime) werden ebenfalls weitergereicht.
// Start: node deploy/gateway.mjs   (Port über GATEWAY_PORT, Standard 8080)
import { createServer, request } from "node:http";
import { connect } from "node:net";
import { existsSync, readFileSync, unlinkSync } from "node:fs";

const PORT = Number(process.env.GATEWAY_PORT ?? 8080);
const WEBSITE = new URL(process.env.WEBSITE_TARGET ?? "http://127.0.0.1:3000");
const NODE = new URL(process.env.NODE_TARGET ?? "http://127.0.0.1:80");
const SUPABASE = new URL(process.env.SUPABASE_TARGET ?? "http://127.0.0.1:8000");
// Wartungsmodus: Existiert diese Datei, ist die Website vorübergehend offline (deploy/maintenance.sh).
const MAINTENANCE_FILE = process.env.MAINTENANCE_FILE ?? "/var/lib/gibbcoin/maintenance";
// Datei-Inhalt (optional, JSON): { "until": "<ISO-Zeit>", "message": "<Text>" }. Leer = unbegrenzt.
// Ist "until" vorbei, ist die Website automatisch wieder online (Datei wird entfernt).
function maintenanceState() {
  if (!existsSync(MAINTENANCE_FILE)) return null;
  let info = {};
  try { const text = readFileSync(MAINTENANCE_FILE, "utf8").trim(); if (text) info = JSON.parse(text); } catch { info = {}; }
  const until = info.until ? Date.parse(info.until) : NaN;
  if (Number.isFinite(until) && until <= Date.now()) {
    try { unlinkSync(MAINTENANCE_FILE); } catch { /* bleibt einfach liegen */ }
    return null;
  }
  return { until: Number.isFinite(until) ? new Date(until).toISOString() : null, message: typeof info.message === "string" ? info.message.slice(0, 500) : "" };
}
const escapeHtml = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
function maintenancePage(state) {
  const message = state.message ? `<p class="msg">${escapeHtml(state.message)}</p>` : "";
  const eta = state.until ? `<div class="timer" id="eta" data-until="${state.until}"><span>Website wieder online in</span><strong id="etaLeft">–</strong><small>ca. um <b id="etaTime"></b></small></div>` : "";
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GIBB Coin – Wartung</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#0f1115;color:#e8eaf0;text-align:center;padding:16px}main{max-width:520px}h1{font-size:24px;margin:0 0 8px}p{color:#9aa3b2;margin:0 0 10px}.msg{color:#e8eaf0;background:#171b22;border:1px solid #2a303b;border-radius:12px;padding:12px 14px;white-space:pre-wrap}.timer{margin:18px auto;padding:16px 18px;border:1px solid rgba(117,245,154,.3);border-radius:16px;background:rgba(117,245,154,.06);max-width:320px}.timer span{display:block;color:#9aa3b2;font-size:13px}.timer strong{display:block;font-size:44px;line-height:1.15;color:#75f59a;font-variant-numeric:tabular-nums;letter-spacing:-.02em}.timer small{color:#9aa3b2}.timer b{color:#e8eaf0}</style></head>
<body><main><h1>GIBB Coin ist kurz offline</h1><p>Wir führen gerade Wartungsarbeiten durch.</p>${message}${eta}<p>Die Seite lädt automatisch neu, sobald sie wieder online ist.</p></main>
<script>
const el = document.getElementById("eta");
const until = el ? Date.parse(el.dataset.until) : NaN;
// Live-Countdown (z. B. 19:42), bei mehr als einer Stunde mit Stunden (1:05:09).
const pad = (n) => String(n).padStart(2, "0");
function tick() {
  if (!Number.isFinite(until)) return;
  document.getElementById("etaTime").textContent = new Date(until).toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit" });
  const left = Math.max(0, Math.ceil((until - Date.now()) / 1000));
  const h = Math.floor(left / 3600), m = Math.floor((left % 3600) / 60), sec = left % 60;
  document.getElementById("etaLeft").textContent = left === 0 ? "gleich …" : h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : pad(m) + ":" + pad(sec);
}
tick(); setInterval(tick, 1000);
// Zurück zur Website, sobald die Wartung vorbei ist – ohne selbst neu laden zu müssen.
let leaving = false;
async function check() {
  if (leaving) return;
  try {
    const s = await fetch("/__status?t=" + Date.now(), { cache: "no-store" }).then((r) => r.json());
    if (!s.maintenance) { leaving = true; location.replace(location.pathname + location.search + location.hash); }
  } catch {}
}
setInterval(check, 5000);
if (Number.isFinite(until)) setTimeout(check, Math.max(1000, until - Date.now() + 1500));
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") check(); });
window.addEventListener("focus", check);
window.addEventListener("online", check);
</script></body></html>`;
}

function route(url) {
  for (const [prefix, target] of [["/node", NODE], ["/sb", SUPABASE]]) {
    if (url === prefix || url.startsWith(`${prefix}/`) || url.startsWith(`${prefix}?`)) {
      const rest = url.slice(prefix.length);
      return { target, path: rest.startsWith("/") ? rest : `/${rest}`, label: prefix };
    }
  }
  return { target: WEBSITE, path: url, label: "/" };
}

const server = createServer((req, res) => {
  // Status für offene Browser-Tabs: im Wartungsmodus melden sie sich selbst ab.
  if (req.url === "/__status" || req.url.startsWith("/__status?")) {
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    const state = maintenanceState();
    res.end(JSON.stringify({ maintenance: Boolean(state), until: state?.until ?? null, message: state?.message ?? "" }));
    return;
  }
  const maintenance = maintenanceState();
  if (maintenance) {
    const retry = maintenance.until ? Math.max(30, Math.round((Date.parse(maintenance.until) - Date.now()) / 1000)) : 600;
    res.writeHead(503, { "content-type": "text/html; charset=utf-8", "retry-after": String(retry), "cache-control": "no-store" });
    res.end(maintenancePage(maintenance));
    return;
  }
  const { target, path, label } = route(req.url);
  const upstream = request({
    hostname: target.hostname, port: target.port, method: req.method, path,
    headers: { ...req.headers, host: target.host, "x-forwarded-prefix": label === "/" ? "" : label, "x-forwarded-for": req.headers["x-forwarded-for"] || req.headers["cf-connecting-ip"] || req.socket.remoteAddress || "gateway" },
  }, (up) => { res.writeHead(up.statusCode ?? 502, up.headers); up.pipe(res); });
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    res.end(`Dienst hinter ${label} nicht erreichbar`);
  });
  req.pipe(upstream);
});

// WebSocket-Upgrades roh an das Ziel durchreichen (z. B. /sb/realtime/v1/websocket).
server.on("upgrade", (req, socket, head) => {
  if (maintenanceState()) { socket.destroy(); return; }
  const { target, path } = route(req.url);
  const upstream = connect(Number(target.port || 80), target.hostname, () => {
    const headers = { ...req.headers, host: target.host, "x-forwarded-for": req.headers["x-forwarded-for"] || req.headers["cf-connecting-ip"] || req.socket.remoteAddress || "gateway" };
    const lines = [`${req.method} ${path} HTTP/${req.httpVersion}`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`)];
    upstream.write(`${lines.join("\r\n")}\r\n\r\n`);
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  const close = () => { socket.destroy(); upstream.destroy(); };
  upstream.on("error", close);
  socket.on("error", close);
});

server.listen(PORT, () => console.log(`GIBB Gateway auf Port ${PORT}: /node -> ${NODE.href}, /sb -> ${SUPABASE.href}, Rest -> ${WEBSITE.href}`));
