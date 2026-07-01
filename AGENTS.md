# AGENTS.md — Agri Catalogue Platform: Infra & API Scaffolding

## What this repo is

This repository is the **deployment and API-platform scaffolding** for the Agri Catalogue Service (internal codename VERG) — a Spring Boot registry API backed by PostgreSQL, Redis, and Elasticsearch, fronted by Kong, running on a single EC2 instance via Kubespray for a UAT pilot.

It is **not** the application repository. The application (`agri-catalogue-service`) is being developed separately and is still changing — registry domains get added, removed, or renamed via that repo's own code generator (`main.py` + `registry_template/`). This repo's job is to be ready for whatever version of that application lands, with the smallest possible amount of rework.

## The one rule that matters more than any other

**Never hardcode anything specific to the current snapshot of the application.** Domain names (`cropcategory`, `soil`, `livestock`, etc.), consumer counts, endpoint counts — none of these are stable. Every chart, script, and config file in this repo must derive those specifics from `service.config.yaml` or from the application's own `/v3/api-docs` output at build/deploy time — never from a value typed once and left sitting in a template.

If you (the agent) find yourself about to write a literal domain name, route path, or count into a Helm template, a Kong plugin config, or a pipeline stage — stop. That value belongs in `service.config.yaml` or should be discovered dynamically, not embedded.

## Target architecture (already decided — don't relitigate this)

- Single EC2, `ap-south-1`, Kubespray single-node cluster (control-plane + worker on one host).
- Namespaces: `platform` (Kong), `data` (Postgres/Redis/Elasticsearch), `app` (catalogue-service).
- Kong runs in DB-less/declarative mode, exposed via NodePort `30080` — no domain, no TLS yet.
- Auth: Kong `key-auth` + `rate-limiting` plugins, one API key per consumer, ~10 consumers.
- Data services run in-cluster via Bitnami Helm charts — not managed AWS services (RDS/ElastiCache/OpenSearch), not yet.
- CI/CD: Jenkins (already exists elsewhere) → build → push to ECR → SSH into the EC2 host → `helm upgrade`. The Kubernetes API server is never exposed to Jenkins directly.
- Storage: `local-path-provisioner`, no EBS CSI driver yet.

Full rationale for these decisions lives in `docs/deployment-plan.md`. Read it before proposing an alternative architecture — don't reopen that discussion here unless something has genuinely changed (e.g., you've moved past pilot scope).

## What the application MUST provide (non-negotiable)

See `.agents/rules/platform-contract.md`. If a version of the application arrives that doesn't satisfy this contract, the correct response is to flag the gap clearly — **not** to silently work around it in the deployment scaffolding. Don't add a custom TCP liveness check because the app has no health endpoint; that's an application-side fix, not an infra one.

## Repo layout this scaffolding should converge on

```
.
├── AGENTS.md
├── service.config.yaml          # single source of truth — edit this, not the templates
├── docs/
│   └── deployment-plan.md       # full architecture rationale (reference, not app-specific)
├── helm/
│   └── catalogue-service/       # parameterized chart, values.yaml driven
├── kong/
│   └── kong.yml                 # declarative config — services/routes generated, not hand-written
├── jenkins/
│   └── Jenkinsfile
├── scripts/
│   ├── generate-kong-routes.sh
│   └── refresh-ecr-secret.sh
└── .agents/
    ├── rules/
    ├── skills/
    └── workflows/
```

## Explicit non-goals right now

Multi-node HA, managed AWS data services, TLS/domain, Keycloak/OAuth, Prometheus/Grafana, autoscaling, service mesh. Don't scaffold for these speculatively — adding them later is cheap; carrying unused complexity now isn't. Full list with "revisit when" triggers is in `docs/deployment-plan.md` Section 12.

## How to work in this repo

- Read `service.config.yaml` before touching any generated file.
- Prefer the skills in `.agents/skills/` over ad-hoc edits — they encode the "how" so it doesn't drift between sessions.
- When a new or updated application codebase shows up, run the `/onboard-service` workflow rather than manually working through chart/Kong/pipeline changes one at a time.
- When in doubt about whether something is "infra scope" or "app scope," check `.agents/rules/platform-contract.md` — if it's in the contract, it's app scope; if it's about how the contract-compliant app gets deployed, it's infra scope.
