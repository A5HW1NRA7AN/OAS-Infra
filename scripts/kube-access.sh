#!/usr/bin/env bash
# Open a shell where kubectl talks to the OAS cluster (view pods, read logs). Type 'exit' to close.
set -e
cd "$(dirname "$0")"

[ -f config.env ] && source config.env
BASTION_IP="${BASTION_IP:-${1:-}}"
[ -n "$BASTION_IP" ] || { echo "Set BASTION_IP in config.env (or pass the bastion IP as an argument)."; exit 1; }

command -v kubectl >/dev/null || { echo "kubectl is not installed. Install it, then re-run."; echo "  macOS: brew install kubectl   |   docs: https://kubernetes.io/docs/tasks/tools/"; exit 1; }
chmod 600 oas-key.pem 2>/dev/null || true

echo "Connecting to the cluster..."
ssh -i oas-key.pem -N -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
  -o ExitOnForwardFailure=yes -L 16443:10.0.20.26:6443 ubuntu@"$BASTION_IP" &
TUNNEL=$!
trap 'kill "$TUNNEL" 2>/dev/null' EXIT
sleep 3

export KUBECONFIG="$PWD/oas-kubeconfig"
kubectl get pods -n app >/dev/null 2>&1 || { echo "Could not reach the cluster (is local port 16443 free, and the IP in config.env current?)."; exit 1; }

echo
echo "Connected. Pods:"
kubectl get pods -n app
echo
echo "Type any of these (then Enter). 'exit' closes the connection:"
echo "  kubectl logs -n app deploy/catalogue-service --tail=200        # agri"
echo "  kubectl logs -n app deploy/org-user-notification-services --tail=200   # org"
echo "  kubectl logs -n app deploy/catalogue-service -f                # follow live"
echo "  kubectl logs -n platform deploy/kong-kong --tail=100           # gateway"
echo
bash
