#!/usr/bin/env bash
# Erlaubt dem Server-Benutzer (z. B. m431-g002 – alle verbinden sich damit), die GIBB-Befehle OHNE
# sudo-Passwort auszuführen (auch über die Knöpfe der Chain-Seite). Alle anderen sudo-Befehle brauchen
# weiterhin das Passwort, ebenso "gibb-backup zurueck …", "gibb-chain-key" und "gibb-wartung 30m …".
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
# Erlaubt: root oder der System-Benutzer der App (gibb, ohne Anmeldung). Nicht erlaubt: du selbst
# oder Schreibrechte für Gruppe/andere – dann könntest du über die Knöpfe ohne Passwort root werden.
RUN_USER="${RUN_USER:-gibb}"
pruefe() {
  local p="$1" owner perm
  owner="$(stat -c %U "$p")"; perm="$(stat -c %a "$p")"
  if { [ "$owner" != "root" ] && [ "$owner" != "$RUN_USER" ]; } || [ "$owner" = "$NUTZER" ] || [ $(( 0$perm & 022 )) -ne 0 ]; then
    echo "Abbruch: $p ist für dich oder andere änderbar (Besitzer $owner, Rechte $perm)." >&2
    echo "Erst beheben:  sudo chmod go-w $p" >&2
    exit 1
  fi
}
for p in "$APP_DIR" "$APP_DIR/deploy"; do pruefe "$p"; done
LINES=""
# gibb-Befehle ohne Passwort, jeweils nur genau mit diesen Angaben ("" = ohne Angaben).
# Bleiben mit Passwort: gibb-backup zurueck (überschreibt Daten), gibb-chain-key (neuer Schlüssel),
# gibb-wartung mit Dauer/Text und alle anderen sudo-Befehle.
ERLAUBT=(
  'update|' 'help|' 'version|' 'code|' 'neuladen|'
  'backup|' 'backup|liste' 'backup|auto an' 'backup|auto aus'
  'autoupdate|' 'autoupdate|an' 'autoupdate|aus'
  'wartung|aus'
)
GEPRUEFT=" "
for eintrag in "${ERLAUBT[@]}"; do
  name="${eintrag%%|*}"; angaben="${eintrag#*|}"
  link="/usr/local/bin/gibb-$name"
  [ -e "$link" ] || { echo "Fehlt: $link – zuerst sudo gibb-update ausführen." >&2; exit 1; }
  case "$GEPRUEFT" in *" $name "*) ;; *) pruefe "$(readlink -f "$link")"; GEPRUEFT="$GEPRUEFT$name ";; esac
  if [ -z "$angaben" ]; then LINES="$LINES$NUTZER ALL=(root) NOPASSWD: $link \"\"
"; else LINES="$LINES$NUTZER ALL=(root) NOPASSWD: $link $angaben
"; fi
done

TMP="$(mktemp)"
printf '# GIBB Coin: Knöpfe auf der Chain-Seite (erstellt von gibb-sudo)\n%s' "$LINES" > "$TMP"
if ! visudo -cf "$TMP" >/dev/null; then rm -f "$TMP"; echo "Abbruch: sudoers-Prüfung fehlgeschlagen." >&2; exit 1; fi
install -m 0440 -o root -g root "$TMP" "$FILE"
rm -f "$TMP"
echo "Fertig: $NUTZER kann jetzt ohne Passwort ausführen:"
echo "  sudo gibb-update · gibb-help · gibb-version · gibb-code · gibb-neuladen"
echo "  sudo gibb-backup [liste | auto an | auto aus] · gibb-autoupdate [an | aus] · gibb-wartung aus"
echo "Alle anderen sudo-Befehle fragen weiterhin nach dem Passwort."
echo "Ausschalten: sudo gibb-sudo aus"
