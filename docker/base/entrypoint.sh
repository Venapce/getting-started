#!/usr/bin/env bash
#
# venapce-base entrypoint (PID 1).
#
# Decides internal vs. external Postgres, prepares persistent state on first
# boot (initializes the internal PostgreSQL cluster only when used, generates a
# self-signed TLS cert if none is mounted), then hands off to supervisord which
# runs postgres (optional) + the one-shot bootstrap + gunicorn + nginx.
#
# Superset here is a synchronous BI engine: no Redis, no Celery. Caching is a
# filesystem cache on the persistent volume, and the metadata database is the
# in-container PostgreSQL (not sqlite). Async SQL Lab / Alerts & Reports /
# thumbnails — the only features that would need a broker — are off.
#
# External Postgres is selected when SUPERSET_DB_URI is set OR DB_HOST is not
# a loopback address. In that case the internal Postgres is NOT started and the
# shared instance is expected to already hold the `superset` database + role
# (the deploy compose's init SQL creates it).
set -euo pipefail

STATE_DIR=/var/lib/superset
PGDATA="${PGDATA:-$STATE_DIR/pgdata}"
CACHE_DIR="$STATE_DIR/cache"
TLS_DIR=/opt/superset/tls
RUN_DIR=/run/superset

PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
DB_HOST="${DB_HOST:-127.0.0.1}"

# --- internal vs external Postgres ---------------------------------------
if [ -n "${SUPERSET_DB_URI:-}" ] || { [ "$DB_HOST" != "127.0.0.1" ] && [ "$DB_HOST" != "localhost" ]; }; then
    export PG_INTERNAL=false
    export PG_AUTOSTART=false
    echo "[entrypoint] using EXTERNAL Postgres (DB_HOST=$DB_HOST${SUPERSET_DB_URI:+, SUPERSET_DB_URI set})"
else
    export PG_INTERNAL=true
    export PG_AUTOSTART=true
    echo "[entrypoint] using INTERNAL Postgres at $PGDATA"
fi
export PGDATA DB_HOST

PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$PG_BIN" ] && export PATH="$PG_BIN:$PATH"

echo "[entrypoint] venapce-base starting (host=$PUBLIC_HOST)"
case "${SUPERSET_SECRET_KEY:-}" in
    ""|CHANGE_ME_*)
        echo "[entrypoint] WARNING: SUPERSET_SECRET_KEY is unset/default — set a real value (openssl rand -base64 42)" >&2 ;;
esac

mkdir -p "$STATE_DIR" "$TLS_DIR" "$RUN_DIR" /var/log/supervisor /var/run/postgresql
chmod 0755 "$RUN_DIR"

# --- internal PostgreSQL cluster (first boot only) ---
if [ "$PG_INTERNAL" = "true" ]; then
    chown -R postgres:postgres "$STATE_DIR" /var/run/postgresql 2>/dev/null || true
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        echo "[entrypoint] initializing PostgreSQL cluster at $PGDATA"
        mkdir -p "$PGDATA"
        chown postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"
        su postgres -c "$PG_BIN/initdb -D '$PGDATA' -E UTF8 --auth-local=peer --auth-host=scram-sha-256"
        {
            echo "listen_addresses = '127.0.0.1'"
            echo "unix_socket_directories = '/var/run/postgresql'"
        } >> "$PGDATA/postgresql.conf"
        {
            echo "host all all 127.0.0.1/32 scram-sha-256"
            echo "host all all ::1/128 scram-sha-256"
        } >> "$PGDATA/pg_hba.conf"
    fi
fi

# --- TLS certificate for nginx (self-signed unless one is mounted) ---
if [ ! -f "$TLS_DIR/tls.crt" ] || [ ! -f "$TLS_DIR/tls.key" ]; then
    echo "[entrypoint] generating self-signed certificate for CN=$PUBLIC_HOST"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
        -subj "/CN=$PUBLIC_HOST" \
        -addext "subjectAltName=DNS:$PUBLIC_HOST,DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 0644 "$TLS_DIR/tls.crt" "$TLS_DIR/tls.key"
fi

# Superset's filesystem cache. Must be writable by the superset user — in
# internal-Postgres mode the rest of $STATE_DIR is owned by postgres — so give it
# its own dir, chowned here after any internal-Postgres chown of $STATE_DIR.
mkdir -p "$CACHE_DIR"
chown -R superset:superset "$CACHE_DIR" 2>/dev/null || true

# Venapce control state (on-demand examples load: status/marker/log). Must be
# writable by the superset user — in internal-Postgres mode the rest of
# $STATE_DIR is owned by postgres — so give the loader its own dir. Kept here,
# after any internal-Postgres chown of $STATE_DIR.
mkdir -p "$STATE_DIR/venapce"
chown superset:superset "$STATE_DIR/venapce" 2>/dev/null || true

# Fresh boot: force the bootstrap gate closed so services wait for it.
rm -f "$RUN_DIR/bootstrap.done"

echo "[entrypoint] handing off to supervisord"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
