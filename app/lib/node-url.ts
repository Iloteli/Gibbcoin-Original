// Standard-Adresse des Blockchain-Nodes.
// - Website mit eigenem Port (z. B. http://192.168.1.5:3000): Node auf demselben Rechner, Port 8787.
// - Website ohne Port (Standard-Port 80/443, z. B. hinter dem Server-Gateway oder einem Tunnel):
//   der Node ist unter demselben Origin im Pfad /node erreichbar.
export function defaultNodeUrl(): string {
  if (typeof window === "undefined" || !window.location?.hostname) return "http://localhost:8787";
  const { protocol, hostname, port, origin } = window.location;
  if (port) return `${protocol}//${hostname}:8787`;
  return `${origin}/node`;
}
