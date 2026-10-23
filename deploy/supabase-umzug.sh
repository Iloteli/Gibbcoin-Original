#!/usr/bin/env bash
# Zieht ALLE Daten vom alten Supabase-Projekt ins neue um: Logins (Passwörter bleiben gleich),
# Profile, Wallets, Guthaben, Credits, Transaktionen, Blöcke, Markt, Spiele, Einstellungen usw.
#
# Voraussetzung: Im NEUEN Projekt wurden die 5 Teile aus deploy/neu-supabase ausgeführt.
# Die Verbindungs-Adressen (mit Datenbank-Passwort) tippst du hier selbst ein – sie werden nirgends gespeichert.
# Zu finden in Supabase: Projekt → "Connect" (oben) → "Session pooler" → URI kopieren, [YOUR-PASSWORD] ersetzen.
#
#   sudo gibb-umzug
set -uo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo gibb-umzug" >&2; exit 1; fi
command -v docker >/dev/null 2>&1 || { echo "docker fehlt: sudo apt-get install -y docker.io" >&2; exit 1; }
PG_IMAGE="${PG_IMAGE:-postgres:17}"

echo
echo "GIBB Coin – Umzug ins neue Supabase"
echo "==================================="
echo "Alle Daten im NEUEN Projekt werden dabei ERSETZT (das alte Projekt bleibt unverändert)."
echo
read -r -s -p "Verbindungs-URI des ALTEN Projekts (laduzigqgvvnrqcgfgab): " OLD; echo
read -r -s -p "Verbindungs-URI des NEUEN Projekts (dlcsraxnofbtquhpnleu): " NEW; echo
case "$OLD" in *laduzigqgvvnrqcgfgab*) ;; *) echo "Die alte URI muss laduzigqgvvnrqcgfgab enthalten." >&2; exit 1;; esac
case "$NEW" in *dlcsraxnofbtquhpnleu*) ;; *) echo "Die neue URI muss dlcsraxnofbtquhpnleu enthalten." >&2; exit 1;; esac
read -r -p "Wirklich alle Daten ins neue Projekt übernehmen? Tippe JA: " OK
[ "$OK" = "JA" ] || { echo "Abgebrochen."; exit 1; }

WORK="$(mktemp -d)"; chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
pg() { docker run --rm -i --network host -v "$WORK:/work" "$PG_IMAGE" "$@"; }

echo "==> Verbindungen prüfen"
pg psql "$OLD" -tAc "select 'alt: ' || count(*) || ' Konten' from auth.users" || { echo "Altes Projekt nicht erreichbar (URI/Passwort prüfen)." >&2; exit 1; }
pg psql "$NEW" -tAc "select 'neu: Datenbank bereit' where to_regclass('public.wallets') is not null" | grep -q bereit \
  || { echo "Im neuen Projekt fehlen die Tabellen – zuerst die 5 Teile aus deploy/neu-supabase ausführen." >&2; exit 1; }

echo "==> Daten aus dem alten Projekt holen"
# Nur Daten (die Struktur ist im neuen Projekt schon da). Aus auth nur Benutzer, Logins und 2FA.
pg pg_dump "$OLD" --data-only --no-owner --no-privileges --disable-triggers \
  --schema=public --schema=private \
  --table=auth.users --table=auth.identities --table=auth.mfa_factors \
  --exclude-table='private.node_settings_key*' \
  -f /work/daten.sql || { echo "Export fehlgeschlagen." >&2; exit 1; }
echo "    $(wc -c < "$WORK/daten.sql") Bytes exportiert"

echo "==> Neues Projekt leeren (nur Daten, Struktur bleibt)"
pg psql "$NEW" -v ON_ERROR_STOP=1 -q <<'SQL' || { echo "Leeren fehlgeschlagen." >&2; exit 1; }
do $$
declare r record;
begin
  for r in select format('%I.%I', schemaname, tablename) t from pg_tables where schemaname in ('public', 'private')
           and tablename not like 'node_settings_key%' loop
    execute 'truncate table ' || r.t || ' cascade';
  end loop;
  delete from auth.mfa_factors; delete from auth.identities; delete from auth.users;
end $$;
SQL

echo "==> Daten ins neue Projekt einspielen"
# session_replication_role = replica: Trigger (z. B. "Registrieren gesperrt", neue Wallets) laufen beim Einspielen nicht
{ echo "set session_replication_role = replica;"; cat "$WORK/daten.sql"; echo "set session_replication_role = origin;"; } \
  | pg psql "$NEW" -q 2>"$WORK/fehler.txt" >/dev/null
if [ -s "$WORK/fehler.txt" ]; then
  echo "    Hinweise/Fehler beim Einspielen (Tabellen, die es nur im alten Projekt gab, sind normal):"
  grep -E 'ERROR|FEHLER' "$WORK/fehler.txt" | sort | uniq -c | head -20
fi

echo "==> Ergebnis im neuen Projekt"
pg psql "$NEW" -tA <<'SQL'
select 'Konten:         ' || (select count(*) from auth.users);
select 'Profile:        ' || (select count(*) from public.profiles);
select 'Wallets:        ' || (select count(*) from public.wallets) || ' (zusammen ' || (select coalesce(sum(balance), 0) from public.wallets) || ' GIBB)';
select 'Transaktionen:  ' || (select count(*) from public.transactions);
select 'Blöcke:         ' || (select count(*) from public.blocks);
SQL
echo
echo "Fertig. Logins und Passwörter sind übernommen – alle melden sich wie bisher an."
echo "Danach noch:  sudo gibb-chain-key   (und die ausgegebene Zeile im SQL Editor des NEUEN Projekts ausführen)"
echo "Profilbilder liegen weiter im alten Projekt und werden von dort angezeigt, solange es besteht."
