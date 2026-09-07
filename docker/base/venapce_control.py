"""
Venapce control blueprint — a tiny, admin-only surface mounted inside Superset.

It lets the Venapce backend trigger operator actions (currently: load Superset's
example datasets/charts/dashboards for a demo) over the SAME authenticated
channel it already uses — the service-account bearer token — with no extra port,
process, or docker socket. Registered from superset_config.py via
FLASK_APP_MUTATOR.

Endpoints (all require a valid Superset JWT belonging to an Admin):
    POST /venapce/examples/load    -> start `superset load_examples` in the
                                      background. Idempotent: 200 if already
                                      loaded, 409 if a load is in progress.
    GET  /venapce/examples/status  -> {"state","message","updatedAt"}
                                      state ∈ idle | running | loaded | failed

State lives in a small JSON file on the persistent volume so it survives gunicorn
worker recycling. The `examples.loaded` marker is shared with bootstrap.sh so the
boot-time LOAD_EXAMPLES path and this on-demand path agree on "already loaded".
"""

from __future__ import annotations

import json
import os
import subprocess
import time

from flask import Blueprint, current_app, jsonify
from flask_jwt_extended import get_jwt_identity, jwt_required

# Superset user-writable state dir (created + chowned by entrypoint.sh). Keeping
# everything here matters: in internal-Postgres mode entrypoint chowns the rest
# of /var/lib/superset to the postgres user, which the superset (gunicorn) user
# cannot write to.
STATE_DIR = os.environ.get("VENAPCE_STATE_DIR", "/var/lib/superset/venapce")
STATUS_FILE = os.path.join(STATE_DIR, "examples.status.json")
LOADED_MARKER = os.path.join(STATE_DIR, "examples.loaded")
LOAD_LOG = os.path.join(STATE_DIR, "examples.load.log")

venapce_bp = Blueprint("venapce_control", __name__, url_prefix="/venapce")


# --------------------------------------------------------------------------- #
# auth — reuse Superset's own JWT (the token the backend already holds)
# --------------------------------------------------------------------------- #
def _current_admin():
    """Return the authenticated Admin user, or None if not found / not an admin.

    The JWT subject is the user id; some flask-jwt-extended versions encode it as
    a string, so coerce before the lookup.
    """
    sm = current_app.appbuilder.sm
    try:
        user = sm.get_user_by_id(int(get_jwt_identity()))
    except (TypeError, ValueError):
        user = None
    if user is None:
        return None
    admin = sm.find_role("Admin")
    return user if admin in user.roles else None


# --------------------------------------------------------------------------- #
# status helpers
# --------------------------------------------------------------------------- #
def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _write_status(state: str, message: str = "", pid: int | None = None) -> dict:
    status = {"state": state, "message": message, "updatedAt": _now()}
    if pid is not None:
        status["pid"] = pid
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(status, fh)
    os.replace(tmp, STATUS_FILE)
    return status


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (OSError, ProcessLookupError):
        return False
    return True


def _read_status() -> dict:
    """
    Resolve the current state, reconciling a stale 'running' record against the
    live process and the shared marker so a crashed worker can't wedge us.
    """
    raw = None
    if os.path.exists(STATUS_FILE):
        try:
            with open(STATUS_FILE, encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError):
            raw = None

    if raw is None:
        # No record yet: loaded if the marker is there (e.g. boot-time load),
        # otherwise never started.
        state = "loaded" if os.path.exists(LOADED_MARKER) else "idle"
        return {"state": state, "message": "", "updatedAt": _now()}

    if raw.get("state") == "running":
        pid = raw.get("pid")
        if not pid or not _pid_alive(pid):
            # The loader exited: the marker tells us whether it succeeded.
            if os.path.exists(LOADED_MARKER):
                return _write_status("loaded", "Example data loaded.")
            return _write_status("failed", "Loader exited before finishing (see examples.load.log).")
    return raw


# --------------------------------------------------------------------------- #
# routes
# --------------------------------------------------------------------------- #
@venapce_bp.get("/examples/status")
@jwt_required()
def examples_status():
    if _current_admin() is None:
        return jsonify(error="admin privileges required"), 403
    return jsonify(_read_status())


@venapce_bp.post("/examples/load")
@jwt_required()
def examples_load():
    if _current_admin() is None:
        return jsonify(error="admin privileges required"), 403

    current = _read_status()
    if current["state"] == "running":
        return jsonify(current), 409
    if current["state"] == "loaded":
        # Already loaded — idempotent no-op (the datasets are in the DB).
        return jsonify(current), 200

    # Kick off `superset load_examples` detached. A trailing `touch` of the
    # shared marker records success; failure leaves the marker absent, which
    # _read_status() surfaces as "failed".
    os.makedirs(STATE_DIR, exist_ok=True)
    cmd = f"superset load_examples && touch {LOADED_MARKER!r}"
    logfh = open(LOAD_LOG, "ab", buffering=0)
    try:
        proc = subprocess.Popen(  # noqa: S603 — fixed command, no user input
            ["bash", "-c", cmd],
            stdout=logfh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    finally:
        logfh.close()
    status = _write_status("running", "Loading example data…", pid=proc.pid)
    return jsonify(status), 202


def register(app) -> None:
    """Attach the blueprint and exempt it from CSRF (it is JWT-authenticated)."""
    app.register_blueprint(venapce_bp)
    csrf = app.extensions.get("csrf")
    if csrf is not None:
        csrf.exempt(venapce_bp)
