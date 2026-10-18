#!/usr/bin/env bash
# Gibt die installierte Version aus, z. B. "1.4 (18.10.2026)".
#   gibb-version
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
cd "$APP_DIR" 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")/.."
HAUPT=1; START=0
[ -f deploy/VERSION ] && . deploy/VERSION
COUNT="$(git -c safe.directory='*' rev-list --count HEAD 2>/dev/null || echo "$START")"
MINOR=$((COUNT - START)); [ "$MINOR" -lt 0 ] && MINOR=0
DATE="$(git -c safe.directory='*' log -1 --format=%cd --date=format:%d.%m.%Y 2>/dev/null || echo "?")"
if [ "$MINOR" -eq 0 ]; then echo "$HAUPT ($DATE)"; else echo "$HAUPT.$MINOR ($DATE)"; fi
