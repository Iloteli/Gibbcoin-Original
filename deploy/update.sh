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
ln -sf "$APP_DIR/deploy/login-code.sh" /usr/local/bin/gibb-code 2>/dev/null || true
ln -sf "$APP_DIR/deploy/backup.sh" /usr/local/bin/gibb-backup 2>/dev/null || true
ln -sf "$APP_DIR/deploy/help.sh" /usr/local/bin/gibb-help 2>/dev/null || true
ln -sf "$APP_DIR/deploy/version.sh" /usr/local/bin/gibb-version 2>/dev/null || true
ln -sf "$APP_DIR/deploy/autoupdate-switch.sh" /usr/local/bin/gibb-autoupdate 2>/dev/null || true
ln -sf "$APP_DIR/deploy/supabase-umzug.sh" /usr/local/bin/gibb-umzug 2>/dev/null || true
ln -sf "$APP_DIR/deploy/sudo-ohne-passwort.sh" /usr/local/bin/gibb-sudo 2>/dev/null || true
ln -sf "$APP_DIR/deploy/ssh-keys.sh" /usr/local/bin/gibb-ssh-keys 2>/dev/null || true
ln -sf "$APP_DIR/deploy/email-setup.sh" /usr/local/bin/gibb-email 2>/dev/null || true
FORCE=1 bash "$APP_DIR/deploy/auto-update.sh"
systemctl reload caddy 2>/dev/null || true
sleep 3
echo
echo "== Dienste"
for s in gibb-node gibb-website gibb-gateway caddy; do
  printf '  %-20s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done
echo "== Version: $(bash "$APP_DIR/deploy/version.sh")"
echo "   Letzte Änderung: $(git -c safe.directory='*' -C "$APP_DIR" log -1 --format='%s' | cut -c1-90)"
printf '   Automatische Updates: %s
' "$(systemctl is-active gibb-update.timer >/dev/null 2>&1 && echo an || echo aus)"
echo "   Alle Befehle: gibb-help"
echo "== Erreichbarkeit"
printf '  Website (8080)   %s\n' "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"
printf '  Chain   (8787)   %s\n' "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/api/stats)"
