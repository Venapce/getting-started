#!/usr/bin/env bash
#
# Venapce one-liner installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Venapce/getting-started/main/install.sh | bash
#
# Stands up Venapce — the panel, its API and a built-in Superset/Postgres — from a
# single published image (mehdishokohi/venapce). Venapce runs as a FloMorphic
# plugin, so it needs a FloMorphic instance (on the Inflowenger platform); this
# installer finds the one you already run, or installs a new one for you by
# delegating to the FloMorphic installer — one source of truth for that stack.
#
# Everything lands on the shared `inflow_net` Docker network so Venapce reaches
# FloMorphic and Infra by name, and the compose stack is written into an install
# directory so you can manage it by hand afterwards.
#
# What it asks (all of it can be driven by the env vars below instead):
#   1. install directory
#   2. FloMorphic: use the one already running, install a new one, or skip
#   3. where that FloMorphic is — API URL, shared secret (auto-read when it was
#      installed here) and infra host. Asked whenever we did not install FloMorphic
#      ourselves, skip included: they are what "Connect FloMorphic" needs, and every
#      one of them can also be set later from the panel (Settings -> Connect
#      FloMorphic -> FloMorphic API) without editing files or restarting anything.
#   4. ports + admin (behind an advanced-options prompt)
#
# It pulls the published, baked image — building is a maintainer job (see the
# Makefile), not an install-time one.
#
# Works interactively (prompts read from /dev/tty even when piped through curl)
# and non-interactively (drive it entirely with the env vars below).
#
# Env vars (all optional — prompted for when a TTY is available, else defaulted):
#   VENAPCE_DIR          install directory                     (default: current directory)
#   FLOMORPHIC_MODE      existing | new | skip                 (default: detected, else prompted)
#   FLOMORPHIC_DIR       dir holding flomorphic/.env           (default: the install dir)
#   FLOMORPHIC_URL       FloMorphic API base, as reached from inside the container
#                                                              (default: suggested, else prompted)
#   FLOMORPHIC_JWT_SECRET  shared secret (= FloMorphic API_JWT_SECRET / INFLOW_INFRA_JWT_SECRET)
#   INFRA_HOST           Infra host for NATS/osspace           (default: suggested, else inflow-infra)
#   IMAGE_NS             Docker Hub namespace                  (default: mehdishokohi)
#   IMAGE_TAG            tag for the pulled image              (default: latest)
#   VENAPCE_IMAGE        full image ref, overrides NS/TAG      (default: $IMAGE_NS/venapce:$IMAGE_TAG)
#   VENAPCE_PORT         host port for the panel               (default: 8080)
#   SUPERSET_PORT        host port for Superset's own UI       (default: 8088)
#   PUBLIC_HOST          hostname this instance is reached at  (default: localhost)
#   ADMIN_USER/ADMIN_PASS/ADMIN_EMAIL   Superset admin (created on first boot)
#   SUPERSET_SECRET_KEY  Superset secret                       (default: generated)
#   VENAPCE_APP_SECRET   key for encrypting stored secrets     (default: generated)
#   VENAPCE_DB_PASS      internal venapce Postgres password    (default: generated)
#   LOAD_EXAMPLES        true/false — load Superset examples   (default: false)
#   REPO_RAW / REPO_REF  raw base URL + ref the compose file is fetched from
#   FLOMORPHIC_INSTALLER URL or local path of the FloMorphic installer
#   ASSUME_YES           1 — accept all defaults, no prompts   (default: 0)
#   EULA_ACCEPT          1 — accept the Inflowenger EULA non-interactively
#
# Flags:  --yes  same as ASSUME_YES=1
#
set -euo pipefail

