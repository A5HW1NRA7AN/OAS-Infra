# OAS-Infra — Full Setup Implementation Plan

Build out the OAS-Infra repository from its current scaffolding state to a deployable pilot, using proven patterns from the **Telephony-Infrastructure** and **Jenkins** reference repos.

---

## Current State Assessment

### What OAS-Infra already has (well-built)
| Asset | Status | Notes |
|---|---|---|
| `service.config.yaml` | ✅ Complete | Single source of truth, well-structured |
| `helm/catalogue-service/` | ✅ Complete | Chart.yaml, values.yaml, all 4 templates (`_helpers.tpl`, `deployment.yaml`, `service.yaml`, `configmap.yaml`) |
| `kong/kong.yml` | ✅ Complete | Declarative config with placeholder keys, `strip_path: false`, 10 consumers |
| `jenkins/Jenkinsfile` | ✅ Complete | Build → Push ECR → SSH Deploy → Smoke Test pipeline |
| `scripts/generate-kong-routes.sh` | ✅ Complete | OpenAPI-driven route discovery |
| `scripts/refresh-ecr-secret.sh` | ✅ Complete | ECR token refresh for non-EKS clusters |
| `docs/deployment-plan.md` | ✅ Complete | Comprehensive 9-phase architecture rationale |
| `.agents/` | ✅ Complete | Rules, skills, workflows |

### What OAS-Infra is MISSING (must build)
| Gap | Reference Pattern | Priority |
|---|---|---|
| **Terraform for EC2 provisioning** | `Telephony-Infrastructure/freeswitch-kubernetes/terraform/` | 🔴 Critical |
| **Kubespray automation scripts** | `Telephony-Infrastructure/freeswitch-kubernetes/kubespray/` | 🔴 Critical |
| **Jenkins server setup (Dockerfile + JCasC)** | `Jenkins/` (standalone repo) | 🔴 Critical |
| **Jenkins Terraform (EC2 for Jenkins itself)** | `Telephony-Infrastructure/jenkins/terraform/` | 🟡 Medium |
| **`.env.example` template** | `Telephony-Infrastructure/.env.example` | 🟢 Easy |
| **Userdata bootstrap templates** | `Telephony-Infrastructure/*/terraform/templates/` | 🔴 Critical |

---

## User Review Required

> [!IMPORTANT]
> **Architecture choice — single EC2 without bastion/proxy:**  
> The Telephony-Infrastructure uses a 3-instance pattern (Bastion + Proxy + Server) because FreeSWITCH needs SIP/RTP traffic routing. The OAS-Infra deployment plan specifies a **single EC2 with an Elastic IP** — no bastion, no proxy. Kong on NodePort `:30080` is the only entry point. I will follow the simpler single-EC2 pattern from `deployment-plan.md`. Confirm this is still the intent.

> [!IMPORTANT]
> **Jenkins hosting — reuse existing or provision new?**  
> The deployment plan says *"Jenkins (already exists elsewhere)"*. The reference repos show how to provision a **new** Jenkins EC2 with Terraform + Dockerized Jenkins. Should I:
> - **(A)** Add Terraform + Docker config to OAS-Infra for a **dedicated Jenkins** instance (like the reference repos do)?
> - **(B)** Only add the **Jenkins job/credential config** (JCasC, plugins.txt) assuming you'll deploy it on your **existing Jenkins** server?
> - **(C)** Do both — full Jenkins provisioning Terraform **plus** the JCasC config — so you have the option?

> [!IMPORTANT]
> **AWS Region:**  
> Telephony-Infrastructure uses `ap-northeast-1` (Tokyo). OAS-Infra's `deployment-plan.md` specifies `ap-south-1` (Mumbai). I will use `ap-south-1` throughout. Confirm.

---

## Open Questions

> [!IMPORTANT]
> **ECR repo name:** The service config references `379220350808.dkr.ecr.ap-south-1.amazonaws.com/catalogue-service`. Is this ECR repository already created, or should the Terraform include an `aws_ecr_repository` resource?

> [!NOTE]
> **IAM Instance Profile:** The Telephony repo references `EC2-ECR-Read-Role` as a pre-existing IAM instance profile. Does this same profile exist in `ap-south-1`, or should Terraform create a new one (e.g., `OAS-ECR-Read-Role`)?

> [!NOTE]
> **SSH Admin IP restriction:** The deployment plan says SSH should be restricted to "your admin IP and Jenkins' IP." Do you have specific CIDRs, or should I default to `0.0.0.0/0` for now with a `TODO` comment?

---

## Proposed Changes

### Component 1 — EC2 Provisioning (Terraform)

Adapted from [Telephony-Infrastructure/freeswitch-kubernetes/terraform/](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-kubernetes/terraform) but simplified to a **single EC2** (no bastion, no proxy) per the deployment plan.

