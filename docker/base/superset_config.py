# venapce-base — Superset configuration, driven entirely by environment.
#
# Mounted at /app/pythonpath/superset_config.py (SUPERSET_CONFIG_PATH). Every
# knob reads from os.environ so the same image works standalone (internal
# Postgres) or against a shared external Postgres (see the deploy compose). The
# metadata database is PostgreSQL — never sqlite — and caching is a filesystem
# cache; there is no Redis and no Celery in this image.
import os


def _bool(name: str, default: bool) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


# ---------------------------------------------------------------------------
# Metadata database (Superset's own state: dashboards, charts, users, roles).
# NOT the analytics data you visualize — those are added as Database
# connections in the UI/API and live in ClickHouse/Postgres/MySQL.
#
# Always PostgreSQL. By default it is the PostgreSQL running IN THIS CONTAINER
# (DB_HOST=127.0.0.1), so Superset never falls back to sqlite. Precedence:
#   1. SUPERSET_DB_URI  — a full SQLAlchemy URI (used by the shared-Postgres
#      deployment, e.g. postgresql+psycopg2://superset:pw@postgres:5432/superset)
#   2. otherwise assembled from DB_* (the in-container Postgres by default)
# ---------------------------------------------------------------------------
_db_uri = os.environ.get("SUPERSET_DB_URI")
if not _db_uri:
    _db_uri = (
        "postgresql+psycopg2://"
        f"{os.environ.get('DB_USER', 'superset')}:"
        f"{os.environ.get('DB_PASS', 'superset')}@"
        f"{os.environ.get('DB_HOST', '127.0.0.1')}:"
        f"{os.environ.get('DB_PORT', '5432')}/"
        f"{os.environ.get('DB_NAME', 'superset')}"
    )
SQLALCHEMY_DATABASE_URI = _db_uri

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "CHANGE_ME_super_insecure_default_key")

# ---------------------------------------------------------------------------
# Caching — filesystem, on the persistent volume. No Redis.
#
# This appliance runs Superset as a SYNCHRONOUS BI engine: the features that
# would need a broker (async SQL Lab, Alerts & Reports, thumbnails) are off, so
# there is no Celery and no Redis to operate. A FileSystemCache in $CACHE_DIR is
# shared across the gunicorn workers and survives restarts. To scale out later,
# point these at a Redis/Memcached instance and re-enable Celery.
# ---------------------------------------------------------------------------
_cache_dir = os.environ.get("SUPERSET_CACHE_DIR", "/var/lib/superset/cache")


def _fs_cache(subdir: str, timeout: int = 300) -> dict:
    return {
        "CACHE_TYPE": "FileSystemCache",
        "CACHE_DEFAULT_TIMEOUT": timeout,
        "CACHE_DIR": os.path.join(_cache_dir, subdir),
        "CACHE_THRESHOLD": 20000,
    }


CACHE_CONFIG = _fs_cache("default")
DATA_CACHE_CONFIG = _fs_cache("data")
FILTER_STATE_CACHE_CONFIG = _fs_cache("filter_state", timeout=86400)
EXPLORE_FORM_DATA_CACHE_CONFIG = _fs_cache("explore_form", timeout=86400)

# SQL Lab result storage (used only when SQL Lab runs async — off here — but
# Superset still expects a backend object). Keep it on the filesystem.
from cachelib.file import FileSystemCache  # noqa: E402

RESULTS_BACKEND = FileSystemCache(os.path.join(_cache_dir, "sqllab_results"), default_timeout=86400)

# ---------------------------------------------------------------------------
# CORS — let the Venapce Vue front call the API directly (headless model).
# Comma-separated origins in SUPERSET_CORS_ORIGINS; "*" allowed for dev.
# ---------------------------------------------------------------------------
ENABLE_CORS = _bool("SUPERSET_ENABLE_CORS", True)
_origins = os.environ.get("SUPERSET_CORS_ORIGINS", "http://localhost:5173")
CORS_OPTIONS = {
    "supports_credentials": True,
    "allow_headers": ["*"],
    "resources": ["/api/*"],
    "origins": ["*"] if _origins.strip() == "*" else [o.strip() for o in _origins.split(",") if o.strip()],
}

# ---------------------------------------------------------------------------
# CSRF — Superset's CSRF is session-cookie based. For a headless Bearer client
# the cleanest path is to disable it (dev) or exempt the data endpoint.
# ---------------------------------------------------------------------------
WTF_CSRF_ENABLED = _bool("SUPERSET_CSRF_ENABLED", False)
WTF_CSRF_EXEMPT_LIST = ["superset.charts.data.api.ChartDataRestApi.data"]

# Behind our own nginx (TLS terminator) / a Venapce proxy.
ENABLE_PROXY_FIX = True
PREFERRED_URL_SCHEME = "https"

# ---------------------------------------------------------------------------
# Feature flags — per-space multi-tenancy needs DASHBOARD_RBAC (study §6).
# ---------------------------------------------------------------------------
FEATURE_FLAGS = {
    "DASHBOARD_RBAC": _bool("SUPERSET_DASHBOARD_RBAC", True),
    "EMBEDDED_SUPERSET": False,  # headless — we do NOT use the iframe/embed path
    "ALERT_REPORTS": _bool("SUPERSET_ALERT_REPORTS", False),
    "GLOBAL_ASYNC_QUERIES": _bool("SUPERSET_ASYNC_QUERIES", False),
}

SQLLAB_CTAS_NO_LIMIT = True
ROW_LIMIT = int(os.environ.get("SUPERSET_ROW_LIMIT", "50000"))


# ---------------------------------------------------------------------------
# Venapce control surface — an admin-only blueprint the Venapce backend calls
# (over its existing service-account bearer token) to trigger operator actions,
# currently loading the example datasets on demand for a demo. Never block boot
# on it; a failure here just means the "Load sample data" button is unavailable.
# ---------------------------------------------------------------------------
def FLASK_APP_MUTATOR(app):  # noqa: N802 — Superset expects this exact name
    try:
        from venapce_control import register as _register_venapce

        _register_venapce(app)
    except Exception as exc:  # pragma: no cover — must not break Superset startup
        app.logger.warning("venapce control blueprint not registered: %s", exc)
