#!/usr/bin/env bash
#
# venapce entrypoint (PID 1 for the product image).
#
# Thin wrapper over the base image's entrypoint: it only resets the venapce boot
# gate, then hands off to the base entrypoint, which prepares Postgres + TLS and
# execs supervisord. supervisord then starts the base programs AND the venapce
# programs (venapce-db + venapce-api) it picked up from /etc/supervisor/conf.d.
set -euo pipefail

RUN_DIR=/run/venapce
mkdir -p "$RUN_DIR"
# Fresh boot: force the venapce DB gate closed so venapce-api waits for it.
rm -f "$RUN_DIR/db.done"

exec /opt/superset/entrypoint.sh
