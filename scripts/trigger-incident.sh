#!/usr/bin/env bash
# Beat 0: fire the incident.
# 1) Hold a pile of idle connections open against orders-db to simulate the
#    connection-pool exhaustion that the diagnose step (database/creds/readonly-orders)
#    will reveal.
# 2) Patch checkout-service with a broken readiness probe path so it starts
#    crash-looping, which the fix step (kubernetes/creds/checkout-restart-role) resolves
#    with a rollout restart once the real cause is addressed.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
LEAK_CONN_COUNT="${LEAK_CONN_COUNT:-18}"

echo "Opening ${LEAK_CONN_COUNT} idle connections against orders-db..."
for i in $(seq 1 "${LEAK_CONN_COUNT}"); do
  docker exec -d orders-db psql -U orders_admin -d orders -c "SELECT pg_sleep(600);"
done

echo "Breaking checkout-service readiness probe to induce CrashLoopBackOff..."
kubectl config use-context "${CLUSTER_NAME}" >/dev/null
kubectl -n prod-checkout patch deployment checkout-service --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/path", "value": "/__bad_health_path__"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/__bad_health_path__"}
]'

echo "Incident fired: checkout-service degrading, orders-db connections elevated."
echo "Check with: kubectl -n prod-checkout get pods"
