#!/usr/bin/env bash
# GIBB Coin auf dem Server sofort aktualisieren (statt auf das automatische Update alle 5 Min. zu warten).
#   sudo gibb-update            (oder: sudo bash /opt/gibbcoin/deploy/update.sh)
# Holt die neueste Version von GitHub, baut die Website neu, startet alle Dienste neu
# und zeigt danach den Zustand an.
set -uo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo bash /opt/gibbcoin/deploy/update.sh" >&2; exit 1; fi
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
# Kurzbefehl "sudo gibb-update" einrichten (zeigt immer auf dieses Skript)
ln -sf "$APP_DIR/deploy/update.sh" /usr/local/bin/gibb-update 2>/dev/null || true
ln -sf "$APP_DIR/deploy/maintenance.sh" /usr/local/bin/gibb-wartung 2>/dev/null || true
ln -sf "$APP_DIR/deploy/chain-key.sh" /usr/local/bin/gibb-chain-key 2>/dev/null || true
ln -sf "$APP_DIR/deploy/reload-clients.sh" /usr/local/bin/gibb-neuladen 2>/dev/null || true
FORCE=1 bash "$APP_DIR/deploy/auto-update.sh"
systemctl reload caddy 2>/dev/null || true
sleep 3
echo
echo "== Dienste"
for s in gibb-node gibb-website gibb-gateway caddy gibb-update.timer; do
  printf '  %-20s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done
echo "== Version: $(git -C "$APP_DIR" log -1 --format='%h %s' | cut -c1-80)"
echo "== Erreichbarkeit"
printf '  Website (8080)   %s\n' "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"
printf '  Chain   (8787)   %s\n' "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/api/stats)"
