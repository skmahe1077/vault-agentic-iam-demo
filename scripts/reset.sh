#!/usr/bin/env bash
# Restores a clean state between rehearsals.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"

echo "Killing leaked orders-db connections..."
docker exec orders-db psql -U orders_admin -d orders -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'orders' AND pid <> pg_backend_pid();" \
  || echo "orders-db not running, skipping."

echo "Restoring checkout-service readiness/liveness probes..."
kubectl config use-context "${CLUSTER_NAME}" >/dev/null 2>&1 && \
kubectl -n prod-checkout patch deployment checkout-service --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/path", "value": "/"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/"}
]' || echo "EKS cluster context '${CLUSTER_NAME}' not reachable, skipping."

echo "Reset complete."
