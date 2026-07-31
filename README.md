# OAS-Infra — OpenAgriStack Catalogues

Infrastructure-as-code and deployment scaffolding for the **OAS catalogue services**
OAS registry framework: Spring Boot APIs backed by PostgreSQL, Redis, and Elasticsearch,
Kong API Gateway).

## Architecture

A purpose-built VPC with one public tier and two private tiers. Databases run as **Docker
containers on a dedicated host**; application services run as **Kubernetes pods**;
Kong (DB-backed) enforces API-key auth and role-based access.

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
   │        postgres:16 (acs_db, oas_db, kong) · elasticsearch:8.13 · redis:7  │
   │        pgAdmin · Kibana · RedisInsight  (bastion-tunnel only)             │
   └───────────────────────────────────────────────────────────────────────────┘
   Private subnets egress via the bastion NAT. Jenkins (external) reaches the
   private node via SSH ProxyJump through the bastion.
```

Request path: `http://<nginx-ip>/<catalogue>/v1/... (apikey header)` → nginx → Kong (key-auth +
acl) → catalogue pod → DB host. The apps have **no built-in auth** — Kong is the sole enforcement
point.

### Key decisions (UAT)
- **Databases as Docker on one EC2**. 
  One Postgres with three databases; shared ES/Redis. Extensible to cassandra/yugabyte via compose profiles.
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
  `k8s-node`, `iam`.
- [terraform/environments/oas-uat/](terraform/environments/oas-uat/) — composes the whole platform;
  generates `env.sh` + `hosts_k8s.yaml` (gitignored).
- [db-host/](db-host/) — the data tier's `docker-compose.yml`, `init/` (creates the 3 databases),
  `gui/servers.json`, `.env.example`.
- [kubernetes/helm/oas-catalogue/](kubernetes/helm/oas-catalogue/) — shared chart + per-service
  `values-<service>.yaml`.
- [kubernetes/kubespray/](kubernetes/kubespray/) — cluster bootstrap (bastion/ProxyJump aware).
- [kong/kong.decK.yaml](kong/kong.decK.yaml) — services, read/write regex routes, key-auth+acl,
  rate-limiting(off), 3 consumers. [kong/scripts/](kong/scripts/) — `deck-sync.sh`, `rotate-key.sh`.
- [services/](services/) — one source-of-truth config per service.
- [scripts/](scripts/) — `setup-cluster.sh` orchestrator, `refresh-ecr-secret.sh`, `flush-databases.sh`
  (wipe catalogue data for bulk re-ingest), `lib/kube-tunnel.sh`.
- [jenkins/Jenkinsfile](jenkins/Jenkinsfile) — CI/CD (ProxyJump through the bastion). The Jenkins
  controller + JCasC live in the separate **Jenkins** repo.

## Deploy (from scratch)
Prereqs: `terraform`, `helm`, `kubectl`, `deck`, `ssh`; copy `db-host/.env.example`→`db-host/.env`,
`kong/.env.example`→`kong/.env`, and `terraform/environments/oas-uat/terraform.tfvars.example`→
`terraform.tfvars` (lock `admin_ssh_cidrs`). Then:

```bash
scripts/setup-cluster.sh              # terraform → dbhost → kubespray → postinstall → kong → deck
# or run a single stage: scripts/setup-cluster.sh <terraform|dbhost|kubespray|postinstall|kong|deck>
```

Then, per service, run its Jenkins job with `BASTION_HOST` / `NODE_PRIVATE_IP` / `NGINX_HOST` from
`terraform output`. Hand developers the base URL `http://<nginx-ip>` and their role API key.
(Reminder: the agri job's `SERVICE` value is `agri-catalogue`, not the job name.)

Install `scripts/refresh-ecr-secret.sh` on the k8s node's cron (ECR tokens expire ~12h).

## Onboarding a new service
1. `services/<svc>.config.yaml` — repo, port, DB name/user, resources, chart/values pointers.
2. `kubernetes/helm/oas-catalogue/values-<svc>.yaml` — env → DB host, `secretName`, `fullnameOverride`.
3. `kong/kong.decK.yaml` — add the service + its two regex routes (read vs write), then `deck-sync.sh`.
4. `db-host/init/` — add its database + user; recreate/rerun on the DB host.
5. Jenkins `casc.yaml` — a `pipelineJob('<svc>')` + a `db-password-<svc>` credential.
No Terraform/VPC/cluster changes — the platform is already there.

## Security notes (UAT)
Static, non-secret role keys for now; `superadmin` key rotation is manual. Kong Admin API and the
Kubernetes API are never public (reached via the bastion). Elasticsearch runs with security
disabled **only** because it is not internet-reachable (SG-restricted to the k8s nodes and the
bastion). Pre-prod would add TLS/domain, real IAM/RBAC, and rate-limiting enforcement.

## License
MIT — see [LICENSE](LICENSE).
