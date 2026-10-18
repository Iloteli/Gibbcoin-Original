#!/usr/bin/env bash
# Schützt https://chain.DOMAIN mit einer Browser-Anmeldung: nur der Benutzer "ilja" kommt rein.
# Ohne Angabe wird ein zufälliges Passwort erzeugt und EINMAL angezeigt.
# (Nutzt "basicauth" – die Schreibweise, die alle Caddy-2-Versionen verstehen.)
#   sudo bash deploy/protect-chain.sh                 -> neues Zufallspasswort
#   sudo CHAIN_PASSWORD='...' bash deploy/protect-chain.sh   -> eigenes Passwort (mind. 10 Zeichen)
#   sudo bash deploy/protect-chain.sh --off           -> Schutz wieder entfernen
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
AUTH_FILE=/etc/caddy/chain-auth.caddy
CHAIN_USER="${CHAIN_USER:-ilja}"

if [ "${1:-}" = "--off" ]; then
  # Import-Zeile aus dem Caddyfile nehmen, sonst lädt Caddy die fehlende Datei nicht
  if grep -q "import $AUTH_FILE" /etc/caddy/Caddyfile; then
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
    grep -v "import $AUTH_FILE" /etc/caddy/Caddyfile.bak > /etc/caddy/Caddyfile
  fi
  rm -f "$AUTH_FILE"
  if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    echo "Caddy-Konfiguration ungültig – alte Datei wird wiederhergestellt." >&2
    [ -f /etc/caddy/Caddyfile.bak ] && cp /etc/caddy/Caddyfile.bak /etc/caddy/Caddyfile
    exit 1
  fi
  systemctl reload caddy
  echo "Schutz der Chain-Seite entfernt – kein Browser-Anmeldefenster mehr."
  exit 0
fi

PASSWORD="${CHAIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}"
if [ "${#PASSWORD}" -lt 10 ]; then echo "Passwort muss mindestens 10 Zeichen haben." >&2; exit 1; fi
HASH="$(caddy hash-password --plaintext "$PASSWORD")"
cat > "$AUTH_FILE" <<CADDY
basicauth {
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
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  echo "Caddy-Konfiguration ungültig – Schutz wird zurückgenommen." >&2
  rm -f "$AUTH_FILE"
  [ -f /etc/caddy/Caddyfile.bak ] && cp /etc/caddy/Caddyfile.bak /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  exit 1
fi
systemctl reload caddy
echo
echo "Chain-Seite ist jetzt geschützt."
echo "  Benutzername: $CHAIN_USER"
echo "  Passwort:     $PASSWORD"
echo "Notiere das Passwort – es wird nicht gespeichert (nur als Hash)."
