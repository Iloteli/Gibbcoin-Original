#!/usr/bin/env bash
#
# GIBB Coin – eigene Datenbank auf DIESEM Server statt der Supabase-Cloud.
# Installiert die Open-Source-Version von Supabase (Docker), spielt alle Migrationen
# aus supabase/migrations ein, stellt die Edge Functions bereit und baut die
# Website so um, dass sie nur noch diese eigene Instanz nutzt (über /sb im Gateway).
#
# Verwendung (nach install-server.sh, install-website.sh und install-tunnel.sh):
#   sudo bash deploy/install-supabase.sh
#
# Erneut ausführen ist sicher: Secrets bleiben erhalten, bereits eingespielte
# Migrationen werden übersprungen.
set -euo pipefail
RUN_USER="${RUN_USER:-gibb}"
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
DATA_DIR="${DATA_DIR:-/var/lib/gibbcoin}"
SB_DIR="${SB_DIR:-/opt/supabase}"
SECRETS="$DATA_DIR/supabase-secrets.env"
WEBSITE_ENV="$DATA_DIR/website.env"

if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausführen: sudo bash deploy/install-supabase.sh" >&2; exit 1; fi
if [ ! -d "$APP_DIR/.git" ]; then echo "Erst 'sudo bash deploy/install-server.sh' ausführen." >&2; exit 1; fi

MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
echo "==> Arbeitsspeicher: ${MEM_MB} MB"
if [ "$MEM_MB" -lt 3500 ]; then
  echo "WARNUNG: Supabase braucht etwa 4 GB RAM. Mit ${MEM_MB} MB kann es knapp werden." >&2
fi

echo "==> Neueste Version des Projekts holen"
git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" merge -q --ff-only '@{u}' || true

echo "==> Docker installieren (falls nötig)"
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker.io docker-compose-v2 || apt-get install -y docker.io docker-compose-plugin
fi
systemctl enable --now docker
docker compose version >/dev/null

echo "==> Supabase-Docker-Setup holen"
if [ ! -f "$SB_DIR/docker-compose.yml" ]; then
  TMP="$(mktemp -d)"
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase "$TMP/supabase"
  git -C "$TMP/supabase" sparse-checkout set docker
  mkdir -p "$SB_DIR"
  cp -a "$TMP/supabase/docker/." "$SB_DIR/"
  rm -rf "$TMP"
fi
[ -f "$SB_DIR/.env" ] || cp "$SB_DIR/.env.example" "$SB_DIR/.env"

