#!/usr/bin/env bash
# Erlaubt dem eigenen Server-Benutzer, genau diese GIBB-Befehle OHNE sudo-Passwort auszuführen
# (für die Knöpfe auf der Chain-Seite): gibb-update, gibb-help, gibb-backup, gibb-version, gibb-code.
# Nur ohne zusätzliche Angaben – "sudo gibb-backup zurueck …" usw. fragen weiter nach dem Passwort.
#   sudo gibb-sudo            -> einschalten (für den Benutzer, der sudo aufruft)
#   sudo gibb-sudo aus        -> wieder ausschalten
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo gibb-sudo" >&2; exit 1; fi
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
FILE=/etc/sudoers.d/gibbcoin-knoepfe
NUTZER="${SUDO_USER:-}"

if [ "${1:-}" = "aus" ] || [ "${1:-}" = "--off" ]; then
  rm -f "$FILE"
  echo "Aus: GIBB-Befehle fragen wieder nach dem sudo-Passwort."
  exit 0
fi
if [ -z "$NUTZER" ] || [ "$NUTZER" = "root" ]; then echo "Bitte als normaler Benutzer mit sudo starten (nicht als root)." >&2; exit 1; fi

# Sicherheit: Wer die Skripte ändern kann, könnte sonst alles als root ausführen.
for p in "$APP_DIR" "$APP_DIR/deploy"; do
  owner="$(stat -c %U "$p")"; perm="$(stat -c %a "$p")"
  if [ "$owner" != "root" ] || [ $(( 0$perm & 022 )) -ne 0 ]; then
    echo "Abbruch: $p gehört nicht root oder ist für andere beschreibbar ($owner, $perm)." >&2
    echo "Erst beheben:  sudo chown root:root $p && sudo chmod go-w $p" >&2
    exit 1
  fi
done
LINES=""
for name in update help backup version code; do
  link="/usr/local/bin/gibb-$name"
  [ -e "$link" ] || { echo "Fehlt: $link – zuerst sudo gibb-update ausführen." >&2; exit 1; }
  target="$(readlink -f "$link")"
  owner="$(stat -c %U "$target")"; perm="$(stat -c %a "$target")"
  if [ "$owner" != "root" ] || [ $(( 0$perm & 022 )) -ne 0 ]; then
    echo "Abbruch: $target gehört nicht root oder ist für andere beschreibbar ($owner, $perm)." >&2
    exit 1
  fi
  # "" = keine zusätzlichen Argumente erlaubt
  LINES="$LINES$NUTZER ALL=(root) NOPASSWD: $link \"\"
"
done

TMP="$(mktemp)"
printf '# GIBB Coin: Knöpfe auf der Chain-Seite (erstellt von gibb-sudo)\n%s' "$LINES" > "$TMP"
if ! visudo -cf "$TMP" >/dev/null; then rm -f "$TMP"; echo "Abbruch: sudoers-Prüfung fehlgeschlagen." >&2; exit 1; fi
install -m 0440 -o root -g root "$TMP" "$FILE"
rm -f "$TMP"
echo "Fertig: $NUTZER kann jetzt ohne Passwort ausführen:"
echo "  sudo gibb-update · sudo gibb-help · sudo gibb-backup · sudo gibb-version · sudo gibb-code"
echo "Ausschalten: sudo gibb-sudo aus"
