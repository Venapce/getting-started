#!/usr/bin/env bash
# Resolve the installed PostgreSQL version dir and exec the server in the
# foreground (supervisord runs this as the postgres user). Only started when
# the internal Postgres is in use (see entrypoint / PG_AUTOSTART).
set -euo pipefail
PG_BIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"
exec "$PG_BIN/postgres" -D "${PGDATA:-/var/lib/superset/pgdata}"
