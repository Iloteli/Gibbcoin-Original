// Gateway: führt Website und Blockchain-Node unter EINER Adresse zusammen.
//   /node/...  -> Blockchain-Node (NODE_TARGET, Präfix /node wird entfernt)
//   alles andere -> GibbCoin-Website (WEBSITE_TARGET)
// Start: node deploy/gateway.mjs   (Port über GATEWAY_PORT, Standard 8080)
import { createServer, request } from "node:http";

const PORT = Number(process.env.GATEWAY_PORT ?? 8080);
const WEBSITE = new URL(process.env.WEBSITE_TARGET ?? "http://127.0.0.1:3000");
const NODE = new URL(process.env.NODE_TARGET ?? "http://127.0.0.1:80");

createServer((req, res) => {
  const toNode = req.url === "/node" || req.url.startsWith("/node/") || req.url.startsWith("/node?");
  const target = toNode ? NODE : WEBSITE;
  const path = toNode ? (req.url.slice("/node".length) || "/") : req.url;
  const upstream = request({
    hostname: target.hostname, port: target.port, method: req.method, path,
    headers: { ...req.headers, host: target.host },
  }, (up) => { res.writeHead(up.statusCode ?? 502, up.headers); up.pipe(res); });
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    res.end(toNode ? "Blockchain-Node nicht erreichbar" : "Website nicht erreichbar");
  });
  req.pipe(upstream);
}).listen(PORT, () => console.log(`GIBB Gateway auf Port ${PORT}: /node -> ${NODE.href}, Rest -> ${WEBSITE.href}`));
