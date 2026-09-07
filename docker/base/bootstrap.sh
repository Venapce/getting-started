#!/usr/bin/env bash
#
# aio-superset bootstrap (one-shot, run once per boot by supervisord).
#
# Waits for Postgres, (internal only) creates the metadata role + database,
# runs the Superset schema migration, creates the admin user and initializes
# roles/permissions, then drops the gate file that gunicorn waits on.
set -uo pipefail

RUN_DIR=/run/superset

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-superset}"
DB_USER="${DB_USER:-superset}"
DB_PASS="${DB_PASS:-superset}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@venapce.local}"
ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
ADMIN_LAST="${ADMIN_LAST:-Venapce}"

log() { echo "[bootstrap] $*"; }
run_superset() { su -p superset -s /bin/bash -c "$*"; }

# --- 1. wait for the metadata Postgres (internal or shared/external) ---
log "waiting for Postgres at ${DB_HOST}:${DB_PORT}..."
until pg_isready -q -h "$DB_HOST" -p "$DB_PORT"; do sleep 2; done

# --- 2. metadata role + database ---
if [ "${PG_INTERNAL:-true}" = "true" ]; then
    if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" | grep -q 1; then
        log "creating role ${DB_USER}"
        su postgres -c "psql -c \"CREATE ROLE \\\"${DB_USER}\\\" LOGIN PASSWORD '${DB_PASS}'\""
    fi
    if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" | grep -q 1; then
        log "creating database ${DB_NAME}"
        su postgres -c "createdb -O '${DB_USER}' '${DB_NAME}'"
    fi
else
    log "external Postgres — expecting database '${DB_NAME}' + role '${DB_USER}' to already exist (deploy init SQL)"
fi

# --- 3. schema migration ---
log "superset db upgrade"
run_superset "superset db upgrade"

# --- 4. admin user (idempotent) ---
log "ensuring admin user '${ADMIN_USER}'"
run_superset "superset fab create-admin \
    --username '${ADMIN_USER}' \
    --firstname '${ADMIN_FIRST}' \
    --lastname '${ADMIN_LAST}' \
    --email '${ADMIN_EMAIL}' \
    --password '${ADMIN_PASS}'" || log "admin user '${ADMIN_USER}' already exists"

# --- 5. roles + permissions ---
log "superset init (roles + permissions)"
run_superset "superset init"

# --- 5b. optional example datasets/charts/dashboards (needs internet) ---
# Loads into the metadata DB's `examples` schema; handy for testing the builder.
# LOAD_EXAMPLES=true loads them at boot; alternatively an operator can load them
# on demand from Venapce Settings (venapce_control blueprint). The marker file is
# SHARED with that path so both agree on "already loaded" and neither re-downloads.
EXAMPLES_MARKER=/var/lib/superset/venapce/examples.loaded
mkdir -p "$(dirname "$EXAMPLES_MARKER")"
if [ "${LOAD_EXAMPLES:-false}" = "true" ] && [ ! -f "$EXAMPLES_MARKER" ]; then
    log "loading examples (first run downloads data — can take a few minutes)…"
    if run_superset "superset load_examples"; then
        touch "$EXAMPLES_MARKER"
        log "examples loaded"
    else
        log "load_examples failed (no internet?) — continuing without examples"
    fi
fi

# --- 6. open the gate so gunicorn may start ---
touch "$RUN_DIR/bootstrap.done"
log "done — Superset metadata ready, admin '${ADMIN_USER}'"
