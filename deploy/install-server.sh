#!/usr/bin/env bash
#
# GIBB Coin – Server-Installation OHNE Supabase / Cloud.
# Installiert nur den eigenen Node (Blockchain + Konten + Wallets + Handel + Website)
# als systemd-Dienst. Alle Daten liegen lokal auf dem Server in $DATA_DIR/chain.json.
#
# Verwendung (auf dem Server, im geklonten Repository, als root bzw. mit sudo):
#   git clone https://github.com/Iloteli/Gibbcoin-Original.git && cd Gibbcoin-Original
#   sudo bash deploy/install-server.sh
#
# Optionen: HTTPS_PORT=443  PORT=80  RUN_USER=gibb  DATA_DIR=/var/lib/gibbcoin  NODE_MAJOR=22  OPEN_FIREWALL=1

set -euo pipefail
PORT="${PORT:-80}"
RUN_USER="${RUN_USER:-gibb}"
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
NODE_MAJOR="${NODE_MAJOR:-22}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
HTTPS_PORT="${HTTPS_PORT:-443}"

if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo bash deploy/install-server.sh" >&2; exit 1; fi
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Der Dienst läuft aus /opt/gibbcoin (lesbar für alle), nicht aus einem privaten Home-Ordner.
REPO_DIR="${APP_DIR:-/opt/gibbcoin}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg libcap2-bin openssl

if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt "$NODE_MAJOR" ]; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y && apt-get install -y nodejs
fi
NODE_BIN="$(command -v node)"

ORIGIN_URL="$(git -C "$SRC_DIR" remote get-url origin 2>/dev/null || echo https://github.com/Iloteli/Gibbcoin-Original.git)"
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch -q origin && git -C "$REPO_DIR" merge -q --ff-only '@{u}' || true
else
  git clone -q "$ORIGIN_URL" "$REPO_DIR"
fi
chmod -R a+rX "$REPO_DIR"

id "$RUN_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
mkdir -p "$DATA_DIR"; chown -R "$RUN_USER":"$RUN_USER" "$DATA_DIR"
# Bestehende Kette beim Update nicht überschreiben; alte Daten aus dem Repo einmalig übernehmen.
if [ ! -f "$DATA_DIR/chain.json" ] && [ -f "$REPO_DIR/blockchain-node/data/chain.json" ]; then
  cp "$REPO_DIR/blockchain-node/data/chain.json" "$DATA_DIR/chain.json"; chown "$RUN_USER":"$RUN_USER" "$DATA_DIR/chain.json"
fi

# Selbst signiertes HTTPS-Zertifikat (10 Jahre) für IP und localhost – einmalig erzeugen.
TLS_DIR="$DATA_DIR/tls"; mkdir -p "$TLS_DIR"
if [ ! -f "$TLS_DIR/cert.pem" ]; then
  IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem"     -subj "/CN=gibbcoin" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1${IP_ADDR:+,IP:$IP_ADDR}"
fi
chown -R "$RUN_USER":"$RUN_USER" "$TLS_DIR"; chmod 600 "$TLS_DIR/key.pem"

cat > /etc/systemd/system/gibb-node.service <<UNIT
[Unit]
Description=GIBB Coin (Blockchain + Website, ohne Supabase)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$REPO_DIR
Environment=PORT=$PORT
Environment=CHAIN_FILE=$DATA_DIR/chain.json
Environment=FALLBACK_MINER=1
Environment=HTTPS_PORT=$HTTPS_PORT
Environment=TLS_KEY=$TLS_DIR/key.pem
Environment=TLS_CERT=$TLS_DIR/cert.pem
ExecStart=$NODE_BIN blockchain-node/server.mjs
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable gibb-node.service
systemctl restart gibb-node.service

# Auto-Update: alle 5 Minuten neue Version von GitHub holen (kein SSH-Login mehr nötig).
if [ "${AUTO_UPDATE:-1}" = "1" ]; then
  cat > /etc/systemd/system/gibb-update.service <<UNIT
[Unit]
Description=GIBB Coin Auto-Update von GitHub

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
ExecStart=/bin/bash $REPO_DIR/deploy/auto-update.sh
UNIT
  cat > /etc/systemd/system/gibb-update.timer <<UNIT
[Unit]
Description=GIBB Coin Auto-Update (alle 5 Minuten)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now gibb-update.timer
fi
# Alte Supabase-basierte Website-Dienste (falls früher installiert) abschalten.
systemctl disable --now gibb-website.service 2>/dev/null || true

if [ "$OPEN_FIREWALL" = "1" ] && command -v ufw >/dev/null 2>&1; then ufw allow "$PORT"/tcp || true; ufw allow "$HTTPS_PORT"/tcp || true; fi
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo; echo "GIBB Coin läuft:  http://${IP:-DEIN_SERVER}$([ "$PORT" = 80 ] || echo ":$PORT")"
echo "HTTPS:            https://${IP:-DEIN_SERVER}   (selbst signiert: Browser-Warnung einmal bestätigen)"
echo "Status: systemctl status gibb-node   Logs: journalctl -u gibb-node -f"
echo "Updates: automatisch alle 5 Min. von GitHub (Timer gibb-update)"
echo "Daten:  $DATA_DIR/chain.json  (Backup: diese Datei kopieren)"
