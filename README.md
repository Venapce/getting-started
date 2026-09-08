<div align="center">

# Venapce

### A nervous system for security governance

*Vein — the agents across your compute. Synapse — the signal when something's wrong.*

[Write-up](https://inflowenger.com/blog/venapce-a-nervous-system-for-security) ·
[Product page](https://inflowenger.com/venapce) ·
[FloMorphic](https://inflowenger.com/flomorphic)

</div>

---

> **Status: in active development.** Venapce is past its feasibility study and being built now.
> This repo is the getting-started guide; screenshots and run instructions land here as the panel matures.

## Quick start

One command. It checks for a FloMorphic instance (Venapce runs as a FloMorphic
plugin), offers to install one if there isn't, wires in its shared secret, then
pulls and starts the Venapce image:

```bash
curl -fsSL https://raw.githubusercontent.com/Venapce/getting-started/main/install.sh | bash
```

or, from a clone of this repo:

```bash
./install.sh
```

Then open the panel at **http://localhost:8080** (Superset's own UI is on
**http://localhost:8090**). The installer writes the stack to `venapce/` so you
can manage it by hand afterwards:

```bash
cd venapce
docker compose logs -f          # follow the boot (first boot takes ~1–2 min)
docker compose down             # stop (keeps the data volume)
docker compose pull && docker compose up -d   # update the image
```

Drive it non-interactively with env vars (see the header of `install.sh` for the
full list) — for example:

```bash
FLOMORPHIC_MODE=existing FLOMORPHIC_JWT_SECRET=… ASSUME_YES=1 ./install.sh
```

### Pointing Venapce at FloMorphic later

If you skipped the FloMorphic step — or your FloMorphic later moves — set its
address from the panel: **Settings → Connect FloMorphic → FloMorphic API**. It
takes the API URL, the shared JWT secret and the infra host, tests them, and
stores them in Venapce's database, where they override `FLOMORPHIC_URL`,
`FLOMORPHIC_JWT_SECRET` and `INFRA_HOST` from the environment and survive a
container recreate. **Reset to environment** undoes the override.

Two things to keep in mind when editing `venapce/.env` instead:

- Those values are read once at startup, and `docker compose restart` reuses the
  container's existing environment. Use `docker compose up -d` (a recreate) —
  restart will look like your edit was ignored.
- They are resolved *from inside* the container, so `localhost` is the container
  itself. A FloMorphic container on `inflow_net` is reached by its name
  (`http://flomorphic:8025`); one running on your host is reached at the Docker
  gateway (`docker network inspect inflow_net -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}'`).

## What Venapce is

Every security team is drowning in tools and starved of connective tissue. Endpoints, network gear,
cloud consoles, the ticketing system — each is a black box that already decided what matters, and none
of them talk. Venapce is the missing layer.

It's the first product built the **FloMorphic way, end to end**: all of its business logic lives in
[FloMorphic](https://inflowenger.com/flomorphic) workflows, and Venapce itself is only the view — a
posture builder and BI surface over the data those workflows produce.

```
Senses — plugins & osquery agents
  Reach each system, return raw data frames. No opinions, no scoring, no stored secrets.
        ↓
Nervous system — FloMorphic workflows
  Correlate, enrich & evaluate per feature; an LLM node reasons in the open.
  ALL business logic lives here.
        ↓
The face — Venapce
  Dashboards, fleet view, issues, actions. Posture you can see; a panel you act from.
```

## The data model: Stage → Issues

Two tables carry the whole model, with FloMorphic doing the data engineering between them.

| Table | What it holds |
| --- | --- |
| **Stage** | The raw intake — everything the agents collect, including the noise and false positives. |
| **Issues** | The enriched, real signal FloMorphic promotes: a raised problem, a fix, a security incident. |

Over both sits a **full BI chart and dashboard builder** — every chart drawn on data that came from
FloMorphic. Posture isn't a fixed set of screens; you build the views you need.

## The assistant

Every feature is a flow, and some of those flows carry an AI node. Click an issue and that flow works it
the way a person would — **bounded by the workflow designed for it**. Exactly the steps in the graph, no
false-positive actions. Judgment applied to one issue, inside a contract you drew.

## What ships

Venapce ships as a **single container image** — and behind it, one Postgres.

| Component | Role |
| --- | --- |
| **Go backend API** | The service the panel talks to, and the bridge to FloMorphic. |
| **Vue web app** | The panel: fleet, posture, issues, agent onboarding. |
| **BI dashboard builder** | A full chart and dashboard builder over FloMorphic data. |
| **nginx** | Front door, tying the web app, API, and dashboards behind one origin. |
| **PostgreSQL** | One database, shared by the dashboards and the backend API. |

## Onboarding: the vein is agents

Lightweight **osquery agents** run across your compute and report into a **node hub**. Two ways to start:

- **Connect your own** — already running a node hub for your osquery fleet? Point Venapce at it, and your
  enrolled nodes start showing up.
- **Request a space** — no node hub yet? Ask for one from the panel. Inflowenger runs node hubs on its own
  servers; a request provisions a dedicated space (your own environment and enrollment credentials) and
  hands it back.

Either way you land on a live fleet view — a menu of enrolled operating systems and their status — with
the workflows already reasoning over what those nodes report.

## How it's packaged

Venapce ships as **one image on a permanent base image**:

| Image | Contents | Cadence |
| --- | --- | --- |
| **`mehdishokohi/venapce-base`** | PostgreSQL · Superset (gunicorn, synchronous — **no Redis/Celery**) · nginx · supervisord | Rebuilt only when Superset or the base plumbing changes (`BASE_VERSION`) |
| **`mehdishokohi/venapce`** | `FROM venapce-base` + the `venapce-api` Go backend + the compiled `venapce-wapp` panel + the nginx front door | Every product release (`VERSION`) |

Everything runs in **one container**, supervised by supervisord, behind a single
origin:

```
:80   nginx ──► /         venapce-wapp (Vue SPA)
              └► /api      venapce-api (Go)  ─┐
:8088 (→ host :8090)  Superset (gunicorn)     │  one PostgreSQL, two databases:
                        └──────────────────────┴─►  venapce  +  superset
```

- **One PostgreSQL** holds both the `venapce` database (the backend's charts,
  dashboards, settings, stage/issues) and Superset's `superset` metadata database
  — Superset's metadata is Postgres, never sqlite.
- **No Redis, no Celery.** Superset is a synchronous BI engine here; its caches
  are a filesystem cache on the data volume. The async-only features (async SQL
  Lab, Alerts & Reports, thumbnails) are off.
- **FloMorphic** is reached over the shared `inflow_net` network at
  `flomorphic:8025`, authenticated with FloMorphic's shared secret — the installer
  captures it from the instance it finds or installs.

All state lives in one named volume (`venapce-state` → `/var/lib/superset`).

## Building & publishing (maintainers)

The `Makefile` builds and pushes both images from the sibling `venapce-api` /
`venapce-wapp` checkouts (Docker Hub namespace `mehdishokohi`):

```bash
make base-build           # build venapce-base:local (host arch)
make build                # build venapce:local FROM the local base
make run                  # try it standalone on :8080 (+ Superset on :8090)

make login
make base-release BASE_VERSION=v1     # publish the base (multi-arch)
make release      VERSION=v0.1.0      # publish the product (multi-arch)
```

`make help` lists every target. A product release layers the Go binary and static
panel onto the existing base, so it doesn't recompile Superset.

## Screenshots

Panel walkthroughs land here as the menus come to life.

<!-- Replace these once the images are in ./images -->
<!--
![Fleet view](images/fleet.png)
![Issues](images/issues.png)
![Dashboard builder](images/dashboards.png)
-->

## Links

- **Write-up:** https://inflowenger.com/blog/venapce-a-nervous-system-for-security
- **Product page:** https://inflowenger.com/venapce
- **The runtime it runs on — FloMorphic:** https://inflowenger.com/flomorphic

---

<div align="center">
<sub>Venapce · the security segment of Inflowenger, built the FloMorphic way. In development — dates and scope will shift.</sub>
</div>
