#!/usr/bin/env bash
# E-Mails der Hauptseite (Registrieren bestätigen, Passwort vergessen, E-Mail ändern) über DEINE E-Mail-Adresse
# verschicken – für die eigene Supabase auf diesem Server.
#   sudo gibb-email            -> einrichten (fragt Adresse und App-Passwort)
#   sudo gibb-email test [ADRESSE] -> Test-Mail an dich (oder an ADRESSE) schicken
#   sudo gibb-email status     -> zeigt, ob und womit Mails verschickt werden
#   sudo gibb-email aus        -> wieder aus (Konten werden dann ohne Bestätigungs-Mail sofort aktiv)
# Das Passwort steht nur in /opt/supabase/.env auf dem Server (nur root lesbar), nie im Code oder auf GitHub.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo gibb-email" >&2; exit 1; fi
SB_DIR="${SB_DIR:-/opt/supabase}"
ENV_FILE="$SB_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Keine eigene Supabase gefunden ($ENV_FILE fehlt)." >&2; exit 1; }

get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed "s/^'\(.*\)'$/\1/"; }
# KEY=VALUE sicher setzen (auch mit Sonderzeichen im Passwort)
set_env() {
  KEY="$1" VALUE="$2" FILE="$ENV_FILE" node -e '
    const fs = require("fs");
    const { KEY, VALUE, FILE } = process.env;
    const v = /^[A-Za-z0-9._@:\/+-]*$/.test(VALUE) ? VALUE : "\x27" + VALUE.replace(/\x27/g, "") + "\x27";
    const lines = fs.readFileSync(FILE, "utf8").split("\n");
    let found = false;
    const out = lines.map((l) => (l.startsWith(KEY + "=") ? ((found = true), `${KEY}=${v}`) : l));
    if (!found) out.splice(out[out.length - 1] === "" ? out.length - 1 : out.length, 0, `${KEY}=${v}`);
    fs.writeFileSync(FILE, out.join("\n"));
  '
  chmod 600 "$ENV_FILE"
}
restart_auth() {
  echo "Supabase-Anmeldedienst wird neu gestartet …"
  (cd "$SB_DIR" && docker compose up -d --force-recreate auth >/dev/null 2>&1) || { echo "Neustart fehlgeschlagen – bitte: cd $SB_DIR && docker compose up -d auth" >&2; exit 1; }
}
send_test() { # an, host, port, user, pass, absender
  local to="$1" host="$2" port="$3" user="$4" pass="$5" from="$6" msg
  msg="$(mktemp)"; chmod 600 "$msg"
  # Mit Datum und Message-ID – ohne diese Angaben verwerfen Anbieter wie iCloud Mails oft still
  printf 'From: GIBB Coin <%s>\r\nTo: <%s>\r\nSubject: GIBB Coin: Test-Mail\r\nDate: %s\r\nMessage-ID: <%s.gibbcoin@%s>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\nHallo!\r\n\r\nWenn du das liest, verschickt GIBB Coin E-Mails jetzt über %s.\r\n\r\nGIBB Coin\r\n' \
    "$from" "$to" "$(LC_ALL=C date -R)" "$(date +%s%N)" "${from##*@}" "$from" > "$msg"
  local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'user = "%s:%s"\n' "$user" "$pass" > "$cfg"   # Passwort nicht in der Prozessliste zeigen
  if curl -sS --max-time 30 --ssl-reqd --url "smtp://$host:$port" -K "$cfg" --mail-from "$from" --mail-rcpt "$to" -T "$msg"; then
    rm -f "$msg" "$cfg"; echo "✔ Test-Mail an $to verschickt – schau in dein Postfach (auch Spam)."; return 0
  fi
  rm -f "$msg" "$cfg"; return 1
}

