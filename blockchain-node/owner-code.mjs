// Zweiter Faktor für Full-Konten: pro Konto ein 6-stelliger Code, der alle 5 Minuten wechselt.
// Die Hauptseite zeigt ihn angemeldeten Full-Ownern an (POST /api/owner-code). Der geheime Schlüssel
// liegt nur auf dem Server (Datei neben chain.json); ohne ihn lässt sich kein Code berechnen.
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

export const CODE_WINDOW_MS = 5 * 60 * 1000;

export function createOwnerCodes({ file, now = () => Date.now() } = {}) {
  let secret = "";
  try { secret = readFileSync(file, "utf8").trim(); } catch { /* neu erzeugen */ }
  if (!/^[0-9a-f]{64}$/.test(secret)) {
    secret = randomBytes(32).toString("hex");
    if (file) { try { writeFileSync(file, secret, { mode: 0o600 }); } catch { /* nur im Speicher */ } }
  }
  const codeFor = (userId, window) => {
    const n = Number.parseInt(createHmac("sha256", secret).update(`${userId}:${window}`).digest("hex").slice(0, 12), 16);
    return String(n % 1_000_000).padStart(6, "0");
  };
  return {
    // Aktueller Code und wann der nächste kommt
    current(userId) {
      const window = Math.floor(now() / CODE_WINDOW_MS);
      return { code: codeFor(userId, window), validUntil: (window + 1) * CODE_WINDOW_MS, serverTime: now() };
    },
    // Gültig: aktueller Code oder der vorherige (damit ein Code kurz vor dem Wechsel noch klappt)
    check(userId, code) {
      if (!userId || typeof code !== "string" || !/^\d{6}$/.test(code.trim())) return false;
      const given = Buffer.from(code.trim());
      const window = Math.floor(now() / CODE_WINDOW_MS);
      return [window, window - 1].some((w) => timingSafeEqual(Buffer.from(codeFor(userId, w)), given));
    },
  };
}
