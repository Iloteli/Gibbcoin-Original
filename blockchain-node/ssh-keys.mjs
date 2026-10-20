// Öffentliche SSH-Schlüssel für die Anmeldung am Server ohne Passwort.
// Die Chain-Seite speichert pro Konto einen öffentlichen Schlüssel. Der Owner schaltet sie
// auf dem Server mit "gibb-ssh-keys" frei (schreibt einen eigenen Block in ~/.ssh/authorized_keys).

const KEY_RE = /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com) ([A-Za-z0-9+/]{40,8000}={0,3})(?:\s.*)?$/;
export const BLOCK_START = "# >>> gibb-chain (automatisch von gibb-ssh-keys, nicht von Hand ändern)";
export const BLOCK_END = "# <<< gibb-chain";

// Nur "typ base64" übernehmen (Kommentar und Optionen fallen weg). Der Typ muss auch im Schlüssel stehen.
export function parsePublicKey(text) {
  const line = String(text ?? "").trim().split(/\r?\n/)[0].trim();
  const m = KEY_RE.exec(line);
  if (!m) throw new Error("invalid_ssh_key");
  const raw = Buffer.from(m[2], "base64");
  if (raw.length < 8) throw new Error("invalid_ssh_key");
  const len = raw.readUInt32BE(0);
  if (len > raw.length - 4 || raw.subarray(4, 4 + len).toString("latin1") !== m[1]) throw new Error("invalid_ssh_key");
  return `${m[1]} ${m[2]}`;
}

// Name als Kommentar hinter dem Schlüssel (nur harmlose Zeichen)
export const keyLabel = (name) => String(name ?? "").toLowerCase().replace(/[^a-z0-9._-]/g, "").slice(0, 40) || "konto";

// Bestehende authorized_keys behalten, nur den gibb-Block ersetzen (leer = Block entfernen).
export function mergeAuthorizedKeys(existing, entries) {
  const lines = String(existing ?? "").split(/\r?\n/);
  const kept = [];
  let inside = false;
  for (const line of lines) {
    if (line === BLOCK_START) { inside = true; continue; }
    if (line === BLOCK_END) { inside = false; continue; }
    if (!inside) kept.push(line);
  }
  while (kept.length && kept[kept.length - 1] === "") kept.pop();
  const keys = [];
  for (const e of entries ?? []) {
    try { keys.push(`${parsePublicKey(e.key)} gibb:${keyLabel(e.name)}`); } catch { /* ungültig: weglassen */ }
  }
  const block = keys.length ? [BLOCK_START, ...new Set(keys), BLOCK_END] : [];
  const out = [...kept, ...block];
  return out.length ? `${out.join("\n")}\n` : "";
}
