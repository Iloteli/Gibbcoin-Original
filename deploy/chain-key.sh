#!/usr/bin/env bash
# Verbindet die Chain-Seite mit der Hauptseite: erzeugt einen geheimen Schlüssel für den Node
# und gibt die SQL-Zeile aus, die ihn einmal in Supabase hinterlegt.
#   sudo gibb-chain-key
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
KEY="$(openssl rand -hex 32)"
mkdir -p /etc/systemd/system/gibb-node.service.d
cat > /etc/systemd/system/gibb-node.service.d/settings-key.conf <<UNIT
[Service]
Environment=NODE_SETTINGS_KEY=$KEY
UNIT
chmod 600 /etc/systemd/system/gibb-node.service.d/settings-key.conf
systemctl daemon-reload
systemctl restart gibb-node.service
echo
echo "Schlüssel auf dem Server gespeichert. Jetzt im Supabase SQL Editor diese Zeile ausführen:"
echo
echo "  select private.set_node_settings_key('$KEY');"
echo
echo "Danach überträgt die Chain-Seite ihre Einstellungen auf die Hauptseite."