echo "==> Geheimnisse erzeugen (einmalig, bleiben bei erneutem Lauf erhalten)"
mkdir -p "$DATA_DIR"
if [ ! -f "$SECRETS" ]; then
  rand() { openssl rand -hex "$1"; }
  JWT_SECRET="$(rand 32)"
  read -r ANON_KEY SERVICE_ROLE_KEY < <(JWT_SECRET="$JWT_SECRET" node -e '
    const { createHmac } = require("node:crypto");
    const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const sign = (role) => {
      const now = Math.floor(Date.now() / 1000);
      const head = b64({ alg: "HS256", typ: "JWT" });
      const body = b64({ role, iss: "supabase", iat: now, exp: now + 10 * 365 * 24 * 3600 });
      const sig = createHmac("sha256", process.env.JWT_SECRET).update(`${head}.${body}`).digest("base64url");
      return `${head}.${body}.${sig}`;
    };
    console.log(sign("anon"), sign("service_role"));')
  cat > "$SECRETS" <<SECRETS_EOF
POSTGRES_PASSWORD=$(rand 24)
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
DASHBOARD_USERNAME=gibbadmin
DASHBOARD_PASSWORD=$(rand 16)
SECRET_KEY_BASE=$(rand 32)
VAULT_ENC_KEY=$(rand 16)
PG_META_CRYPTO_KEY=$(rand 16)
LOGFLARE_PUBLIC_ACCESS_TOKEN=$(rand 24)
LOGFLARE_PRIVATE_ACCESS_TOKEN=$(rand 24)
POOLER_TENANT_ID=gibbcoin
SECRETS_EOF
  chmod 600 "$SECRETS"
fi
# shellcheck disable=SC1090
set -a; . "$SECRETS"; set +a

PUBLIC_URL="$(cat "$DATA_DIR/public-url-website.txt" 2>/dev/null || echo http://localhost:8080)"
set_env() { # KEY VALUE  -> in $SB_DIR/.env setzen oder ergänzen
  if grep -q "^$1=" "$SB_DIR/.env"; then
    sed -i "s|^$1=.*|$1=$2|" "$SB_DIR/.env"
  else
    echo "$1=$2" >> "$SB_DIR/.env"
  fi
}
for k in POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY DASHBOARD_USERNAME DASHBOARD_PASSWORD \
         SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN POOLER_TENANT_ID; do
  set_env "$k" "${!k}"
done
set_env SITE_URL "$PUBLIC_URL"
set_env ADDITIONAL_REDIRECT_URLS "$PUBLIC_URL/**,http://localhost:3000/**,http://localhost:8080/**"
set_env API_EXTERNAL_URL "$PUBLIC_URL/sb"
set_env SUPABASE_PUBLIC_URL "$PUBLIC_URL/sb"
# Ohne Mailserver: Konten sind sofort aktiv (keine Bestätigungs-Mail nötig).
set_env ENABLE_EMAIL_SIGNUP true
set_env ENABLE_EMAIL_AUTOCONFIRM true
set_env ENABLE_ANONYMOUS_USERS false
set_env DISABLE_SIGNUP false
chmod 600 "$SB_DIR/.env"

echo "==> Edge Functions bereitstellen"
mkdir -p "$SB_DIR/volumes/functions"
for fn in "$APP_DIR"/supabase/functions/*/; do
  name="$(basename "$fn")"
  rm -rf "$SB_DIR/volumes/functions/$name"
  cp -a "$fn" "$SB_DIR/volumes/functions/$name"
done

echo "==> Supabase starten (der erste Start lädt Docker-Images, das dauert einige Minuten)"
cd "$SB_DIR"
docker compose pull -q
docker compose up -d

echo "==> Warte auf die Datenbank"
for i in $(seq 1 90); do
  docker exec supabase-db pg_isready -U postgres -h localhost >/dev/null 2>&1 && break
  sleep 2
done
docker exec supabase-db pg_isready -U postgres -h localhost >/dev/null

psql_db() { docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -q -U supabase_admin -d postgres "$@"; }

echo "==> Migrationen einspielen"
psql_db -c "create schema if not exists gibb_meta; create table if not exists gibb_meta.applied_migrations (name text primary key, applied_at timestamptz not null default now());"
for f in "$APP_DIR"/supabase/migrations/*.sql; do
  name="$(basename "$f")"
  if [ "$(psql_db -tA -c "select 1 from gibb_meta.applied_migrations where name = '$name'")" = "1" ]; then
    continue
  fi
  echo "    -> $name"
  if ! { echo "begin;"; cat "$f"; echo; echo "insert into gibb_meta.applied_migrations(name) values ('$name');"; echo "commit;"; } | psql_db; then
    echo >&2
    echo "FEHLER in Migration $name – Installation angehalten. Bitte diese Ausgabe an Claude schicken." >&2
    exit 1
  fi
done
docker compose restart rest >/dev/null 2>&1 || true

echo "==> Website auf die eigene Instanz umstellen und neu bauen"
cat > "$WEBSITE_ENV" <<WEB_EOF
NEXT_PUBLIC_SUPABASE_URL=/sb
NEXT_PUBLIC_SUPABASE_ANON_KEY=$ANON_KEY
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=$ANON_KEY
WEB_EOF
chmod 644 "$WEBSITE_ENV"
PNPM_BIN="$(command -v pnpm)"
chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR"
sudo -u "$RUN_USER" env HOME="/home/$RUN_USER" bash -lc "set -a; . '$WEBSITE_ENV'; set +a; cd '$APP_DIR' && '$PNPM_BIN' install --frozen-lockfile && NODE_OPTIONS=--max-old-space-size=3072 '$PNPM_BIN' run build"
chmod -R a+rX "$APP_DIR"
systemctl restart gibb-website.service
systemctl restart gibb-gateway.service 2>/dev/null || true

echo
echo "============================================================"
echo " Eigene Datenbank läuft. Die Website nutzt KEINE Cloud mehr."
echo "   Website:   $PUBLIC_URL"
echo "   Supabase:  $PUBLIC_URL/sb   (intern: http://localhost:8000)"
echo "   Studio (Datenbank-Oberfläche) über SSH-Tunnel:"
echo "     ssh -L 8000:localhost:8000 $(logname 2>/dev/null || echo USER)@SERVER  ->  http://localhost:8000"
echo "     Benutzer: $DASHBOARD_USERNAME   Passwort: siehe $SECRETS"
echo
echo " Nächster Schritt: auf der Website registrieren (ilja.podorieszach@icloud.com),"
echo " danach:  sudo bash deploy/make-owner.sh"
echo "============================================================"