# ── config / defaults ─────────────────────────────────────────────────────────
VENAPCE_DIR="${VENAPCE_DIR:-$PWD}"
FLOMORPHIC_MODE="${FLOMORPHIC_MODE:-}"
FLOMORPHIC_DIR="${FLOMORPHIC_DIR:-}"
FLOMORPHIC_URL="${FLOMORPHIC_URL:-}"
FLOMORPHIC_JWT_SECRET="${FLOMORPHIC_JWT_SECRET:-}"
INFRA_HOST="${INFRA_HOST:-inflow-infra}"
IMAGE_NS="${IMAGE_NS:-mehdishokohi}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
VENAPCE_IMAGE="${VENAPCE_IMAGE:-}"
VENAPCE_PORT="${VENAPCE_PORT:-8080}"
SUPERSET_PORT="${SUPERSET_PORT:-8090}"
PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@venapce.local}"
SUPERSET_SECRET_KEY="${SUPERSET_SECRET_KEY:-}"
VENAPCE_APP_SECRET="${VENAPCE_APP_SECRET:-}"
VENAPCE_DB_PASS="${VENAPCE_DB_PASS:-}"
LOAD_EXAMPLES="${LOAD_EXAMPLES:-false}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Venapce/getting-started}"
REPO_REF="${REPO_REF:-main}"
FLOMORPHIC_INSTALLER="${FLOMORPHIC_INSTALLER:-https://raw.githubusercontent.com/FloMorphic/getting-started/main/install.sh}"
ASSUME_YES="${ASSUME_YES:-0}"
EULA_ACCEPT="${EULA_ACCEPT:-0}"
EULA_URL="${EULA_URL:-https://github.com/Inflowenger/getting-started/blob/main/EULA.md}"

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      if [ -f "${BASH_SOURCE[0]:-}" ]; then sed -n '3,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      else printf 'see https://github.com/Venapce/getting-started#install\n'; fi
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Where this script lives, when it lives anywhere: from a clone, the repo's own
# compose file is used; piped through curl, it is fetched from REPO_RAW/REPO_REF.
SCRIPT_DIR=""
case "${BASH_SOURCE[0]:-}" in
  ''|bash|-|/dev/fd/*|/proc/self/fd/*) ;;
  *) SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
esac

# ── pretty output ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  B=''; DIM=''; GRN=''; YLW=''; RED=''; CYN=''; RST=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$CYN" "$RST" "$B" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '    %s!%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ── interactive helpers (read from /dev/tty so `curl | bash` still prompts) ────
have_tty() { [ "$ASSUME_YES" != "1" ] && [ -e /dev/tty ]; }

ask() { # <prompt> <default> -> echoes answer
  local prompt="$1" def="${2:-}" reply
  if ! have_tty; then printf '%s' "$def"; return; fi
  if [ -n "$def" ]; then printf '%s%s%s [%s]: ' "$B" "$prompt" "$RST" "$def" >/dev/tty
  else printf '%s%s%s: ' "$B" "$prompt" "$RST" >/dev/tty; fi
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "${reply:-$def}"
}

# Echoed rather than hidden: the value is written to venapce/.env anyway, and a
# silent prompt gives no feedback that a pasted secret actually landed.
ask_secret() { # <prompt> -> echoes answer
  local prompt="$1" reply
  if ! have_tty; then printf ''; return; fi
  printf '%s%s%s: ' "$B" "$prompt" "$RST" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "$reply"
}

confirm() { # <prompt> <default y|n> -> exit status
  local prompt="$1" def="${2:-n}" reply hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  if ! have_tty; then [ "$def" = y ]; return; fi
  printf '%s%s%s %s ' "$B" "$prompt" "$RST" "$hint" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-$def}"
  case "$reply" in [Yy]*) return 0;; *) return 1;; esac
}

gen_secret() { # length (default 48)
  local n="${1:-48}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$((n*2))" | tr -dc 'A-Za-z0-9' | head -c "$n"
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n"
  fi
}

# Read KEY=value from an env file (last match wins), stripping surrounding quotes.
read_env_key() { # <file> <key>
  [ -f "$1" ] || return 1
  grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# ── reachability helpers ──────────────────────────────────────────────────────
#
# Every address written into venapce/.env is used from INSIDE the venapce
# container, where `localhost` is the container itself. So a service on the host
# is reached at the Docker gateway, and a service in a container on inflow_net at
# its container name. These helpers pick the right suggestion rather than leaving
# the operator to find out from a failed connection.

# The address the venapce container reaches this host on: inflow_net's gateway
# (the interface venapce actually routes through), falling back to the default
# bridge and finally to Docker Desktop's host alias.
host_gateway() {
  local gw=""
  for net in inflow_net bridge; do
    gw="$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
    [ -n "$gw" ] && { printf '%s' "$gw"; return; }
  done
  printf 'host.docker.internal'
}

# Is something listening on this host port? Used to spot a FloMorphic/infra that
# runs on the host rather than in a container.
port_open() { # <port>
  (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
}

# Is <container> running and attached to inflow_net (so venapce can reach it by
# name)? A FloMorphic on some other network is reachable only via the host.
on_inflow_net() { # <container>
  docker inspect "$1" --format '{{range $n, $v := .NetworkSettings.Networks}}{{$n}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -qx inflow_net
}

# Best guess for FLOMORPHIC_URL / INFRA_HOST, offered as the prompt default.
suggest_flomorphic_url() {
  if on_inflow_net flomorphic; then printf 'http://flomorphic:8025'; return; fi
  if port_open 8025; then printf 'http://%s:8025' "$(host_gateway)"; return; fi
  printf 'http://flomorphic:8025'
}
suggest_infra_host() {
  if on_inflow_net inflow-infra; then printf 'inflow-infra'; return; fi
  if port_open 4222; then printf '%s' "$(host_gateway)"; return; fi
  printf 'inflow-infra'
}

DL=""
fetch() { # <url-or-path> <dest>
  case "$1" in
    /*|./*|../*) cp "$1" "$2" ;;  # local installer path
    *) case "$DL" in
         curl) curl -fsSL "$1" -o "$2" ;;
         wget) wget -qO "$2" "$1" ;;
       esac ;;
  esac || die "failed to obtain $1"
}

# ── prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "the Docker Compose v2 plugin is required (\`docker compose version\`)."
fi
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon — is it running / do you have permission?"
if command -v curl >/dev/null 2>&1; then DL=curl
elif command -v wget >/dev/null 2>&1; then DL=wget
else die "need curl or wget to download the compose file."; fi
ok "docker + compose available ($DC); downloader: $DL"

# ── banner ────────────────────────────────────────────────────────────────────
printf '\n%s  Venapce installer%s\n' "$B" "$RST"
printf '%s  panel + API + Superset/Postgres in one image, on the FloMorphic runtime%s\n' "$DIM" "$RST"

# ── license (EULA) ────────────────────────────────────────────────────────────
step "License"
info "Venapce is built the FloMorphic way and runs on Inflowenger, which is"
info "proprietary software — free for personal, non-commercial use (limited"
info "edition). Commercial, high-value or high-volume use needs a separate"
info "license. Full EULA: ${B}${EULA_URL}${RST}"
if [ "$EULA_ACCEPT" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
  if have_tty; then
    [ "$(ask 'Type "I AGREE" to accept the EULA and continue' 'I AGREE')" = "I AGREE" ] \
      || die "EULA not accepted."
  else
    die "EULA not accepted — re-run with EULA_ACCEPT=1 (or ASSUME_YES=1). See $EULA_URL"
  fi
fi
EULA_ACCEPT=1   # carried into a delegated FloMorphic installer below
ok "EULA accepted."

# ── 1. where ──────────────────────────────────────────────────────────────────
step "Configuration"
VENAPCE_DIR="$(ask "Install directory" "$VENAPCE_DIR")"
mkdir -p "$VENAPCE_DIR"
VENAPCE_DIR="$(cd "$VENAPCE_DIR" && pwd)"
: "${FLOMORPHIC_DIR:=$VENAPCE_DIR}"

# ── shared network ────────────────────────────────────────────────────────────
step "Ensuring the shared network (inflow_net) exists"
if docker network inspect inflow_net >/dev/null 2>&1; then
  ok "network inflow_net already exists"
else
  docker network create inflow_net >/dev/null
  ok "created network inflow_net"
fi

# ── 2. FloMorphic ─────────────────────────────────────────────────────────────
#
# Venapce is a product ON the FloMorphic runtime, not a replacement for it:
# without it there is no workflow engine behind the panel and no plugin credential.
if [ -z "$FLOMORPHIC_MODE" ]; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'flomorphic'; then
    ok "found a running FloMorphic container (flomorphic)"
    if confirm "Use the FloMorphic instance that is already running?" y; then
      FLOMORPHIC_MODE=existing
    else
      FLOMORPHIC_MODE=new
    fi
  else
    info "No running FloMorphic found. Venapce runs as a FloMorphic plugin."
    if confirm "Install FloMorphic now (delegates to its installer)?" y; then
      FLOMORPHIC_MODE=new
    else
      FLOMORPHIC_MODE=skip
    fi
  fi
fi

if [ "$FLOMORPHIC_MODE" = new ]; then
  step "Installing FloMorphic (canvas + API, on the Inflowenger platform)"
  info "Delegated to the FloMorphic installer so that stack has one source of truth:"
  info "  $FLOMORPHIC_INSTALLER"
  FLO_SH="$(mktemp)"
  fetch "$FLOMORPHIC_INSTALLER" "$FLO_SH"
  # Install FloMorphic + its platform under the SAME dir, so we can read the
  # shared secret it generates straight back out.
  FLOMORPHIC_DIR="$VENAPCE_DIR"
  FLOMORPHIC_DIR="$FLOMORPHIC_DIR" \
  ASSUME_YES=1 \
  EULA_ACCEPT="$EULA_ACCEPT" \
    bash "$FLO_SH" || die "the FloMorphic installer failed — fix that first, then re-run this script."
  rm -f "$FLO_SH"
  ok "FloMorphic installed under $FLOMORPHIC_DIR"
elif [ "$FLOMORPHIC_MODE" = existing ]; then
  step "Using an existing FloMorphic instance"
  FLOMORPHIC_DIR="$(ask "FloMorphic install directory (holds flomorphic/.env)" "$FLOMORPHIC_DIR")"
else
  step "Skipping the FloMorphic install"
  info "Venapce still runs as a FloMorphic plugin, so it needs to know where your"
  info "FloMorphic is. Fill that in below — or leave it blank and set it later from"
  info "the panel: Settings -> Connect FloMorphic -> FloMorphic API."
fi

# The shared secret: read it from a FloMorphic install we can see, else ask. Even
# in skip mode we look, because the operator may point us at an install directory.
if [ -z "$FLOMORPHIC_JWT_SECRET" ]; then
  for f in "$FLOMORPHIC_DIR/flomorphic/.env" "$FLOMORPHIC_DIR/platform/.env"; do
    [ -f "$f" ] || continue
    for key in INFLOW_INFRA_JWT_SECRET API_JWT_SECRET; do
      v="$(read_env_key "$f" "$key" || true)"
      if [ -n "${v:-}" ]; then FLOMORPHIC_JWT_SECRET="$v"; ok "read the FloMorphic shared secret from $f"; break 2; fi
    done
  done
fi

# ── the address venapce reaches FloMorphic + infra at ─────────────────────────
#
# In `new` mode the FloMorphic we just installed sits on inflow_net under known
# names, so the defaults are right and we do not ask. In every other mode we do:
# these three values are exactly what "Connect FloMorphic" needs, and leaving them
# for the operator to discover later is the expensive path — a wrong or missing
# value means editing venapce/.env AND recreating the container (a plain
# `docker compose restart` keeps the old environment).
#
# Remember they are resolved from inside the venapce container: `localhost` there
# is the container, never your machine. The suggested defaults account for that.
if [ "$FLOMORPHIC_MODE" = new ]; then
  FLOMORPHIC_URL="${FLOMORPHIC_URL:-http://flomorphic:8025}"
else
  step "Where Venapce reaches FloMorphic"
  info "These are resolved from inside the venapce container, so ${B}localhost${RST}"
  info "will not work: a FloMorphic container on inflow_net is reached by its name"
  info "(${B}http://flomorphic:8025${RST}), one running on this host through the Docker"
  info "gateway (${B}$(host_gateway)${RST})."

  if [ -z "$FLOMORPHIC_URL" ]; then
    if [ "$FLOMORPHIC_MODE" = skip ]; then
      # Blank is a valid answer here: it leaves the panel usable and the connection
      # to be made from Settings later.
      FLOMORPHIC_URL="$(ask "FloMorphic API URL (blank to set later in Settings)" "")"
    else
      FLOMORPHIC_URL="$(ask "FloMorphic API URL" "$(suggest_flomorphic_url)")"
    fi
  fi

  if [ -n "$FLOMORPHIC_URL" ] && [ -z "$FLOMORPHIC_JWT_SECRET" ]; then
    info "Venapce authenticates to FloMorphic with its shared secret (FloMorphic's"
    info "API Secret Key — API_JWT_SECRET / INFLOW_INFRA_JWT_SECRET). It must match."
    FLOMORPHIC_JWT_SECRET="$(ask_secret "FloMorphic shared secret")"
  fi

  # Infra is where the plugin connects (NATS :4222) and where the osctrl-space
  # broker calls (osspace :8022) — a hostname, not a URL; venapce adds the ports.
  if [ -n "$FLOMORPHIC_URL" ]; then
    INFRA_HOST="$(ask "Infra host (NATS :4222 / osspace :8022)" "$(suggest_infra_host)")"
  fi
fi

# Warn about whatever is still missing, naming the one place it can be fixed
# without touching files.
if [ -z "$FLOMORPHIC_URL" ] || [ -z "$FLOMORPHIC_JWT_SECRET" ]; then
  warn "FloMorphic is not fully configured: the panel and BI builder work, but"
  warn "'Connect FloMorphic' and workflow-driven features stay dark. Set the URL,"
  warn "secret and infra host from the panel (Settings -> Connect FloMorphic) —"
  warn "no restart needed."
fi

# ── 3. the image + secrets ────────────────────────────────────────────────────
VENAPCE_IMAGE="${VENAPCE_IMAGE:-$IMAGE_NS/venapce:$IMAGE_TAG}"

[ -z "$SUPERSET_SECRET_KEY" ] && { SUPERSET_SECRET_KEY="$(gen_secret 48)"; ok "generated a Superset secret key"; }
[ -z "$VENAPCE_APP_SECRET" ]  && { VENAPCE_APP_SECRET="$(gen_secret 48)";  ok "generated a Venapce app secret"; }
[ -z "$VENAPCE_DB_PASS" ]     && { VENAPCE_DB_PASS="$(gen_secret 24)";     ok "generated the venapce database password"; }

if have_tty && confirm "Set advanced options (ports, admin)?" n; then
  VENAPCE_PORT="$(ask "Host port for the panel" "$VENAPCE_PORT")"
  SUPERSET_PORT="$(ask "Host port for Superset's UI" "$SUPERSET_PORT")"
  PUBLIC_HOST="$(ask "Public hostname" "$PUBLIC_HOST")"
  ADMIN_USER="$(ask "Admin username" "$ADMIN_USER")"
  ADMIN_PASS="$(ask "Admin password" "$ADMIN_PASS")"
  ADMIN_EMAIL="$(ask "Admin email" "$ADMIN_EMAIL")"
fi

# ── write the stack ───────────────────────────────────────────────────────────
step "Writing the Venapce stack -> $VENAPCE_DIR/venapce"
mkdir -p "$VENAPCE_DIR/venapce"

COMPOSE_DST="$VENAPCE_DIR/venapce/docker-compose.yml"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/venapce/docker-compose.yml" ]; then
  [ "$SCRIPT_DIR/venapce/docker-compose.yml" = "$COMPOSE_DST" ] || \
    cp "$SCRIPT_DIR/venapce/docker-compose.yml" "$COMPOSE_DST"
  info "compose file taken from this checkout"
else
  fetch "$REPO_RAW/$REPO_REF/venapce/docker-compose.yml" "$COMPOSE_DST"
fi

if [ -f "$VENAPCE_DIR/venapce/.env" ]; then
  cp "$VENAPCE_DIR/venapce/.env" "$VENAPCE_DIR/venapce/.env.bak"
  warn "existing .env backed up to venapce/.env.bak"
fi

{
  printf 'VENAPCE_IMAGE=%s\n'         "$VENAPCE_IMAGE"
  printf 'PUBLIC_HOST=%s\n'           "$PUBLIC_HOST"
  printf 'VENAPCE_PORT=%s\n'          "$VENAPCE_PORT"
  printf 'SUPERSET_PORT=%s\n'         "$SUPERSET_PORT"
  printf 'SUPERSET_SECRET_KEY=%s\n'   "$SUPERSET_SECRET_KEY"
  printf 'ADMIN_USER=%s\n'            "$ADMIN_USER"
  printf 'ADMIN_PASS=%s\n'            "$ADMIN_PASS"
  printf 'ADMIN_EMAIL=%s\n'           "$ADMIN_EMAIL"
  printf 'LOAD_EXAMPLES=%s\n'         "$LOAD_EXAMPLES"
  printf 'VENAPCE_APP_SECRET=%s\n'    "$VENAPCE_APP_SECRET"
  printf 'VENAPCE_DB_PASS=%s\n'       "$VENAPCE_DB_PASS"
  printf 'FLOMORPHIC_URL=%s\n'        "$FLOMORPHIC_URL"
  printf 'FLOMORPHIC_JWT_SECRET=%s\n' "$FLOMORPHIC_JWT_SECRET"
  printf 'INFRA_HOST=%s\n'            "$INFRA_HOST"
} > "$VENAPCE_DIR/venapce/.env"
chmod 600 "$VENAPCE_DIR/venapce/.env"
ok "venapce/docker-compose.yml + .env written"


# ── start ─────────────────────────────────────────────────────────────────────
step "Starting Venapce"
( cd "$VENAPCE_DIR/venapce" && $DC pull --quiet 2>/dev/null || true )
info "First boot initializes Postgres, migrates the Superset metadata DB and"
info "creates the admin user before the API answers — this takes ~1-2 minutes."
if ! ( cd "$VENAPCE_DIR/venapce" && $DC up -d ); then
  printf '\n'; die "\`$DC up -d\` failed — see the error above."
fi

info "Waiting for the panel to answer on http://127.0.0.1:$VENAPCE_PORT ..."
ready=0
for _ in $(seq 1 240); do
  if curl -fsS --noproxy '*' "http://127.0.0.1:$VENAPCE_PORT/healthz" >/dev/null 2>&1; then ready=1; break; fi
  if ! docker ps --format '{{.Names}}' | grep -qx 'venapce'; then
    warn "the venapce container is not running — check its logs:"
    info "  (cd $VENAPCE_DIR/venapce && $DC logs --tail 50)"
    break
  fi
  sleep 5
done
if [ "$ready" = "1" ]; then ok "Venapce is up"; else
  warn "not ready yet — first boot can take a couple of minutes; follow it with:"
  info "  (cd $VENAPCE_DIR/venapce && $DC logs -f)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
step "Done"
printf '\n%s  Venapce%s\n' "$B" "$RST"
info "Panel                http://localhost:$VENAPCE_PORT"
info "Superset UI          http://localhost:$SUPERSET_PORT   ${DIM}(admin: $ADMIN_USER)${RST}"
printf '\n%s  FloMorphic%s\n' "$B" "$RST"
if [ "$FLOMORPHIC_MODE" = skip ]; then
  info "Not connected — set FLOMORPHIC_URL + FLOMORPHIC_JWT_SECRET in venapce/.env, then \`$DC up -d\`."
else
  info "API                  $FLOMORPHIC_URL"
  info "Shared secret        ${FLOMORPHIC_JWT_SECRET:+(set)}${FLOMORPHIC_JWT_SECRET:-(not set — Connect FloMorphic stays off)}"
  [ "$FLOMORPHIC_MODE" = new ] && info "Canvas               http://localhost:8088   ${DIM}(FloMorphic's own UI)${RST}"
fi
printf '\n%s  Files & management%s\n' "$B" "$RST"
info "Stack lives in       $VENAPCE_DIR/venapce"
info "Config               $VENAPCE_DIR/venapce/.env"
info "Follow the boot      (cd $VENAPCE_DIR/venapce && $DC logs -f)"
info "Stop Venapce         (cd $VENAPCE_DIR/venapce && $DC down)"
info "Update the image     $DC pull && $DC up -d"
printf '\n'
