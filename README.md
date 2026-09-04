# OAS-Infra — OpenAgriStack Catalogues

Infrastructure as code and deployment scaffolding for the **OpenAgriStack (OAS) registry
framework** — a set of Spring Boot catalogue services backed by PostgreSQL, Elasticsearch and
Redis, fronted by the Kong API gateway, with Keycloak as the identity provider.

This repository provisions the platform (Terraform), bootstraps the cluster and data tier, defines
the shared Helm chart and gateway configuration, and owns the CI/CD pipeline. The application code
lives in separate repositories, one per service.

**Services deployed by this repo**

| Service | Serves | Repository |
|---|---|---|
| `agri-catalogue-service` | 18 agricultural catalogues (`seed`, `croptype`, `livestock`, …) | `Open-Agri-Stack/agri-catalogue-service` |
| `org-user-notification-services` | `org`, `user`, `catalogue`, `catalogueassignment`, `orgtype` + notifications | `Open-Agri-Stack/OrgUserNotificationServices` |
| `oas-auth-service` | Token issue / validate / refresh / revoke, backed by Keycloak | `Open-Agri-Stack/OAS-Auth-Service` |

## Architecture

A purpose-built VPC with one public tier and two private tiers. Data services run as **Docker
containers on a dedicated host**; application services run as **Kubernetes pods**; Kong (DB-backed)
enforces API-key authentication and role-based access at the edge.

```
                         Internet
                            │  HTTP :80 (world)   SSH :22 (admin CIDR)
                     Internet Gateway
   ┌───────────────────────────────────────────────────────────────────────────┐ OAS VPC 10.0.0.0/16 (ap-northeast-1)
   │  PUBLIC  10.0.0.0/24, 10.0.1.0/24                                         │
   │    • bastion + NAT instance (public IP)  — SSH jump host + private egress │
   │    • nginx reverse proxy (public IP)      — :80 → Kong NodePort :30080    │
   │                                                                           │
   │  PRIVATE "app"  10.0.20.0/24, 10.0.21.0/24                                │
   │    • Kubespray k8s node (private): catalogue pods + Kong (DB mode)        │
   │                                                                           │
   │  PRIVATE "data" 10.0.10.0/24, 10.0.11.0/24                                │
   │    • DB host EC2 @ 10.0.10.10 (docker-compose):                           │
   │        postgres:16 (acs_db, oas_db, kong, keycloak)                       │
   │        elasticsearch:8.13 · redis:7 · keycloak:26.7 (:8081, internal)     │
   │        pgAdmin · Kibana · RedisInsight  (bastion-tunnel only)             │
   └───────────────────────────────────────────────────────────────────────────┘
   Private subnets egress via the bastion NAT. Jenkins (external) reaches the
   private node via SSH ProxyJump through the bastion.
```

Request path: `http://<nginx-ip>/<catalogue>/v1/... (apikey header)` → nginx → Kong (key-auth +
acl) → catalogue pod → DB host.

Authentication is **two layers**:

1. **Kong** gates the edge on the `apikey` header (key-auth + ACL by role). This is what decides
   whether a request reaches a pod at all.
