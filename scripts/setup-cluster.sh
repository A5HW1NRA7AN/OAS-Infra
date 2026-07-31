#!/usr/bin/env bash
# setup-cluster.sh — orchestrates the OAS platform bootstrap for the new
# VPC-based architecture (see docs/deployment-plan.md).
#
# Stages (run all, or a single one):
#   terraform   Provision VPC + bastion/NAT + nginx + db-host + k8s-node.
#   dbhost      Deliver db-host/ compose stack over the bastion and start it
#               (Postgres[acs_db,oas_db,kong] + Elasticsearch + Redis + GUIs).
#   kubespray   Install Kubernetes on the PRIVATE k8s node via the bastion.
#   postinstall Namespaces, local-path, ECR pull secret; fetch kubeconfig.
#   kong        Deploy Kong (DB mode, Postgres on the db-host) via Helm.
#   deck        Sync kong/kong.decK.yaml (routes + RBAC consumers) via decK.
#
#   Usage:  scripts/setup-cluster.sh [stage]     (no stage = all, in order)
#
# Prereqs: terraform, helm, kubectl, ssh, scp, deck. db-host/.env and kong/.env
# must exist (copy from the .example files). Application services (agri, org)
# are deployed by Jenkins AFTER this, not here.
set -euo pipefail

STAGE="${1:-all}"
ENV_NAME="oas-uat"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"
export KUBECONFIG="$REPO_ROOT/scratch_kubeconfig"

# shellcheck disable=SC1091
[ -f "$ENV_DIR/env.sh" ] && source "$ENV_DIR/env.sh" || true
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/kube-tunnel.sh"

ssh_bastion() { ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$BASTION_IP" "$@"; }
ssh_via_bastion() { # ssh_via_bastion <private-ip> <cmd...>
  local host="$1"; shift
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
      "ubuntu@$host" "$@"
}

stage_terraform() {
  echo "== [terraform] provisioning VPC + all tiers =="
  ( cd "$ENV_DIR" && terraform init && terraform apply -auto-approve )
  # shellcheck disable=SC1091
  source "$ENV_DIR/env.sh"
  echo "bastion=$BASTION_IP nginx=$NGINX_IP node=$NODE_PRIVATE_IP db=$DB_HOST_IP"
}

stage_dbhost() {
  echo "== [dbhost] delivering docker-compose stack to $DB_HOST_IP via bastion =="
  [ -f "$REPO_ROOT/db-host/.env" ] || { echo "ERROR: create db-host/.env from db-host/.env.example" >&2; exit 1; }
  # Copy the whole db-host/ dir (compose + init + gui + .env) through the bastion.
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
      -r "$REPO_ROOT/db-host" "ubuntu@$DB_HOST_IP:/opt/oas-db/"
  ssh_via_bastion "$DB_HOST_IP" "cd /opt/oas-db/db-host && docker compose --env-file .env up -d && docker compose ps"
}

stage_kubespray() {
  echo "== [kubespray] installing Kubernetes on the private node via bastion =="
  bash "$REPO_ROOT/kubernetes/kubespray/deploy_kubespray.sh" "$ENV_NAME"
}

stage_postinstall() {
  echo "== [postinstall] namespaces, storage, ECR secret, kubeconfig =="
  bash "$REPO_ROOT/kubernetes/kubespray/post_install.sh" "$ENV_NAME"
}

stage_kong() {
  echo "== [kong] deploying Kong (DB mode) via Helm =="
  # shellcheck disable=SC1091
  set -a; . "$REPO_ROOT/db-host/.env"; set +a   # KONG_DB_PASSWORD
  helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
  helm repo update >/dev/null
  open_kube_tunnel 6443; trap close_kube_tunnel RETURN
  kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install kong kong/kong -n platform \
    --set env.database=postgres \
    --set env.pg_host="$DB_HOST_IP" \
    --set env.pg_port=5432 \
    --set env.pg_user=kong_user \
    --set env.pg_password="$KONG_DB_PASSWORD" \
    --set env.pg_database=kong \
    --set proxy.type=NodePort \
    --set proxy.http.nodePort=30080 \
    --set admin.enabled=true \
    --set admin.type=ClusterIP \
    --set migrations.preUpgrade=true \
    --set migrations.postUpgrade=true \
    --wait --timeout 300s
  echo "Kong deployed. Proxy NodePort 30080 (fronted by nginx at http://$NGINX_IP)."
}

stage_deck() {
  echo "== [deck] syncing Kong routes + RBAC consumers =="
  bash "$REPO_ROOT/kong/scripts/deck-sync.sh"
}

case "$STAGE" in
  terraform)   stage_terraform ;;
  dbhost)      stage_dbhost ;;
  kubespray)   stage_kubespray ;;
  postinstall) stage_postinstall ;;
  kong)        stage_kong ;;
  deck)        stage_deck ;;
  all)
    stage_terraform
    stage_dbhost
    stage_kubespray
    stage_postinstall
    stage_kong
    stage_deck
    ;;
  *) echo "Usage: $0 [terraform|dbhost|kubespray|postinstall|kong|deck|all]" >&2; exit 1 ;;
esac

echo ""
echo "=== setup-cluster ($STAGE) complete ==="
echo "Next: run the Jenkins jobs (agri-catalogue-service, organisation-catalogue)"
echo "to build/push/deploy the app pods (through the bastion). Then hand developers"
echo "the base URL http://$NGINX_IP and their role API keys."
