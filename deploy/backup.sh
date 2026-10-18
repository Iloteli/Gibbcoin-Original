#!/usr/bin/env bash
# Sicherung der GIBB-Coin-Serverdaten (Blockchain, Einstellungen, Konfiguration).
#   sudo gibb-backup                      Sicherung jetzt erstellen
#   sudo gibb-backup liste                vorhandene Sicherungen anzeigen
#   sudo gibb-backup auto an|aus          tägliche automatische Sicherung (03:30 Uhr) ein-/ausschalten
#   sudo gibb-backup zurueck <datei>      Sicherung wiederherstellen (vorher wird der aktuelle Stand gesichert)
# Gesichert werden: /var/lib/gibbcoin (Chain, Sitzungen, Einstellungen), Caddy-Konfiguration und die
# GIBB-Dienste. Die Datenbank der Hauptseite liegt bei Supabase und wird dort gesichert.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo gibb-backup" >&2; exit 1; fi
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/gibbcoin}"
KEEP="${KEEP:-20}"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

create() {
  local name="$BACKUP_DIR/gibb-$(date +%Y-%m-%d_%H%M%S).tar.gz"
  local items=()
  [ -d "$DATA_DIR" ] && items+=("${DATA_DIR#/}")
  [ -d /etc/caddy ] && items+=("etc/caddy")
  for f in /etc/systemd/system/gibb-*; do [ -e "$f" ] && items+=("${f#/}"); done
  if [ ${#items[@]} -eq 0 ]; then echo "Nichts zu sichern gefunden." >&2; exit 1; fi
  # Einmal-Codes für den Login gehören nicht in eine Sicherung
  tar -C / --exclude="${DATA_DIR#/}/owner-login-code.json" -czf "$name" "${items[@]}"
  chmod 600 "$name"
  # Nur die neuesten $KEEP Sicherungen behalten
  ls -1t "$BACKUP_DIR"/gibb-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  echo "Sicherung erstellt: $name ($(du -h "$name" | cut -f1))"
}

case "${1:-}" in
  ""|jetzt)
    create ;;
  liste|list)
    echo "Sicherungen in $BACKUP_DIR (neueste zuerst):"
    ls -1t "$BACKUP_DIR"/gibb-*.tar.gz 2>/dev/null | while read -r f; do printf '  %s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"; done
    [ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ] || echo "  (noch keine)" ;;
  auto)
    case "${2:-}" in
      an|on)
        cat > /etc/systemd/system/gibb-backup.service <<UNIT
[Unit]
Description=GIBB Coin Sicherung
[Service]
Type=oneshot
ExecStart=/usr/local/bin/gibb-backup
UNIT
        cat > /etc/systemd/system/gibb-backup.timer <<UNIT
[Unit]
Description=GIBB Coin Sicherung täglich
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload
        systemctl enable --now gibb-backup.timer >/dev/null
        echo "Automatische Sicherung ist AN (täglich 03:30, die neuesten $KEEP bleiben)." ;;
      aus|off)
        systemctl disable --now gibb-backup.timer >/dev/null 2>&1 || true
        echo "Automatische Sicherung ist AUS." ;;
      *)
        if systemctl is-enabled gibb-backup.timer >/dev/null 2>&1; then echo "Automatische Sicherung: AN"; else echo "Automatische Sicherung: AUS"; fi
        echo "Ändern mit: sudo gibb-backup auto an   oder   sudo gibb-backup auto aus" ;;
    esac ;;
  zurueck|restore)
    file="${2:-}"
    [ -n "$file" ] || { echo "Welche Sicherung? Siehe: sudo gibb-backup liste" >&2; exit 1; }
    [ -f "$file" ] || file="$BACKUP_DIR/$file"
    [ -f "$file" ] || { echo "Datei nicht gefunden: $file" >&2; exit 1; }
    echo "Wiederherstellen aus: $(basename "$file")"
    read -r -p "Aktuellen Stand ersetzen? Er wird vorher gesichert. [ja/nein] " answer
    [ "$answer" = "ja" ] || { echo "Abgebrochen."; exit 0; }
    create
    systemctl stop gibb-node.service 2>/dev/null || true
    tar -C / -xzf "$file" "${DATA_DIR#/}"
    systemctl start gibb-node.service
    echo "Wiederhergestellt. Die Chain-Seite läuft wieder mit dem gesicherten Stand." ;;
  *)
    echo "Unbekannt: $1 – siehe: sudo gibb-help" >&2; exit 1 ;;
esac
