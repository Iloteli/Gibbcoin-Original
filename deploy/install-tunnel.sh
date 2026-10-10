#!/usr/bin/env bash
#
# GIBB Coin – öffentliche HTTPS-Adresse OHNE offene Ports (Cloudflare Quick Tunnel, kein Konto nötig).
# Der Server baut eine AUSGEHENDE Verbindung zu Cloudflare auf; Cloudflare gibt eine Adresse wie
# https://zufallsname.trycloudflare.com mit gültigem Zertifikat. Die Adresse ändert sich bei jedem Neustart
# des Tunnels (siehe: cat /var/lib/gibbcoin/public-url.txt).
#
# Verwendung auf dem Server:   sudo bash deploy/install-tunnel.sh
set -euo pipefail
RUN_USER="${RUN_USER:-gibb}"
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
APP_DIR="${APP_DIR:-/opt/gibbcoin}"

if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo bash deploy/install-tunnel.sh" >&2; exit 1; fi
if [ ! -d "$APP_DIR/deploy" ]; then echo "Erst 'sudo bash deploy/install-server.sh' ausführen." >&2; exit 1; fi
chmod -R a+rX "$APP_DIR"

if ! command -v cloudflared >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
  echo "==> cloudflared (offizielles Cloudflare-Paket von GitHub) laden: $ARCH"
  curl -fsSL -o /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
  dpkg -i /tmp/cloudflared.deb || apt-get install -f -y
  rm -f /tmp/cloudflared.deb
fi
echo "==> $(cloudflared --version)"

cat > /etc/systemd/system/gibb-tunnel.service <<UNIT
[Unit]
Description=GIBB Coin öffentlicher Tunnel (Cloudflare Quick Tunnel)
After=network-online.target gibb-node.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Environment=DATA_DIR=$DATA_DIR
Environment=HOME=/home/$RUN_USER
ExecStart=/bin/bash $APP_DIR/deploy/tunnel-run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable gibb-tunnel.service
systemctl restart gibb-tunnel.service

echo "==> Warte auf die öffentliche Adresse ..."
for i in $(seq 1 30); do
  [ -s "$DATA_DIR/public-url.txt" ] && break; sleep 2
done
echo
if [ -s "$DATA_DIR/public-url.txt" ]; then
  echo "Öffentliche Adresse:  $(cat "$DATA_DIR/public-url.txt")"
else
  echo "Noch keine Adresse. Logs ansehen:  journalctl -u gibb-tunnel -n 30 --no-pager"
fi
echo "Adresse später abrufen:  cat $DATA_DIR/public-url.txt"
