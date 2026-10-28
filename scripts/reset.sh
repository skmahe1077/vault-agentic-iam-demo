#!/usr/bin/env bash
# Restores a clean state between rehearsals.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${ORDERS_DB_ADMIN_PASSWORD:?set to the orders-db admin password (from .env)}"

echo "Killing leaked orders-db connections..."
"${SCRIPT_DIR}/lib/orders-psql.sh" orders_admin "${ORDERS_DB_ADMIN_PASSWORD}" -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'orders' AND pid <> pg_backend_pid();" \
  || echo "orders-db unreachable (proxy port-forward down?), skipping."

echo "Restoring checkout-service readiness/liveness probes..."
kubectl config use-context "${CLUSTER_NAME}" >/dev/null 2>&1 && \
kubectl -n prod-checkout patch deployment checkout-service --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/path", "value": "/"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/"}
]' || echo "EKS cluster context '${CLUSTER_NAME}' not reachable, skipping."

echo "Reset complete."
