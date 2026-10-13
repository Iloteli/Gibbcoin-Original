#!/usr/bin/env bash
# Website vorübergehend offline nehmen (Wartungsseite) – die Chain-Seite bleibt erreichbar.
#   sudo gibb-wartung an     -> Website zeigt "GIBB Coin ist kurz offline"
#   sudo gibb-wartung aus    -> Website wieder normal
#   sudo gibb-wartung        -> aktuellen Zustand anzeigen
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
FLAG=/var/lib/gibbcoin/maintenance
mkdir -p /var/lib/gibbcoin
case "${1:-status}" in
  an|on)   touch "$FLAG"; echo "Website ist jetzt OFFLINE (Wartungsseite)." ;;
  aus|off) rm -f "$FLAG";  echo "Website ist wieder ONLINE." ;;
  *)       [ -f "$FLAG" ] && echo "Website ist OFFLINE (Wartung)." || echo "Website ist ONLINE." ;;
esac
