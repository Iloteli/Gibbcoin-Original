#!/usr/bin/env bash
#
# GIBB Coin – Einrichtung/Update auf dem Server.
# Wird vom .deb-Paket beim Installieren (postinst) ausgeführt und kann jederzeit
# erneut laufen (idempotent). Holt die aktuelle App, baut sie und richtet die
# systemd-Dienste ein.
#
set -euo pipefail

# ---- Konfiguration (überschreibbar via /etc/default/gibbcoin) --------------
REPO_URL="${REPO_URL:-https://github.com/Iloteli/Gibbcoin-Original.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
RUN_USER="${RUN_USER:-gibb}"
WEBSITE_PORT="${WEBSITE_PORT:-3000}"
NODE_PORT="${NODE_PORT:-8787}"
NODE_MAJOR="${NODE_MAJOR:-22}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
BUILD_MEM_MB="${BUILD_MEM_MB:-3072}"

[ -f /etc/default/gibbcoin ] && . /etc/default/gibbcoin

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

echo "==> GIBB Coin Einrichtung startet"
export DEBIAN_FRONTEND=noninteractive

echo "==> Systempakete sicherstellen (curl, git, ca-certificates, gnupg)"
apt-get update -y
apt-get install -y ca-certificates curl gnupg git

# ---- Node.js (NodeSource) --------------------------------------------------
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt "$NODE_MAJOR" ]; then
  echo "==> Node.js $NODE_MAJOR installieren"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs
fi
echo "==> Node: $(node -v),  npm: $(npm -v)"

echo "==> pnpm über corepack aktivieren"
corepack enable
corepack prepare pnpm@latest --activate
PNPM_BIN="$(command -v pnpm)"
NODE_BIN="$(command -v node)"

# ---- Dienst-Benutzer -------------------------------------------------------
if ! id "$RUN_USER" >/dev/null 2>&1; then
  echo "==> Dienst-Benutzer '$RUN_USER' anlegen"
  useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
fi

# ---- App holen / aktualisieren ---------------------------------------------
if [ -d "$APP_DIR/.git" ]; then
  echo "==> Vorhandene Installation aktualisieren ($APP_DIR)"
  git -C "$APP_DIR" fetch --depth 1 origin "$REPO_BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$REPO_BRANCH"
else
  echo "==> App klonen nach $APP_DIR"
  rm -rf "$APP_DIR"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
fi
chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR"

# ---- Abhängigkeiten + Build ------------------------------------------------
echo "==> Abhängigkeiten installieren und Website bauen (dauert einige Minuten)"
sudo -u "$RUN_USER" env HOME="/home/$RUN_USER" bash -lc \
  "cd '$APP_DIR' && corepack pnpm install --frozen-lockfile && NODE_OPTIONS=--max-old-space-size=$BUILD_MEM_MB corepack pnpm run build"

# ---- systemd-Dienste -------------------------------------------------------
echo "==> systemd-Dienste schreiben"
cat > /etc/systemd/system/gibb-node.service <<UNIT
[Unit]
Description=GIBB Blockchain-Node (API + Reserve-Miner)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=PORT=$NODE_PORT
Environment=FALLBACK_MINER=1
ExecStart=$NODE_BIN blockchain-node/server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/gibb-website.service <<UNIT
[Unit]
Description=GIBB Coin Website
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

echo "==> Dienste aktivieren und (neu) starten"
systemctl daemon-reload
systemctl enable gibb-node.service gibb-website.service
systemctl restart gibb-node.service gibb-website.service

if [ "$OPEN_FIREWALL" = "1" ] && command -v ufw >/dev/null 2>&1; then
  echo "==> Firewall-Ports öffnen ($WEBSITE_PORT, $NODE_PORT)"
  ufw allow "$WEBSITE_PORT"/tcp || true
  ufw allow "$NODE_PORT"/tcp || true
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================================================"
echo " GIBB Coin läuft."
echo "   Website:          http://${IP:-DEIN_SERVER}:$WEBSITE_PORT"
echo "   Blockchain-Node:  http://${IP:-DEIN_SERVER}:$NODE_PORT"
echo
echo " Status:   systemctl status gibb-node gibb-website"
echo " Logs:     journalctl -u gibb-node -f"
echo " Update:   sudo gibbcoin-update      (oder Paket neu installieren)"
echo "============================================================"
