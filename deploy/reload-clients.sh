#!/usr/bin/env bash
# Lädt die Hauptseite bei allen, die sie gerade offen haben, neu (innerhalb von ca. 5 Sekunden).
# Die Anmeldung bleibt erhalten.
#   sudo gibb-neuladen
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
mkdir -p /var/lib/gibbcoin
date +%s%N > /var/lib/gibbcoin/reload
chmod 644 /var/lib/gibbcoin/reload
echo "Alle offenen Seiten werden in den nächsten Sekunden neu geladen."
