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

## Quick start

> Coming as the image is published. The shape it will take:

```bash
# Pull and run the all-in-one image (backend · web · BI builder · nginx),
# with a Postgres alongside it.
docker compose up -d

# Then open the panel:
#   http://localhost:8080
```

A ready-to-edit `docker-compose.yml` and environment reference will be added here alongside the first
published image.

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
