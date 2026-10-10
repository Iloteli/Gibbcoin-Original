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

# Zwei Tunnel: einer für die GibbCoin-Website (Port 3000), einer für die Chain-Seite (Port 80).
systemctl disable --now gibb-tunnel.service 2>/dev/null || true
rm -f /etc/systemd/system/gibb-tunnel.service "$DATA_DIR/public-url.txt"
make_unit() { # name target after
  cat > "/etc/systemd/system/gibb-tunnel-$1.service" <<UNIT
[Unit]
Description=GIBB Coin öffentlicher Tunnel: $1
After=network-online.target $3
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Environment=DATA_DIR=$DATA_DIR
Environment=HOME=/home/$RUN_USER
ExecStart=/bin/bash $APP_DIR/deploy/tunnel-run.sh $1 $2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}
# Gateway: Website + Node (unter /node) auf einem Port, damit die Website den Node findet.
cat > /etc/systemd/system/gibb-gateway.service <<UNIT
[Unit]
Description=GIBB Coin Gateway (Website + /node)
After=network-online.target gibb-website.service gibb-node.service

[Service]
Type=simple
User=$RUN_USER
Environment=GATEWAY_PORT=8080
ExecStart=$(command -v node) $APP_DIR/deploy/gateway.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable gibb-gateway.service
systemctl restart gibb-gateway.service

make_unit website http://localhost:8080 gibb-gateway.service
make_unit chain http://localhost:80 gibb-node.service
systemctl daemon-reload
systemctl enable gibb-tunnel-website.service gibb-tunnel-chain.service
systemctl restart gibb-tunnel-website.service gibb-tunnel-chain.service

echo "==> Warte auf die öffentlichen Adressen ..."
for i in $(seq 1 30); do
  [ -s "$DATA_DIR/public-url-website.txt" ] && [ -s "$DATA_DIR/public-url-chain.txt" ] && break; sleep 2
done
echo
echo "GibbCoin-Website (Supabase):  $(cat "$DATA_DIR/public-url-website.txt" 2>/dev/null || echo '– noch keine, siehe journalctl -u gibb-tunnel-website')"
echo "Chain-Seite:                  $(cat "$DATA_DIR/public-url-chain.txt" 2>/dev/null || echo '– noch keine, siehe journalctl -u gibb-tunnel-chain')"
echo "Später abrufen:  cat $DATA_DIR/public-url-website.txt $DATA_DIR/public-url-chain.txt"
echo "Hinweis: Die Adressen ändern sich, wenn ein Tunnel neu startet (z. B. nach einem Server-Neustart)."
