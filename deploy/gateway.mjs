// Gateway: führt Website, Blockchain-Node und die eigene Supabase-Instanz unter EINER Adresse zusammen.
//   /node/...  -> Blockchain-Node (NODE_TARGET, Präfix /node wird entfernt)
//   /sb/...    -> selbst gehostetes Supabase (SUPABASE_TARGET = Kong, Präfix /sb wird entfernt)
//   alles andere -> GibbCoin-Website (WEBSITE_TARGET)
// WebSockets (Supabase Realtime) werden ebenfalls weitergereicht.
// Start: node deploy/gateway.mjs   (Port über GATEWAY_PORT, Standard 8080)
import { createServer, request } from "node:http";
import { connect } from "node:net";
import { existsSync } from "node:fs";

const PORT = Number(process.env.GATEWAY_PORT ?? 8080);
const WEBSITE = new URL(process.env.WEBSITE_TARGET ?? "http://127.0.0.1:3000");
const NODE = new URL(process.env.NODE_TARGET ?? "http://127.0.0.1:80");
const SUPABASE = new URL(process.env.SUPABASE_TARGET ?? "http://127.0.0.1:8000");
// Wartungsmodus: Existiert diese Datei, ist die Website vorübergehend offline (deploy/maintenance.sh).
const MAINTENANCE_FILE = process.env.MAINTENANCE_FILE ?? "/var/lib/gibbcoin/maintenance";
const MAINTENANCE_PAGE = `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GIBB Coin – Wartung</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#0f1115;color:#e8eaf0;text-align:center;padding:16px}h1{font-size:24px;margin:0 0 8px}p{color:#9aa3b2;margin:0}</style></head>
<body><main><h1>GIBB Coin ist kurz offline</h1><p>Wir führen gerade Wartungsarbeiten durch. Bitte versuche es später nochmals.</p></main></body></html>`;

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
    res.end(JSON.stringify({ maintenance: existsSync(MAINTENANCE_FILE) }));
    return;
  }
  if (existsSync(MAINTENANCE_FILE)) {
    res.writeHead(503, { "content-type": "text/html; charset=utf-8", "retry-after": "600", "cache-control": "no-store" });
    res.end(MAINTENANCE_PAGE);
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
  if (existsSync(MAINTENANCE_FILE)) { socket.destroy(); return; }
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
