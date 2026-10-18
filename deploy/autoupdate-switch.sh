#!/usr/bin/env bash
# Automatische Updates (alle 5 Minuten von GitHub) ein- oder ausschalten.
#   sudo gibb-autoupdate          Zustand anzeigen
#   sudo gibb-autoupdate aus      ausschalten – Updates nur noch mit "sudo gibb-update"
#   sudo gibb-autoupdate an       wieder einschalten
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo gibb-autoupdate" >&2; exit 1; fi
case "${1:-}" in
  aus|off) systemctl disable --now gibb-update.timer >/dev/null 2>&1 || true; echo "Automatische Updates sind AUS. Neue Versionen holst du mit: sudo gibb-update" ;;
  an|on)   systemctl enable --now gibb-update.timer >/dev/null; echo "Automatische Updates sind AN (alle 5 Minuten)." ;;
  "")      if systemctl is-active gibb-update.timer >/dev/null 2>&1; then echo "Automatische Updates: AN"; else echo "Automatische Updates: AUS"; fi
           echo "Ändern mit: sudo gibb-autoupdate an   oder   sudo gibb-autoupdate aus" ;;
  *)       echo "Unbekannt: $1 – erlaubt sind: an, aus" >&2; exit 1 ;;
esac
