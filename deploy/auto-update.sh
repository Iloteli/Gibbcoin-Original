#!/usr/bin/env bash
# Holt neue Versionen von GitHub und startet die Dienste neu, falls es etwas Neues gibt.
# Ist die GibbCoin-Website installiert, wird sie dabei auch neu gebaut.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RUN_USER="${RUN_USER:-gibb}"
git config --global --add safe.directory "$PWD" 2>/dev/null || true
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
  git merge -q --ff-only '@{u}'
  if systemctl list-unit-files gibb-website.service >/dev/null 2>&1 && [ -f /etc/systemd/system/gibb-website.service ]; then
    PNPM_BIN="$(command -v pnpm)"
    chown -R "$RUN_USER":"$RUN_USER" "$PWD"
    sudo -u "$RUN_USER" env HOME="/home/$RUN_USER" bash -lc "[ -f /var/lib/gibbcoin/website.env ] && { set -a; . /var/lib/gibbcoin/website.env; set +a; }; cd '$PWD' && '$PNPM_BIN' install --frozen-lockfile && NODE_OPTIONS=--max-old-space-size=3072 '$PNPM_BIN' run build"
    chmod -R a+rX "$PWD"
    systemctl restart gibb-website.service
  fi
  systemctl restart gibb-node.service
  [ -f /etc/systemd/system/gibb-gateway.service ] && systemctl restart gibb-gateway.service || true
  echo "GIBB Coin aktualisiert auf $(git rev-parse --short HEAD)"
fi
