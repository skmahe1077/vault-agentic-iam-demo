#!/usr/bin/env bash
# Opening scene: fire the incident.
# 1) Hold a pile of idle connections open against orders-db to simulate the
#    connection-pool exhaustion that the diagnose step (database/creds/readonly-orders)
#    will reveal.
# 2) Patch checkout-service with a broken readiness probe path so it starts
#    crash-looping, which the fix step (kubernetes/creds/checkout-restart-role) resolves
#    with a rollout restart once the real cause is addressed.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
LEAK_CONN_COUNT="${LEAK_CONN_COUNT:-18}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/pause.sh"

: "${ORDERS_DB_ADMIN_PASSWORD:?set to the orders-db admin password (from .env)}"

kubectl config use-context "${CLUSTER_NAME}" >/dev/null

echo
echo "\$ kubectl -n prod-checkout get pods"
kubectl -n prod-checkout get pods
pause

for i in $(seq 1 "${LEAK_CONN_COUNT}"); do
  "${SCRIPT_DIR}/lib/orders-psql.sh" orders_admin "${ORDERS_DB_ADMIN_PASSWORD}" \
    -c "SELECT pg_sleep(600);" >/dev/null 2>&1 &
done

echo
echo "\$ kubectl -n prod-checkout patch deployment checkout-service ..."
kubectl -n prod-checkout patch deployment checkout-service --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/path", "value": "/__bad_health_path__"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/__bad_health_path__"}
]'
pause

echo
echo "\$ kubectl -n prod-checkout get pods"
kubectl -n prod-checkout get pods
pause