#### [NEW] terraform/main.tf
- AWS provider config for `ap-south-1`
- Required providers: `hashicorp/aws ~> 5.0`, `hashicorp/tls ~> 4.0`
- **No VPC module** — use default VPC (simpler for pilot, like the Jenkins Terraform reference does) **OR** create a dedicated VPC
- Auto-generated SSH key pair (pattern from [security.tf](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-ec2/terraform/security.tf#L1-L17))

#### [NEW] terraform/variables.tf
- `aws_region` (default: `ap-south-1`)
- `cluster_name` (default: `OAS-Pilot`)
- `instance_type` (default: `t3.xlarge` — per deployment plan §3)
- `root_volume_size` (default: `150` — per deployment plan §3)
- `key_name` (default: `oas-pilot-key-pair`)
- `allowed_ssh_cidrs` (list, default: `["0.0.0.0/0"]` with TODO)
- `allowed_kong_cidrs` (list, default: `["0.0.0.0/0"]`)
- `iam_instance_profile` (default: `EC2-ECR-Read-Role`)

#### [NEW] terraform/security.tf
- Security group for the single K8s node:
  - `22/tcp` from `allowed_ssh_cidrs`
  - `30080/tcp` from `allowed_kong_cidrs` (Kong NodePort)
  - All egress open
  - **No** 5432, 6379, 9200, 6443 exposed externally

#### [NEW] terraform/instances.tf
- Ubuntu 22.04 LTS AMI lookup (deployment plan §3 specifies 22.04, not 24.04)
- Single `aws_instance` with:
  - `t3.xlarge`, 150 GB `gp3` root volume
  - IAM instance profile for ECR
  - Userdata template for Docker + containerd bootstrap
- Elastic IP attachment

#### [NEW] terraform/outputs.tf
- `node_public_ip` (Elastic IP)
- `node_private_ip`
- `ssh_connection_string`
- Auto-generated `env.sh` (pattern from [outputs.tf](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-ec2/terraform/outputs.tf#L28-L41))
- Auto-generated `hosts_k8s.yaml` for Kubespray (pattern from [outputs.tf](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-ec2/terraform/outputs.tf#L43-L72))

#### [NEW] terraform/templates/userdata.sh.tpl
- Based on [userdata_server.sh.tpl](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-ec2/terraform/templates/userdata_server.sh.tpl) but:
  - Installs Docker, containerd, `helm`, `kubectl`, AWS CLI
  - Sets up `local-path-provisioner` prerequisite directories
  - Configures ECR credential helper

---

### Component 2 — Kubespray Automation

Adapted from [freeswitch-kubernetes/kubespray/](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-kubernetes/kubespray).

#### [NEW] kubespray/deploy_kubespray.sh
- Modeled on [deploy_kubespray_wsl.sh](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/freeswitch-kubernetes/kubespray/deploy_kubespray_wsl.sh)
- Sources `env.sh` from Terraform output
- Copies `hosts_k8s.yaml` to Kubespray inventory
- Runs `ansible-playbook cluster.yml` with the SSH key
- Sets `container_manager: containerd` and `kube_proxy_mode: iptables`

#### [NEW] kubespray/post_install.sh
- Creates namespaces: `platform`, `data`, `app`
- Installs `local-path-provisioner` and sets as default StorageClass
- Creates initial ECR pull secret in `app` namespace
- Creates `postgres-creds` secret in `data` namespace (prompts for password)
- Fetches kubeconfig from the node

---

### Component 3 — Jenkins CI/CD Setup

Adapted from the [Jenkins](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Jenkins) standalone repo pattern.

#### [NEW] jenkins/Dockerfile
- Based on [Jenkins/Dockerfile](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Jenkins/Dockerfile)
- `jenkins/jenkins:lts-jdk17`
- Installs: Docker CLI, AWS CLI v2, Maven, `kubectl`, `helm`
- Pre-installs plugins from `plugins.txt`

#### [NEW] jenkins/docker-compose.yml
- Based on [Jenkins/docker-compose.yml](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Jenkins/docker-compose.yml)
- Mounts JCasC, Docker socket
- Environment variables from `.env`

#### [NEW] jenkins/casc.yaml
- Based on [Jenkins/casc.yaml](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Jenkins/casc.yaml) but tailored for OAS:
  - System message: "Jenkins CI/CD for Agri Catalogue Service (OAS)"
  - Credentials: AWS ECR, GitHub, SSH key for EC2 deployment, Smoke test API key
  - Single Job DSL pipeline: `catalogue-service` pointing to the app repo's `main` branch, using [Jenkinsfile](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/OAS-Infra/jenkins/Jenkinsfile)

#### [NEW] jenkins/plugins.txt
- Based on [Jenkins/plugins.txt](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Jenkins/plugins.txt):
  ```
  configuration-as-code
  git
  workflow-aggregator
  pipeline-stage-view
  amazon-ecr
  aws-credentials
  docker-workflow
  pipeline-utility-steps
  job-dsl
  ssh-agent
  ```
  - Added `ssh-agent` (required by the Jenkinsfile `sshagent` step)
  - Removed `kubernetes-cli` (not needed — deployment is via SSH, not direct k8s API)

---

### Component 4 — Jenkins EC2 Provisioning (Terraform)

Adapted from [Telephony-Infrastructure/jenkins/terraform/](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/jenkins/terraform).

#### [NEW] jenkins/terraform/main.tf
- Adapted from [main.tf](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/Telephony-Infrastructure/jenkins/terraform/main.tf)
- Default VPC, Ubuntu 24.04 AMI
- `t3.medium` Jenkins EC2
- Security group: SSH (22) + Jenkins UI (8080)
- Userdata installs Docker + Docker Compose

#### [NEW] jenkins/terraform/variables.tf
#### [NEW] jenkins/terraform/outputs.tf
#### [NEW] jenkins/terraform/templates/userdata_jenkins.sh.tpl

---

### Component 5 — Environment & Secrets Setup

#### [NEW] .env.example
```ini
# OAS-Infra Environment Variables
# Copy to .env and configure — DO NOT COMMIT .env

# Jenkins Dashboard
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=

# AWS Access (for ECR push/pull)
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=ap-south-1

# GitHub (for repo checkout)
GITHUB_USER=
GITHUB_TOKEN=

# SSH key for EC2 deployment (base64 or path)
SSH_PRIVATE_KEY=

# Catalogue Service App Repo URL
CATALOGUE_REPO_URL=
```

#### [MODIFY] [.gitignore](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/OAS-Infra/.gitignore)
- Add `env.sh` (Terraform-generated)
- Add `hosts_k8s.yaml` (Terraform-generated)
- Add `scratch_kubeconfig`

---

### Component 6 — Operational Scripts

#### [NEW] scripts/setup-cluster.sh
- Orchestrator script that wraps:
  1. Terraform apply (EC2 provisioning)
  2. Kubespray deployment
  3. Post-install (namespaces, storage class, secrets)
  4. Data services (Bitnami Helm installs from deployment-plan §6)
  5. Kong install
  6. App deploy

#### [MODIFY] [scripts/refresh-ecr-secret.sh](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/OAS-Infra/scripts/refresh-ecr-secret.sh)
- No changes needed — already well-implemented

---

### Component 7 — README & Documentation Updates

#### [MODIFY] [README.md](file:///wsl.localhost/Ubuntu-24.04/home/rajan/Projects/OAS-Infra/README.md)
- Add "Infrastructure Provisioning" section covering Terraform + Kubespray
- Add "Jenkins Setup" section
- Update "Repo Layout" tree to include new directories
- Add "First-Time Setup" walkthrough linking the new scripts

---

## Proposed Repo Layout (After Implementation)

```
OAS-Infra/
├── AGENTS.md
├── README.md
├── service.config.yaml
├── .env.example                          # [NEW]
├── .gitignore                            # [MODIFIED]
├── docs/
│   └── deployment-plan.md
├── terraform/                            # [NEW] — EC2 for K8s node
│   ├── main.tf
│   ├── variables.tf
│   ├── security.tf
│   ├── instances.tf
│   ├── outputs.tf
│   └── templates/
│       └── userdata.sh.tpl
├── kubespray/                            # [NEW] — K8s bootstrap
│   ├── deploy_kubespray.sh
│   └── post_install.sh
├── jenkins/
│   ├── Jenkinsfile                       # (existing)
│   ├── Dockerfile                        # [NEW]
│   ├── docker-compose.yml                # [NEW]
│   ├── casc.yaml                         # [NEW]
│   ├── plugins.txt                       # [NEW]
│   └── terraform/                        # [NEW] — EC2 for Jenkins
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── templates/
│           └── userdata_jenkins.sh.tpl
├── helm/
│   └── catalogue-service/                # (existing, complete)
├── kong/
│   └── kong.yml                          # (existing, complete)
├── scripts/
│   ├── generate-kong-routes.sh           # (existing)
│   ├── refresh-ecr-secret.sh             # (existing)
│   └── setup-cluster.sh                  # [NEW]
└── .agents/                              # (existing, complete)
```

---

## Execution Order

| Step | Component | Dependencies |
|---|---|---|
| 1 | `.env.example` + `.gitignore` updates | None |
| 2 | **Terraform (EC2 for K8s node)** | None |
| 3 | **Kubespray scripts** | Step 2 (needs Terraform outputs) |
| 4 | **Jenkins Docker setup** (Dockerfile, compose, CasC, plugins) | None (parallel with 2–3) |
| 5 | **Jenkins Terraform** (EC2 for Jenkins) | None (parallel with 2–3) |
| 6 | **setup-cluster.sh** orchestrator | Steps 2, 3 |
| 7 | **README updates** | After all code is written |

---

## Verification Plan

### Automated Tests
```bash
# Terraform validation (no AWS credentials needed)
cd terraform && terraform init && terraform validate
cd jenkins/terraform && terraform init && terraform validate

# Helm chart lint
helm lint helm/catalogue-service/

# Shell script lint
shellcheck scripts/*.sh kubespray/*.sh

# YAML validation
yq '.' kong/kong.yml > /dev/null
yq '.' jenkins/casc.yaml > /dev/null
```

### Manual Verification
- `terraform plan` against your AWS account (dry run — no resources created)
- Jenkins `docker-compose up --build` locally to verify Dockerfile + plugins install
- Walk through `setup-cluster.sh` steps mentally against `deployment-plan.md` to confirm full coverage
