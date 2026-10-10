#!/usr/bin/env bash
# Holt neue Versionen von GitHub und startet den Dienst neu, falls es etwas Neues gibt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git config --global --add safe.directory "$PWD" 2>/dev/null || true
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
  git merge -q --ff-only '@{u}'
  systemctl restart gibb-node.service
  echo "GIBB Coin aktualisiert auf $(git rev-parse --short HEAD)"
fi