2. **The catalogue services** then validate the caller's `Authorization: Bearer <token>` against
   `oas-auth-service` (`/auth/v1/auth_token_validate`), which returns the caller's `user_id`,
   `functional_role` and `display_name`. They call it over **in-cluster Service DNS**, so no API
   key is involved on that hop — see [Service-to-service auth](#service-to-service-auth).

So a caller needs **both** an `apikey` (for Kong) and a bearer token (for the service). Identities
live in the user catalogue and are projected into Keycloak by `oas-auth-service`.

### Deployment Style (UAT)
- **Databases as Docker on one EC2**.
  One Postgres with four databases (`acs_db`, `oas_db`, `kong`, `keycloak`); shared ES/Redis, plus
  the internal Keycloak. Extensible to cassandra/yugabyte via compose profiles.
- **Kong OSS, DB-backed**, synced with **decK**. Three roles by API key + ACL group, split by URL
  path (because `search` is a POST yet a read): `user`=read+search, `admin`=+full CRUD,
  `superadmin`=admin+key rotation. Rate-limiting is provisioned but disabled. Key rotation is a
  manual operator action against the private Admin API.
- **HTTP-only on the nginx public IP** (no domain/TLS yet; EIPs skipped — the account is at its
  Elastic IP quota, so bastion/nginx use auto-assigned public IPs that are stable while running).
  Admin GUIs (and direct ES/PG/Redis) reachable only via a bastion SSH tunnel. Single-AZ / single
  node, but subnets span 2 AZs for later scale-out.
- **Local Terraform state** (gitignored) and **secrets in Jenkins creds + k8s Secrets + gitignored
  `.env`** — no paid/AWS-proprietary services.

## Repository layout
- [terraform/modules/](terraform/modules/) — `network`, `bastion-nat`, `nginx`, `db-host`,
  `k8s-node`. **No IAM module:** the deploy IAM user cannot manage IAM, so the k8s node reuses a
  pre-existing instance profile passed in as `var.ecr_instance_profile` (default
  `EC2-ECR-Read-Role`). ECR pulls in-cluster use the `ecr-pull-secret` refreshed by cron instead.
- [terraform/environments/oas-uat/](terraform/environments/oas-uat/) — composes the whole platform;
  generates `env.sh` + `hosts_k8s.yaml` (gitignored).
- [db-host/](db-host/) — the data tier's `docker-compose.yml`, `init/` (creates the 4 databases +
  their roles), `gui/servers.json`, `.env.example`. All DB/GUI/Keycloak passwords live in
  `db-host/.env` (gitignored); `.env.example` documents each one.
- [kubernetes/helm/oas-catalogue/](kubernetes/helm/oas-catalogue/) — shared chart + per-service
  `values-<service>.yaml`. The Deployment carries a `checksum/config` annotation over the
  ConfigMap, so a values-only change (no new image tag) still rolls the pods — without it
  `envFrom` leaves running pods on their old env while the deploy reports success.
- [kubernetes/kubespray/](kubernetes/kubespray/) — cluster bootstrap (bastion/ProxyJump aware).
- [kong/kong.decK.yaml](kong/kong.decK.yaml) — services, read/write regex routes, key-auth+acl,
  rate-limiting(off), 3 consumers. **TEMP/UAT:** also carries `oas-auth-service` (`~/auth/v1/.*` +
  `~/actuator/health/.*`) — a temporary UAT exposure to revert before prod (see Security notes).
  [kong/scripts/](kong/scripts/) — `deck-sync.sh`, `rotate-key.sh`.
- [services/](services/) — one source-of-truth config per service.
- [scripts/](scripts/) — `setup-cluster.sh` orchestrator, `refresh-ecr-secret.sh`,
  `flush-databases.sh` (wipe catalogue data for bulk re-ingest), `recreate-tables.sh` (drop +
  recreate specific catalogue tables, then restart their service), `db-tunnels.sh` /
  `kube-access.sh` (developer access), `lib/kube-tunnel.sh`.
