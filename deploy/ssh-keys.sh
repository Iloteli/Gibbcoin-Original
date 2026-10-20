#!/usr/bin/env bash
# SSH-Schlüssel der Chain-Konten freischalten (Anmelden ohne Passwort).
#   gibb-ssh-keys        (ohne sudo: für deinen eigenen Server-Benutzer)
# Die Schlüssel tragen die Konten auf der Chain-Seite unter Einstellungen → Server ein.
set -euo pipefail
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CHAIN_FILE="$(systemctl show gibb-node.service -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^CHAIN_FILE=//p' | head -1)"
KEYS="$(dirname "${CHAIN_FILE:-$DIR/../blockchain-node/data/chain.json}")/ssh-keys.json"
if [ ! -r "$KEYS" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Brauche Leserechte für $KEYS – frage nach dem sudo-Passwort …"
  exec sudo "$0" "$@"
fi
exec node "$DIR/ssh-keys.mjs" "$KEYS"
