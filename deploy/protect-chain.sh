#!/usr/bin/env bash
# Schützt https://chain.DOMAIN mit einer Browser-Anmeldung: nur der Benutzer "ilja" kommt rein.
# Ohne Angabe wird ein zufälliges Passwort erzeugt und EINMAL angezeigt.
#   sudo bash deploy/protect-chain.sh                 -> neues Zufallspasswort
#   sudo CHAIN_PASSWORD='...' bash deploy/protect-chain.sh   -> eigenes Passwort (mind. 10 Zeichen)
#   sudo bash deploy/protect-chain.sh --off           -> Schutz wieder entfernen
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
AUTH_FILE=/etc/caddy/chain-auth.caddy
CHAIN_USER="${CHAIN_USER:-ilja}"

if [ "${1:-}" = "--off" ]; then
  rm -f "$AUTH_FILE"
  systemctl reload caddy
  echo "Schutz der Chain-Seite entfernt."
  exit 0
fi

PASSWORD="${CHAIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}"
if [ "${#PASSWORD}" -lt 10 ]; then echo "Passwort muss mindestens 10 Zeichen haben." >&2; exit 1; fi
HASH="$(caddy hash-password --plaintext "$PASSWORD")"
cat > "$AUTH_FILE" <<CADDY
basic_auth {
	$CHAIN_USER $HASH
}
CADDY
chmod 640 "$AUTH_FILE"; chown root:caddy "$AUTH_FILE" 2>/dev/null || true

# Caddyfile: Chain-Block importiert die Datei (einmalig ergänzen).
if ! grep -q "import $AUTH_FILE" /etc/caddy/Caddyfile; then
  sed "/^chain\..* {\$/a\	import $AUTH_FILE" /etc/caddy/Caddyfile > /tmp/Caddyfile.new
  grep -q "import $AUTH_FILE" /tmp/Caddyfile.new || { echo "Chain-Block im Caddyfile nicht gefunden – erst deploy/install-https.sh ausführen." >&2; exit 1; }
  cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
  mv /tmp/Caddyfile.new /etc/caddy/Caddyfile
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl reload caddy
echo
echo "Chain-Seite ist jetzt geschützt."
echo "  Benutzername: $CHAIN_USER"
echo "  Passwort:     $PASSWORD"
echo "Notiere das Passwort – es wird nicht gespeichert (nur als Hash)."
