#!/usr/bin/env bash
#
# GIBB Coin – Update auf dem Debian-Server.
# Holt den neuesten Stand von GitHub, baut die Website neu und startet die
# systemd-Dienste neu. Voraussetzung: install-debian.sh wurde bereits ausgeführt.
#
# Verwendung (als root, im Repository):
#   cd Gibbcoin-Original
#   sudo bash deploy/update-debian.sh
#
# Optionen: RUN_USER=gibb  BRANCH=main

set -euo pipefail

RUN_USER="${RUN_USER:-gibb}"
BRANCH="${BRANCH:-main}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen:  sudo bash deploy/update-debian.sh" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "==> Repository: $REPO_DIR (Branch $BRANCH)"

# Repository muss dem Dienst-Benutzer gehören.
if id "$RUN_USER" >/dev/null 2>&1; then
  chown -R "$RUN_USER":"$RUN_USER" "$REPO_DIR" 2>/dev/null || true
  AS_USER=(sudo -u "$RUN_USER" env HOME="/home/$RUN_USER")
else
  AS_USER=()
fi

BEFORE="$("${AS_USER[@]}" git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo none)"

echo "==> Neuen Stand von GitHub holen"
"${AS_USER[@]}" git -C "$REPO_DIR" fetch --prune origin
"${AS_USER[@]}" git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
AFTER="$("${AS_USER[@]}" git -C "$REPO_DIR" rev-parse HEAD)"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "==> Bereits aktuell (${AFTER:0:7}). Dienste werden trotzdem neu gestartet."
else
  echo "==> Aktualisiert: ${BEFORE:0:7} -> ${AFTER:0:7}"
fi

# Abhängigkeiten nur bei geändertem Lockfile neu installieren.
if [ "$BEFORE" = "none" ] || "${AS_USER[@]}" git -C "$REPO_DIR" diff --name-only "$BEFORE" "$AFTER" | grep -q "pnpm-lock.yaml"; then
  echo "==> Abhängigkeiten installieren"
  "${AS_USER[@]}" bash -lc "cd '$REPO_DIR' && corepack pnpm install --frozen-lockfile"
fi

echo "==> Website neu bauen"
"${AS_USER[@]}" bash -lc "cd '$REPO_DIR' && NODE_OPTIONS=--max-old-space-size=3072 corepack pnpm run build"

echo "==> Dienste neu starten"
systemctl restart gibb-node.service gibb-website.service
sleep 2
systemctl --no-pager --lines=0 status gibb-node.service gibb-website.service || true

echo
echo "============================================================"
echo " Update fertig – GIBB Coin läuft auf dem neuen Stand (${AFTER:0:7})."
echo " Logs:  journalctl -u gibb-node -f   /   journalctl -u gibb-website -f"
echo "============================================================"
