#!/usr/bin/env bash
#
# run-venapce — launch the venapce-api Go backend (supervisord program, prio 350).
#
# Waits for the two things the API needs before it can come up cleanly:
#   1. /run/venapce/db.done       — the `venapce` role + database exist
#   2. /run/superset/bootstrap.done — Superset metadata is migrated + the admin
#      user exists, so the API's on-boot "provision Superset" step can log in and
#      register this Postgres as a Superset database connection.
#
# Then it derives the API's environment from the container's env — the pieces that
# describe how to reach the in-container Superset and Postgres, plus the FloMorphic
# credential the installer wired in — and execs the binary.
set -euo pipefail

echo "[venapce-api] waiting for the venapce database..."
until [ -f /run/venapce/db.done ]; do sleep 2; done
echo "[venapce-api] waiting for the Superset bootstrap gate..."
until [ -f /run/superset/bootstrap.done ]; do sleep 2; done

# Everything below lives in ONE container, so the API reaches Postgres and
# Superset over loopback. Values the operator may set (secrets, FloMorphic wiring,
# the Superset admin) are read from the container env with sensible defaults.
VENAPCE_DB_USER="${VENAPCE_DB_USER:-venapce}"
VENAPCE_DB_PASS="${VENAPCE_DB_PASS:-venapce}"
VENAPCE_DB_NAME="${VENAPCE_DB_NAME:-venapce}"

export PORT="${VENAPCE_API_PORT:-8091}"
export DATABASE_URL="postgres://${VENAPCE_DB_USER}:${VENAPCE_DB_PASS}@127.0.0.1:5432/${VENAPCE_DB_NAME}?sslmode=disable"
export APP_SECRET_KEY="${VENAPCE_APP_SECRET:-dev-insecure-change-me}"
# The panel is same-origin (served by the same nginx as /api), so CORS is not
# needed in the default single-origin setup; default to permissive and let an
# operator pin it when the panel is served from a different origin.
export CORS_ORIGINS="${VENAPCE_CORS_ORIGINS:-*}"

# Built-in Superset, reached in-container over loopback. The admin here is the
# very same admin the base bootstrap created, so the backend self-configures the
# Superset connection with no one typing credentials in Settings.
export SUPERSET_URL="http://127.0.0.1:8088"
export SUPERSET_ADMIN_USER="${ADMIN_USER:-admin}"
export SUPERSET_ADMIN_PASS="${ADMIN_PASS:-admin}"

# Superset registers THIS Postgres as an analytics connection. Superset reaches it
# over the same loopback, as the venapce role.
export SUPERSET_DB_HOST="127.0.0.1"
export SUPERSET_DB_PORT="5432"
export SUPERSET_DB_DATABASE="${VENAPCE_DB_NAME}"
export SUPERSET_DB_USER="${VENAPCE_DB_USER}"
export SUPERSET_DB_PASSWORD="${VENAPCE_DB_PASS}"
export SUPERSET_DB_SSLMODE="disable"

# FloMorphic access — Venapce runs as a FloMorphic plugin. The installer captures
# these from the FloMorphic instance (its API URL + shared API_JWT_SECRET) and
# passes them through as container env. Left empty, the "Connect FloMorphic"
# action is simply unavailable until set.
export FLOMORPHIC_URL="${FLOMORPHIC_URL:-}"
export FLOMORPHIC_JWT_SECRET="${FLOMORPHIC_JWT_SECRET:-}"
export INFRA_HOST="${INFRA_HOST:-}"

echo "[venapce-api] starting on :${PORT} (db=${VENAPCE_DB_NAME}, superset=loopback:8088, flomorphic=${FLOMORPHIC_URL:-<unset>})"
exec /opt/venapce/venapce-api
