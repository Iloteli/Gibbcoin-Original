#!/usr/bin/env bash
# Startet einen Cloudflare Quick Tunnel für ein Ziel und schreibt die öffentliche Adresse
# nach $DATA_DIR/public-url-<NAME>.txt.   Aufruf: tunnel-run.sh <name> <ziel-url>
set -uo pipefail
NAME="${1:-chain}"; TARGET="${2:-http://localhost:80}"
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
OUT="$DATA_DIR/public-url-$NAME.txt"
rm -f "$OUT"
cloudflared tunnel --no-autoupdate --url "$TARGET" 2>&1 | while IFS= read -r line; do
  echo "$line"
  url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' <<<"$line" | head -1 || true)"
  [ -n "$url" ] && echo "$url" > "$OUT"
done
