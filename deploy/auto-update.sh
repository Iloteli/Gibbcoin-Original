#!/usr/bin/env bash
# Holt neue Versionen von GitHub und startet die Dienste neu, falls es etwas Neues gibt.
# Ist die GibbCoin-Website installiert, wird sie dabei auch neu gebaut.
# Der Ordner ist eine reine Server-Kopie: er wird hart auf den GitHub-Stand gesetzt, damit
# Build-Reste (z. B. veränderte generierte Dateien) das Update nie blockieren.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RUN_USER="${RUN_USER:-gibb}"
git config --global --add safe.directory "$PWD" 2>/dev/null || true
git fetch -q origin || { echo "GitHub nicht erreichbar"; exit 1; }
TARGET="$(git rev-parse '@{u}' 2>/dev/null || git rev-parse origin/main)"
if [ "${FORCE:-0}" != "1" ] && [ "$(git rev-parse HEAD)" = "$TARGET" ]; then exit 0; fi
git reset -q --hard "$TARGET"
echo "GIBB Coin: neue Version $(git rev-parse --short HEAD)"
if [ -f /etc/systemd/system/gibb-website.service ]; then
  PNPM_BIN="$(command -v pnpm)"
  chown -R "$RUN_USER":"$RUN_USER" "$PWD"
  if sudo -u "$RUN_USER" env HOME="/home/$RUN_USER" bash -lc "[ -f /var/lib/gibbcoin/website.env ] && { set -a; . /var/lib/gibbcoin/website.env; set +a; }; cd '$PWD' && '$PNPM_BIN' install --frozen-lockfile && NODE_OPTIONS=--max-old-space-size=2048 '$PNPM_BIN' run build"; then
    systemctl restart gibb-website.service
  else
    echo "WARNUNG: Website-Build fehlgeschlagen – alte Website läuft weiter."
  fi
  chmod -R a+rX "$PWD"
fi
# Neue Datenbank-Migrationen (nur bei eigener Supabase-Datenbank auf diesem Server)
bash "$PWD/deploy/apply-migrations.sh" || echo "WARNUNG: Datenbank-Update fehlgeschlagen."
systemctl restart gibb-node.service
[ -f /etc/systemd/system/gibb-gateway.service ] && systemctl restart gibb-gateway.service
# Offene Seiten laden die neue Version automatisch (sobald die Website wieder antwortet).
if [ -f /etc/systemd/system/gibb-website.service ]; then
  for _ in $(seq 1 60); do curl -fs -o /dev/null http://127.0.0.1:3000/ && break; sleep 1; done
  mkdir -p /var/lib/gibbcoin && date +%s%N > /var/lib/gibbcoin/reload && chmod 644 /var/lib/gibbcoin/reload
fi
# Kurzbefehle aktuell halten (auch wenn nur das automatische Update läuft)
for pair in update:update wartung:maintenance chain-key:chain-key neuladen:reload-clients code:login-code backup:backup help:help version:version autoupdate:autoupdate-switch ssh-keys:ssh-keys; do
  ln -sf "$PWD/deploy/${pair#*:}.sh" "/usr/local/bin/gibb-${pair%%:*}" 2>/dev/null || true
done
chmod +x "$PWD"/deploy/*.sh 2>/dev/null || true
echo "GIBB Coin aktualisiert auf Version $(bash "$PWD/deploy/version.sh")"
