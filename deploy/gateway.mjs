// Gateway: führt Website, Blockchain-Node und die eigene Supabase-Instanz unter EINER Adresse zusammen.
//   /node/...  -> Blockchain-Node (NODE_TARGET, Präfix /node wird entfernt)
//   /sb/...    -> selbst gehostetes Supabase (SUPABASE_TARGET = Kong, Präfix /sb wird entfernt)
//   alles andere -> GibbCoin-Website (WEBSITE_TARGET)
// WebSockets (Supabase Realtime) werden ebenfalls weitergereicht.
// Start: node deploy/gateway.mjs   (Port über GATEWAY_PORT, Standard 8080)
import { createServer, request } from "node:http";
import { connect } from "node:net";

const PORT = Number(process.env.GATEWAY_PORT ?? 8080);
const WEBSITE = new URL(process.env.WEBSITE_TARGET ?? "http://127.0.0.1:3000");
const NODE = new URL(process.env.NODE_TARGET ?? "http://127.0.0.1:80");
const SUPABASE = new URL(process.env.SUPABASE_TARGET ?? "http://127.0.0.1:8000");

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
