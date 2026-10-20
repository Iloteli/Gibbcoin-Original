#!/usr/bin/env bash
# Neue Datenbank-Migrationen in die eigene Supabase-Datenbank (Docker) einspielen.
# Läuft automatisch bei jedem Update; ohne eigene Datenbank (Supabase-Cloud) passiert nichts.
# Bereits eingespielte Migrationen werden übersprungen (Liste in gibb_meta.applied_migrations).
set -uo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB_DIR="${SB_DIR:-/opt/supabase}"
command -v docker >/dev/null 2>&1 || exit 0
[ "$(docker inspect -f '{{.State.Running}}' supabase-db 2>/dev/null)" = "true" ] || exit 0
psql_db() { docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -q -U supabase_admin -d postgres "$@"; }
# Ohne Liste wurde die Datenbank nicht mit install-supabase.sh eingerichtet -> nichts anfassen
[ "$(psql_db -tA -c "select to_regclass('gibb_meta.applied_migrations') is not null")" = "t" ] || exit 0
clean_sql() { LC_ALL=C sed -e $'1s/^\xEF\xBB\xBF//' -e $'s/\r$//' "$1"; }
applied=0
for f in "$APP_DIR"/supabase/migrations/*.sql; do
  name="$(basename "$f")"
  [ "$(psql_db -tA -c "select 1 from gibb_meta.applied_migrations where name = '$name'")" = "1" ] && continue
  echo "Datenbank: $name"
  if ! { echo "begin;"; clean_sql "$f"; echo; echo "insert into gibb_meta.applied_migrations(name) values ('$name');"; echo "commit;"; } | psql_db; then
    echo "FEHLER in $name – weitere Migrationen übersprungen." >&2
    break
  fi
  applied=$((applied + 1))
done
if [ "$applied" -gt 0 ]; then
  [ -f "$APP_DIR/deploy/selfhost-final.sql" ] && clean_sql "$APP_DIR/deploy/selfhost-final.sql" | psql_db
  (cd "$SB_DIR" 2>/dev/null && docker compose restart rest >/dev/null 2>&1) || true
  echo "Datenbank: $applied neue Migration(en) eingespielt"
fi
