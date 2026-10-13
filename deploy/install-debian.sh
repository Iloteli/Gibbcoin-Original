#!/usr/bin/env bash
#
# GIBB Coin – Installation auf einem Debian-Server (Debian 12 "bookworm" oder neuer).
# Installiert Node.js, baut die Website und richtet zwei systemd-Dienste ein:
#   - gibb-node.service     -> Blockchain-Node + API auf Port 8787 (mit Reserve-Miner)
#   - gibb-website.service  -> GibbCoin-Website auf Port 3000
# Beide starten automatisch beim Booten und werden bei Absturz neu gestartet.
#
# Verwendung (als root, im geklonten Repository):
#   git clone https://github.com/Iloteli/Gibbcoin-Original.git
#   cd Gibbcoin-Original
#   sudo bash deploy/install-debian.sh
#
# Optionen (Umgebungsvariablen):
#   WEBSITE_PORT=3000   NODE_PORT=8787   RUN_USER=gibb   OPEN_FIREWALL=1

set -euo pipefail

WEBSITE_PORT="${WEBSITE_PORT:-3000}"
NODE_PORT="${NODE_PORT:-8787}"
RUN_USER="${RUN_USER:-gibb}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
NODE_MAJOR="${NODE_MAJOR:-22}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen:  sudo bash deploy/install-debian.sh" >&2
  exit 1
fi

# Repository-Wurzel = übergeordnetes Verzeichnis dieses Skripts.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "==> Repository: $REPO_DIR"

echo "==> Systempakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git

if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt "$NODE_MAJOR" ]; then
  echo "==> Node.js $NODE_MAJOR installieren (NodeSource)"
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
echo "==> pnpm: $($PNPM_BIN -v) ($PNPM_BIN)"

echo "==> Dienst-Benutzer '$RUN_USER' anlegen (falls nötig)"
if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
fi
chown -R "$RUN_USER":"$RUN_USER" "$REPO_DIR"

echo "==> Abhängigkeiten installieren und Website bauen (kann einige Minuten dauern)"
sudo -u "$RUN_USER" env HOME="/home/$RUN_USER" bash -lc "cd '$REPO_DIR' && corepack pnpm install --frozen-lockfile && NODE_OPTIONS=--max-old-space-size=3072 corepack pnpm run build"

echo "==> systemd-Dienste schreiben"
cat > /etc/systemd/system/gibb-node.service <<UNIT
[Unit]
Description=GIBB Blockchain-Node (API + Reserve-Miner)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$REPO_DIR
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
WorkingDirectory=$REPO_DIR
Environment=PORT=$WEBSITE_PORT
Environment=NODE_OPTIONS=--max-old-space-size=1024
ExecStart=$PNPM_BIN start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Dienste aktivieren und starten"
systemctl daemon-reload
systemctl enable --now gibb-node.service gibb-website.service

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
echo " Logs:     journalctl -u gibb-node -f     /     journalctl -u gibb-website -f"
echo " Update:   git pull && sudo bash deploy/install-debian.sh"
echo "============================================================"
