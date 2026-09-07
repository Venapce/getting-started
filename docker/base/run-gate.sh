#!/usr/bin/env bash
# Wait for the one-shot bootstrap to finish (metadata DB migrated, admin user
# present), then exec the command passed as arguments. Keeps gunicorn from
# crash-looping against an un-migrated database during first boot.
set -euo pipefail
until [ -f /run/superset/bootstrap.done ]; do sleep 2; done
exec "$@"
