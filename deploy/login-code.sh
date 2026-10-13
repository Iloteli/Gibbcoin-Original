#!/usr/bin/env bash
# Zweiter Faktor für die Owner-Anmeldung auf der Chain-Seite.
# Erzeugt einen 6-stelligen Einmal-Code (5 Minuten gültig, nur einmal nutzbar).
#   sudo gibb-code
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
DIR=/var/lib/gibbcoin
FILE="$DIR/owner-login-code.json"
mkdir -p "$DIR"
CODE="$(node -e 'console.log(String(require("crypto").randomInt(0, 1000000)).padStart(6, "0"))')"
node -e '
  const [file, code] = process.argv.slice(1);
  const hash = require("crypto").createHash("sha256").update(code).digest("hex");
  require("fs").writeFileSync(file, JSON.stringify({ hash, expires: Date.now() + 5 * 60 * 1000 }), { mode: 0o640 });
' "$FILE" "$CODE"
OWNER="$(stat -c %U "$DIR")"; chown "$OWNER" "$FILE" 2>/dev/null || true
echo
echo "  Server-Code: $CODE"
echo
echo "Gültig für 5 Minuten und nur für eine Anmeldung."
