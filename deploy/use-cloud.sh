#!/usr/bin/env bash
# Stellt die GibbCoin-Website wieder auf die Supabase-CLOUD um (Robyns Projekt).
# - Website wird ohne eigene Datenbank-Einstellung neu gebaut (nutzt die Cloud).
# - Eigene Supabase-Instanz wird gestoppt (Daten bleiben erhalten, kein RAM-Verbrauch).
# - Blockchain-Node prüft Owner-Logins bei der Cloud (öffentlicher Schlüssel), damit
#   Einstellungen, Nutzer-Synchronisation und Server-Miner im Owner-Bereich funktionieren.
#   sudo bash deploy/use-cloud.sh
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUD_URL="https://laduzigqgvvnrqcgfgab.supabase.co"
CLOUD_KEY="$(grep -oE 'sb_publishable_[A-Za-z0-9_]+' "$REPO_DIR/app/lib/supabase.ts" | head -1)"

echo "==> Website-Einstellung für die eigene Datenbank entfernen"
rm -f "$DATA_DIR/website.env"

echo "==> Eigene Supabase-Instanz stoppen (Daten bleiben)"
if [ -f /opt/supabase/docker-compose.yml ]; then (cd /opt/supabase && docker compose down) || true; fi

echo "==> Blockchain-Node mit der Cloud verbinden (nur Owner-Prüfung, öffentlicher Schlüssel)"
mkdir -p /etc/systemd/system/gibb-node.service.d
cat > /etc/systemd/system/gibb-node.service.d/supabase.conf <<UNIT
[Service]
Environment=SUPABASE_URL=$CLOUD_URL
Environment=SUPABASE_ANON_KEY=$CLOUD_KEY
UNIT
systemctl daemon-reload
systemctl restart gibb-node.service

echo "==> Website neu bauen"
bash "$REPO_DIR/deploy/install-website.sh"
systemctl restart gibb-gateway.service 2>/dev/null || true

echo
echo "Fertig: Die Website nutzt wieder die Supabase-Cloud."
echo "Öffentlicher Link:  $(cat "$DATA_DIR/public-url-website.txt" 2>/dev/null || echo '(kein Tunnel – sudo bash deploy/install-tunnel.sh)')"
