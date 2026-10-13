#!/usr/bin/env bash
#
# GIBB Coin – öffentliche HTTPS-Adressen mit gültigem Zertifikat (Let's Encrypt, automatisch erneuert).
# Voraussetzung: Ports 80 und 443 sind von aussen offen und die Domain zeigt auf diesen Server.
#
#   https://DOMAIN          -> GibbCoin-Website (Gateway: Website + /node + /sb)
#   https://chain.DOMAIN    -> Chain-Seite (Blockchain-Node)
#   http://<Server-IP>      -> GibbCoin-Website (ohne Zertifikat; IPs bekommen keins)
#
# Verwendung:   sudo bash deploy/install-https.sh
# Optionen:     DOMAIN=gibbcoin-original.duckdns.org  EMAIL=...  (EMAIL optional, für Ablauf-Hinweise)
set -euo pipefail
DOMAIN="${DOMAIN:-gibbcoin-original.duckdns.org}"
EMAIL="${EMAIL:-}"
NODE_INTERNAL_PORT="${NODE_INTERNAL_PORT:-8787}"

if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo bash deploy/install-https.sh" >&2; exit 1; fi
if [ ! -f /etc/systemd/system/gibb-node.service ]; then echo "Erst 'sudo bash deploy/install-server.sh' ausführen." >&2; exit 1; fi

APP_DIR="${APP_DIR:-/opt/gibbcoin}"
if [ -d "$APP_DIR/.git" ]; then
  echo "==> Neueste Version holen"
  git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
  git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" reset -q --hard origin/main || true
fi

echo "==> Caddy installieren"
export DEBIAN_FRONTEND=noninteractive
if ! command -v caddy >/dev/null 2>&1; then
  apt-get update -y
  if ! apt-get install -y caddy; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y && apt-get install -y caddy
  fi
fi
echo "    $(caddy version | head -1)"

echo "==> Blockchain-Node von Port 80 auf internen Port $NODE_INTERNAL_PORT verlegen"
mkdir -p /etc/systemd/system/gibb-node.service.d
cat > /etc/systemd/system/gibb-node.service.d/port.conf <<UNIT
[Service]
Environment=PORT=$NODE_INTERNAL_PORT
Environment=HTTPS_PORT=
UNIT
if [ ! -f /etc/systemd/system/gibb-gateway.service ]; then
  # Gateway (Website + /node + /sb auf Port 8080) anlegen, falls es noch nicht existiert.
  cat > /etc/systemd/system/gibb-gateway.service <<UNIT
[Unit]
Description=GIBB Coin Gateway (Website + /node)
After=network-online.target gibb-website.service gibb-node.service

[Service]
Type=simple
User=${RUN_USER:-gibb}
Environment=GATEWAY_PORT=8080
ExecStart=$(command -v node) ${APP_DIR:-/opt/gibbcoin}/deploy/gateway.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable gibb-gateway.service
fi
if [ -f /etc/systemd/system/gibb-gateway.service ]; then
  mkdir -p /etc/systemd/system/gibb-gateway.service.d
  cat > /etc/systemd/system/gibb-gateway.service.d/node.conf <<UNIT
[Service]
Environment=NODE_TARGET=http://127.0.0.1:$NODE_INTERNAL_PORT
UNIT
fi
# Cloudflare-Tunnel der Chain-Seite (falls vorhanden) ebenfalls umstellen.
if [ -f /etc/systemd/system/gibb-tunnel-chain.service ]; then
  sed -i "s#http://localhost:80\$#http://localhost:$NODE_INTERNAL_PORT#" /etc/systemd/system/gibb-tunnel-chain.service
fi
systemctl daemon-reload
systemctl restart gibb-node.service
systemctl restart gibb-gateway.service 2>/dev/null || true
systemctl restart gibb-tunnel-chain.service 2>/dev/null || true

echo "==> Caddy konfigurieren"
cat > /etc/caddy/Caddyfile <<CADDY
{
	${EMAIL:+email $EMAIL}
}

# GibbCoin-Website (über das Gateway: Website, /node, /sb)
$DOMAIN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}

# Chain-Seite
chain.$DOMAIN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:$NODE_INTERNAL_PORT
}

# Aufruf per IP (ohne Zertifikat)
http:// {
	reverse_proxy 127.0.0.1:8080
}
CADDY
caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp || true; ufw allow 443/tcp || true
fi

echo "==> Warte auf die Zertifikate (bis zu 60 s)"
ok_main="nein"; ok_chain="nein"
for i in $(seq 1 30); do
  curl -s -m 5 -o /dev/null "https://$DOMAIN/" && ok_main="ja"
  curl -s -m 5 -o /dev/null "https://chain.$DOMAIN/api/stats" && ok_chain="ja"
  [ "$ok_main" = ja ] && [ "$ok_chain" = ja ] && break
  sleep 2
done
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================================================"
echo " GibbCoin-Website:  https://$DOMAIN          (Zertifikat ok: $ok_main)"
echo " Chain-Seite:       https://chain.$DOMAIN    (Zertifikat ok: $ok_chain)"
echo " Per IP:            http://${IP:-SERVER}"
echo " Logs: journalctl -u caddy -n 50 --no-pager"
echo "============================================================"
