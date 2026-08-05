#!/usr/bin/env bash
# Open the OAS databases and their web GUIs on your machine. Keep this window open.
set -e
cd "$(dirname "$0")"

[ -f config.env ] && source config.env
BASTION_IP="${BASTION_IP:-${1:-}}"
[ -n "$BASTION_IP" ] || { echo "Set BASTION_IP in config.env (or pass the bastion IP as an argument)."; exit 1; }
chmod 600 oas-key.pem 2>/dev/null || true

echo "Connecting... then open in your browser (Ctrl-C here to disconnect):"
echo "  pgAdmin       http://localhost:5050"
echo "  Kibana        http://localhost:5601"
echo "  Elasticvue    add cluster http://localhost:9200"
echo "  RedisInsight  http://localhost:5540   (add host 'redis' port 6379)"
echo "  Postgres localhost:5432   Redis localhost:6379"

ssh -i oas-key.pem -N \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
  -L 5050:10.0.10.10:5050 \
  -L 5601:10.0.10.10:5601 \
  -L 9200:10.0.10.10:9200 \
  -L 5540:10.0.10.10:5540 \
  -L 5432:10.0.10.10:5432 \
  -L 6379:10.0.10.10:6379 \
  ubuntu@"$BASTION_IP"
