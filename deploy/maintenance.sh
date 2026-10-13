#!/usr/bin/env bash
# Website vorübergehend offline nehmen (Wartungsseite) – die Chain-Seite bleibt erreichbar.
#   sudo gibb-wartung an                         -> offline, bis du sie wieder einschaltest
#   sudo gibb-wartung an 30m                     -> 30 Minuten offline, danach automatisch online
#   sudo gibb-wartung an 2h "Neue Version kommt" -> 2 Stunden, mit Nachricht auf der Wartungsseite
#   sudo gibb-wartung an 0 "Wir sind bald zurück"-> ohne Zeitlimit, aber mit Nachricht
#   sudo gibb-wartung aus                        -> sofort wieder online
#   sudo gibb-wartung                            -> aktuellen Zustand anzeigen
# Dauer: Zahl mit m (Minuten), h (Stunden) oder d (Tagen); eine Zahl ohne Einheit = Minuten.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
FLAG=/var/lib/gibbcoin/maintenance
mkdir -p /var/lib/gibbcoin

status() {
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    if (!fs.existsSync(f)) { console.log("Website ist ONLINE."); process.exit(0); }
    let i = {}; try { const t = fs.readFileSync(f, "utf8").trim(); if (t) i = JSON.parse(t); } catch {}
    const until = i.until ? Date.parse(i.until) : NaN;
    if (Number.isFinite(until) && until <= Date.now()) { console.log("Website ist ONLINE (Wartungszeit abgelaufen)."); process.exit(0); }
    console.log("Website ist OFFLINE (Wartung).");
    if (Number.isFinite(until)) console.log("  Automatisch wieder online: " + new Date(until).toLocaleString("de-CH", { timeZone: "Europe/Zurich" }) + " (in ca. " + Math.ceil((until - Date.now()) / 60000) + " Min.)");
    else console.log("  Ohne Zeitlimit – mit \"sudo gibb-wartung aus\" wieder einschalten.");
    if (i.message) console.log("  Nachricht: " + i.message);
  ' "$FLAG"
}

case "${1:-status}" in
  an|on)
    DURATION="${2:-0}"
    MESSAGE="${3:-}"
    node -e '
      const [f, d, msg] = process.argv.slice(1);
      const m = String(d).trim().match(/^(\d+(?:[.,]\d+)?)\s*([mhd]?)$/i);
      if (!m) { console.error("Dauer nicht verstanden: " + d + " (Beispiele: 30m, 2h, 1d, 0)"); process.exit(1); }
      const n = Number(m[1].replace(",", ".")); const unit = (m[2] || "m").toLowerCase();
      const ms = n * (unit === "d" ? 86400000 : unit === "h" ? 3600000 : 60000);
      const info = { message: String(msg || "").slice(0, 500) };
      if (ms > 0) info.until = new Date(Date.now() + ms).toISOString();
      require("fs").writeFileSync(f, JSON.stringify(info));
    ' "$FLAG" "$DURATION" "$MESSAGE"
    chmod 644 "$FLAG"
    status
    ;;
  aus|off) rm -f "$FLAG"; echo "Website ist wieder ONLINE." ;;
  *) status ;;
esac