case "${1:-}" in
  status)
    if [ "$(get GIBB_SMTP)" = "1" ]; then echo "An: Mails kommen von $(get SMTP_ADMIN_EMAIL) über $(get SMTP_HOST):$(get SMTP_PORT). Bestätigungs-Mail bei Registrierung: $( [ "$(get ENABLE_EMAIL_AUTOCONFIRM)" = "false" ] && echo ja || echo nein)"
    else echo "Aus: Supabase verschickt keine echten Mails (Konten sind sofort aktiv)."; fi
    exit 0 ;;
  test)
    [ "$(get GIBB_SMTP)" = "1" ] || { echo "Noch nicht eingerichtet: sudo gibb-email" >&2; exit 1; }
    send_test "${2:-$(get SMTP_ADMIN_EMAIL)}" "$(get SMTP_HOST)" "$(get SMTP_PORT)" "$(get SMTP_USER)" "$(get SMTP_PASS)" "$(get SMTP_ADMIN_EMAIL)" || { echo "✖ Senden fehlgeschlagen." >&2; exit 1; }
    exit 0 ;;
  aus|--off)
    set_env GIBB_SMTP 0
    set_env ENABLE_EMAIL_AUTOCONFIRM true
    restart_auth
    echo "Aus: keine Mails mehr, neue Konten sind sofort aktiv."
    exit 0 ;;
esac

echo "E-Mails der Hauptseite über deine eigene Adresse verschicken."
read -r -p "Deine E-Mail-Adresse [ilja.podorieszach@icloud.com]: " EMAIL
EMAIL="${EMAIL:-ilja.podorieszach@icloud.com}"
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "Ungültige Adresse." >&2; exit 1; }
DOMAIN="${EMAIL##*@}"; DOMAIN="${DOMAIN,,}"
case "$DOMAIN" in
  icloud.com|me.com|mac.com) HOST=smtp.mail.me.com; PORT=587
    echo "iCloud: Du brauchst ein App-Passwort (nicht dein Apple-ID-Passwort):"
    echo "  appleid.apple.com → Anmelden und Sicherheit → App-spezifische Passwörter → neues erstellen (z. B. „GIBB Coin“)" ;;
  gmail.com|googlemail.com) HOST=smtp.gmail.com; PORT=587
    echo "Gmail: Du brauchst ein App-Passwort: myaccount.google.com/apppasswords (2-Schritt-Bestätigung muss an sein)" ;;
  outlook.com|hotmail.com|live.com|outlook.ch|hotmail.ch) HOST=smtp-mail.outlook.com; PORT=587 ;;
  *) read -r -p "SMTP-Server deines Anbieters: " HOST; read -r -p "Port [587]: " PORT; PORT="${PORT:-587}" ;;
esac
read -r -s -p "App-Passwort: " PASS; echo
[ -n "$PASS" ] || { echo "Kein Passwort eingegeben." >&2; exit 1; }
read -r -p "Absendername [GIBB Coin]: " NAME
NAME="${NAME:-GIBB Coin}"

echo "Prüfe die Anmeldung beim Mail-Server mit einer Test-Mail an dich …"
send_test "$EMAIL" "$HOST" "$PORT" "$EMAIL" "$PASS" "$EMAIL" || {
  echo "✖ Das hat nicht geklappt. Häufige Gründe: falsches App-Passwort, oder der Server darf Port $PORT nicht nach aussen benutzen." >&2
  echo "  Es wurde nichts geändert." >&2
  exit 1
}

set_env SMTP_ADMIN_EMAIL "$EMAIL"
set_env SMTP_HOST "$HOST"
set_env SMTP_PORT "$PORT"
set_env SMTP_USER "$EMAIL"
set_env SMTP_PASS "$PASS"
set_env SMTP_SENDER_NAME "$NAME"
set_env ENABLE_EMAIL_AUTOCONFIRM false   # Registrieren: Bestätigungs-Mail schicken
set_env GIBB_SMTP 1
restart_auth
echo
echo "Fertig: Registrieren, Passwort vergessen und E-Mail ändern schicken jetzt Mails von $EMAIL."
echo "Neue Konten müssen ihre E-Mail bestätigen. Ausschalten: sudo gibb-email aus"
