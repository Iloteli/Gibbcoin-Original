#!/usr/bin/env bash
# Startet den Cloudflare Quick Tunnel und schreibt die öffentliche Adresse in $DATA_DIR/public-url.txt.
set -uo pipefail
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
TARGET="${TUNNEL_TARGET:-http://localhost:80}"
rm -f "$DATA_DIR/public-url.txt"
cloudflared tunnel --no-autoupdate --url "$TARGET" 2>&1 | while IFS= read -r line; do
  echo "$line"
  url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' <<<"$line" | head -1 || true)"
  [ -n "$url" ] && echo "$url" > "$DATA_DIR/public-url.txt"
done
