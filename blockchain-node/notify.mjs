// Push-Benachrichtigungen für den Owner über ntfy (kostenlose App für Handy und PC, kein Konto nötig).
// Gemeldet werden: neue Banküberweisungen, neue Support-Fälle und Neustarts des Servers.
// Das Thema (topic) ist wie ein Passwort: wer es kennt, liest mit. Es steht deshalb nur in
// notify.json neben der Chain-Datei und nie in den öffentlichen Einstellungen.
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { randomBytes } from "node:crypto";

const TOPIC_RE = /^[A-Za-z0-9_-]{12,64}$/;
const DEFAULTS = { enabled: false, server: "https://ntfy.sh", topic: "", bank: true, support: true, start: true };

export function createNotifier({ file, fetchImpl = globalThis.fetch, note = () => {} } = {}) {
  let config = { ...DEFAULTS };
  try { config = { ...DEFAULTS, ...JSON.parse(readFileSync(file, "utf8")) }; } catch { /* noch nicht eingerichtet */ }
  let lastError = "";
  let lastSent = 0;

  const save = () => {
    const tmp = `${file}.tmp`;
    writeFileSync(tmp, JSON.stringify(config, null, 2));
    renameSync(tmp, file);
  };

  const get = () => ({ ...config, lastError, lastSent });

  const set = (patch = {}) => {
    const next = { ...config };
    if (typeof patch.enabled === "boolean") next.enabled = patch.enabled;
    for (const k of ["bank", "support", "start"]) if (typeof patch[k] === "boolean") next[k] = patch[k];
    if (patch.server !== undefined) {
      const server = String(patch.server).trim().replace(/\/+$/, "");
      if (!/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(server)) throw new Error("invalid_notify_server");
      next.server = server;
    }
    if (patch.newTopic === true) next.topic = `gibb-${randomBytes(12).toString("hex")}`;
    else if (patch.topic !== undefined) {
      const topic = String(patch.topic).trim();
      if (!TOPIC_RE.test(topic)) throw new Error("invalid_notify_topic");
      next.topic = topic;
    }
    if (next.enabled && !next.topic) next.topic = `gibb-${randomBytes(12).toString("hex")}`;
    config = next;
    save();
    return get();
  };

  // kind: "bank" | "support" | "start" | "test"
  const send = async (kind, title, message, { priority = 3, tags = [] } = {}) => {
    if (!config.enabled || !config.topic || !fetchImpl) return { ok: false, skipped: true };
    if (kind !== "test" && config[kind] === false) return { ok: false, skipped: true };
    try {
      const res = await fetchImpl(config.server, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ topic: config.topic, title: String(title).slice(0, 120), message: String(message).slice(0, 500), priority, tags }),
        signal: AbortSignal.timeout(8000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      lastError = "";
      lastSent = Date.now();
      return { ok: true };
    } catch (error) {
      lastError = String(error?.message ?? error).slice(0, 120);
      note("settings", `Benachrichtigung fehlgeschlagen: ${lastError}`);
      return { ok: false, error: lastError };
    }
  };

  // Neue Einträge melden: beim ersten Durchlauf nur merken, danach jede neue ID einmal melden.
  const watch = (list, { kind, intervalMs = 60_000, idOf = (x) => x.id, format }) => {
    let seen = null;
    const tick = async () => {
      if (!config.enabled || config[kind] === false) { seen = null; return; }
      let items;
      try { items = await list(); } catch { return; }
      if (!Array.isArray(items)) return;
      const ids = new Set(items.map(idOf));
      if (seen) for (const item of items) if (!seen.has(idOf(item))) { const m = format(item); await send(kind, m.title, m.message, m); }
      seen = ids;
    };
    const timer = setInterval(() => void tick(), intervalMs);
    timer.unref?.();
    setTimeout(() => void tick(), 5000).unref?.();
    return { tick, stop: () => clearInterval(timer) };
  };

  return { get, set, send, watch };
}
