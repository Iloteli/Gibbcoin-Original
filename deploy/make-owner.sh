#!/usr/bin/env bash
# Macht ilja.podorieszach@icloud.com in der EIGENEN Datenbank zum Owner (super_admin).
# Vorher einmal auf der Website mit dieser E-Mail registrieren.
#   sudo bash deploy/make-owner.sh
set -euo pipefail
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
for f in 20260921090000_restore_ilja_owner.sql 20261010100000_admin_mfa_only_if_enrolled.sql; do
  LC_ALL=C sed -e $'1s/^\xEF\xBB\xBF//' -e $'s/\r$//' "$APP_DIR/supabase/migrations/$f" \
    | docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -q -U supabase_admin -d postgres
done
docker exec supabase-db psql -tA -U supabase_admin -d postgres -c \
  "select 'Rolle: ' || coalesce(p.role, '(kein Profil)') from auth.users u left join public.profiles p on p.id = u.id where lower(u.email) = 'ilja.podorieszach@icloud.com'" \
  | grep . || echo "Konto nicht gefunden – zuerst auf der Website registrieren."
