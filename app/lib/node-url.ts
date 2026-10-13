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

// Gespeicherte Node-Adresse (localStorage "gibb-node-url"), aber nur wenn sie zur Seite passt:
// Auf einer HTTPS-Seite wird eine http://-Adresse ignoriert – der Browser würde sie als
// "gemischte Inhalte" blockieren und die Verbindung als unsicher markieren.
export function preferredNodeUrl(): string {
  const fallback = defaultNodeUrl();
  try {
    const stored = window.localStorage.getItem("gibb-node-url");
    if (!stored) return fallback;
    if (window.location.protocol === "https:" && stored.startsWith("http:")) {
      window.localStorage.removeItem("gibb-node-url");
      return fallback;
    }
    return stored;
  } catch {
    return fallback;
  }
}
