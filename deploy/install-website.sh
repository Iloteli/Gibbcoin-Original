#!/usr/bin/env bash
#
# GIBB Coin – die normale (grüne) GibbCoin-Website zusätzlich auf dem Server installieren.
# Achtung: Diese Website nutzt weiter Supabase (Konten, Wallet, Spiele) und braucht Internet.
# Läuft als Dienst "gibb-website" auf Port 3000, neben der Chain-Seite (Port 80).
#
# Verwendung (nach install-server.sh):   sudo bash deploy/install-website.sh
set -euo pipefail
WEBSITE_PORT="${WEBSITE_PORT:-3000}"
RUN_USER="${RUN_USER:-gibb}"
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"

if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo bash deploy/install-website.sh" >&2; exit 1; fi
if [ ! -d "$APP_DIR/.git" ]; then echo "Erst 'sudo bash deploy/install-server.sh' ausführen." >&2; exit 1; fi

echo "==> Neueste Version holen"
git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" merge -q --ff-only '@{u}' || true

echo "==> pnpm aktivieren"
npm install -g pnpm >/dev/null 2>&1 || corepack enable
PNPM_BIN="$(command -v pnpm)"

# Der Build schreibt ins Repo: kurzzeitig dem Dienst-Benutzer gehören lassen.
chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR"
echo "==> Abhängigkeiten installieren und bauen (kann einige Minuten dauern)"
sudo -u "$RUN_USER" env HOME="/home/$RUN_USER" bash -lc "[ -f /var/lib/gibbcoin/website.env ] && { set -a; . /var/lib/gibbcoin/website.env; set +a; }; cd '$APP_DIR' && '$PNPM_BIN' install --frozen-lockfile && NODE_OPTIONS=--max-old-space-size=3072 '$PNPM_BIN' run build"
chmod -R a+rX "$APP_DIR"

cat > /etc/systemd/system/gibb-website.service <<UNIT
[Unit]
Description=GIBB Coin Website (Original, mit Supabase)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=PORT=$WEBSITE_PORT
Environment=NODE_OPTIONS=--max-old-space-size=1024
ExecStart=$PNPM_BIN start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable gibb-website.service
systemctl restart gibb-website.service
[ "$OPEN_FIREWALL" = "1" ] && command -v ufw >/dev/null 2>&1 && ufw allow "$WEBSITE_PORT"/tcp || true

sleep 5
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo; echo "GibbCoin-Website:  http://${IP:-DEIN_SERVER}:$WEBSITE_PORT   ($(curl -s -o /dev/null -w '%{http_code}' http://localhost:$WEBSITE_PORT/))"
echo "Chain-Seite:       http://${IP:-DEIN_SERVER}"
echo "Logs: journalctl -u gibb-website -f"