- [jenkins/Jenkinsfile](jenkins/Jenkinsfile) — CI/CD (ProxyJump through the bastion). The Jenkins
  controller + JCasC live in the separate **Jenkins** repo. Also configures the Keycloak realm —
  see [Identity](#identity-keycloak).

## Deploy (from scratch)
Prereqs: `terraform`, `helm`, `kubectl`, `deck`, `ssh`; copy `db-host/.env.example`→`db-host/.env`,
`kong/.env.example`→`kong/.env`, and `terraform/environments/oas-uat/terraform.tfvars.example`→
`terraform.tfvars` (lock `admin_ssh_cidrs`). Then:

```bash
scripts/setup-cluster.sh              # terraform → dbhost → kubespray → postinstall → kong → deck
# or run a single stage: scripts/setup-cluster.sh <terraform|dbhost|kubespray|postinstall|kong|deck>
```

Then, per service, just press **Build** on its Jenkins job — no parameters. The pipeline derives the
service from the job name and auto-discovers the bastion/node/nginx IPs from the EC2 tags
(`oas-uat-bastion` / `-K8s-Node` / `-nginx`) via `aws-credentials` (needs `ec2:DescribeInstances`); the
smoke-test key comes from the service config. Hand developers the base URL `http://<nginx-ip>` and their
role API key.

Install `scripts/refresh-ecr-secret.sh` on the k8s node's cron (ECR tokens expire ~12h).

## Identity (Keycloak)
Keycloak runs on the DB host at `10.0.10.10:8081` — **internal only**, never routed. `oas-auth-service`
is the only thing that talks to it; it administers users through its own client service account, so no
admin password reaches any application.

**The realm is configured by the pipeline, not by hand.** When a service config declares
`keycloak_realm.realm_setup_script`, the `Configure Keycloak Realm` stage runs that script (from the
*application* checkout, so realm config ships with the code that depends on it) against the live
Keycloak over an `ssh -L` tunnel through the bastion. The script is idempotent and asserts its own
result, and the stage runs before the image build so it is the cheapest thing to fail on.

The stage also compares Keycloak's live client secret against the `keycloak-client-secret` Jenkins
credential and **fails the build on drift** — otherwise the new pod would deploy unable to get an
admin token, and only fail at the first user publish.

Two prerequisites live on the Jenkins host, not in this repo: `jq` in the Jenkins image, and
`KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` in its `.env` (JCasC credential `keycloak-admin`).

Token claims currently projected: `user_id`, `org_id`, `functional_role`, `org_name`,
`display_name`, `first_name`, `last_name`. Realm session policy is on Keycloak defaults —
5-min access tokens, 30-min idle, 10-hour max session — which is why
`KEYCLOAK_DENYLIST_SID_TTL_SECONDS` is pinned to `36000` in the auth service's config: that one TTL
governs the Redis session index and both revoke denylists, and a revocation must outlive any session
that could still be refreshed.

## Service-to-service auth
Catalogue services validate caller tokens against `oas-auth-service`, and they reach it over
**in-cluster Service DNS** (`http://oas-auth-service.app.svc.cluster.local:8080`), never the public
host:

| Service | Config key | Points at |
|---|---|---|
| agri-catalogue-service | `OAS_AUTH_VALIDATE_URL` | `…/auth/v1/auth_token_validate` |
| org-user-notification-services | `AUTH_SERVICE_URL` | `…` (auth base; appends `/auth/v1/auth_user_create`) |

Both apps default to the public nginx host and an API key. **Do not use that default.** Going
direct means:

- no hairpin out through Kong and back into the same namespace on every request;
- no dependence on the nginx public IP, which is auto-assigned and changes on any stop/start;
- **no API key to manage** — the key exists only to get past Kong, so bypassing Kong removes it.
  Leave `OAS_AUTH_API_KEY` / `AUTH_SERVICE_API_KEY` unset; the apps log one warning per call.

The user catalogue is the source of identity: `POST /user/v1/add` calls `auth_user_create` **before**
persisting, so a user cannot exist in the catalogue without a matching Keycloak identity. Note
`/user/v1/verify` is deliberately **absent** from the Kong routes — it takes a plaintext password and
is only meant to be called in-cluster by `oas-auth-service`.

## Onboarding a new service
1. `services/<svc>.config.yaml` — repo, port, DB name/user, resources, chart/values pointers, and
   the `catalogues:` list (that list is what scopes `flush-databases.sh`).
2. `kubernetes/helm/oas-catalogue/values-<svc>.yaml` — env → DB host, `secretName`,
   `fullnameOverride`. Keep the `env:` block in sync with the config file's — the config yaml is the
   source of truth, but the values file is what Helm actually applies.
3. `kong/kong.decK.yaml` — add the service + its two regex routes (read vs write), then
   `deck-sync.sh`. Nothing in the pipeline touches Kong, so a route change is live only after a sync.
4. `db-host/init/` — add its database + user; recreate/rerun on the DB host.
5. Jenkins `casc.yaml` — a `pipelineJob('<svc>')` + a `db-password-<svc>` credential.

**Adding a catalogue to an existing service** is steps 1 and 3 only: append the prefix to the
`catalogues:` list and to *both* Kong regexes. The app serves it as soon as it deploys, but Kong
404s (`no Route matched`) until `deck-sync.sh` runs. Keep the Kong prefix set exactly equal to the
service's `@RequestMapping` prefixes — drift in either direction is invisible until someone calls
the endpoint.
No Terraform/VPC/cluster changes — the platform is already there.

## Developer access (DB GUIs + k8s logs)
Everything data-plane is private; developers reach it through the **bastion** (key-only SSH — no IP
allow-listing). The operator hands a developer: the SSH key `oas-key.pem`, the current bastion IP
(`terraform -chdir=terraform/environments/oas-uat output -raw bastion_public_ip`), and — for k8s —
the cluster kubeconfig (`scratch_kubeconfig`). No addresses are hardcoded here; the scripts derive the
bastion IP from `terraform output`, or the developer passes `BASTION=<ip>`.

### Database GUIs & clients — `scripts/db-tunnels.sh` (share with any developer)
Standalone: needs only the script + `oas-key.pem` in one folder. Opens local tunnels to the DB
host's GUIs/ports:
```bash
./db-tunnels.sh <bastion-public-ip>    # keep open; Ctrl-C to close
```
| Tool | Open on your machine |
|---|---|
| pgAdmin (Postgres) | `http://localhost:5050` (server "OAS Postgres" pre-registered) |
| Kibana (Elasticsearch) | `http://localhost:5601` |
| Elasticvue (Elasticsearch) | browser extension → add cluster `http://localhost:9200` |
| RedisInsight (Redis) | `http://localhost:5540` → add DB host `redis`, port `6379`, no auth |
| Postgres client (psql / DBeaver) | `localhost:5432` |
| Redis client (redis-cli) | `localhost:6379` |

### Kubernetes logs — `scripts/kube-access.sh` (share ONLY with a trusted teammate)
Standalone: needs the script + `oas-key.pem` + `oas-kubeconfig` in one folder. Tunnels to the private
API and drops you into a shell where `kubectl` works. The kubeconfig is **admin-level** — share it
securely and only with someone who should have full cluster access:
```bash
./kube-access.sh <bastion-public-ip>   # exit the shell to close the tunnel
```
Common debug commands (all namespaces):
```bash
kubectl get pods -A
kubectl logs -n app deploy/catalogue-service --tail=200        # agri (+ audit) app logs
kubectl logs -n app deploy/org-user-notification-services --tail=200   # org app logs
kubectl logs -n app deploy/catalogue-service -f                # follow live
kubectl logs -n app <pod> --previous                           # a crashed container's last logs
kubectl describe pod -n app <pod>                              # events: ImagePull / OOM / probe fails
kubectl get events -n app --sort-by=.lastTimestamp | tail -20
kubectl logs -n platform deploy/kong-kong --tail=100           # gateway: routing / auth issues
```

## Security notes (UAT)
Static, non-secret role keys for now; `superadmin` key rotation is manual. Kong Admin API and the
Kubernetes API are never public (reached via the bastion). Elasticsearch runs with security
disabled **only** because it is not internet-reachable (SG-restricted to the k8s nodes and the
bastion). Pre-prod would add TLS/domain, real IAM/RBAC, and rate-limiting enforcement.

**TEMPORARY — `oas-auth-service` is exposed through Kong.** The auth service is normally
internal-only (ClusterIP, no route). It is routed through Kong (`~/auth/v1/.*` +
`~/actuator/health/.*`) so integration partners can exercise it directly, without a bastion tunnel
and the workarounds that come with it.

Token issuance itself is *not* open: `CATALOGUE_VALIDATE_ENABLED=true`, so `auth_token_create` takes
`{email, password}`, has the user-catalogue verify them, and fails closed. What remains accepted for
UAT is that the **user-management** endpoints (`auth_user_create`, `auth_user_revoke`,
`auth_user_delete`) still authenticate no caller — the role API key is the only gate. Since
`auth_user_create` is an upsert that rewrites `org_id`/`functional_role`, a key holder can alter another
identity's claims or delete it. Acceptable while UAT is a closed group with rotatable keys; not
acceptable in prod.

**Revert to strictly private before prod:** delete the `oas-auth-service` block (marked `TEMP/UAT`)
in [kong/kong.decK.yaml](kong/kong.decK.yaml), re-run `kong/scripts/deck-sync.sh` (the declarative
sync prunes it and `/auth/v1/*` 404s again), then drop the `auth:` block in
[services/oas-auth-service.config.yaml](services/oas-auth-service.config.yaml) and the hosted default
in the auth service's Postman collection. An interim step, if the exposure needs to outlast UAT:
narrow the route to `~/auth/v1/auth_token_.*` so only the credential-checked endpoints are public.

## License
MIT — see [LICENSE](LICENSE).
