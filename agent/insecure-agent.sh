#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${STATIC_ORDERS_DB_PASSWORD:?set to the static orders_admin password (the standing credential)}"
: "${STATIC_K8S_TOKEN:?set to a long-lived, broad ServiceAccount token (the standing credential)}"

K8S_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' --context "${CLUSTER_NAME}")
EPHEMERAL_KUBECONFIG=$("${SCRIPT_DIR}/../scripts/lib/ephemeral-kubeconfig.sh" "${STATIC_K8S_TOKEN}" "${K8S_SERVER}")

echo
echo "\$ vault read agent-registry/registration/display-name/sre-incident-agent-insecure"
vault read agent-registry/registration/display-name/sre-incident-agent-insecure || true

echo
echo "\$ psql -U orders_admin -c \"SELECT count(*) FROM pg_stat_activity WHERE datname = 'orders';\""
"${SCRIPT_DIR}/../scripts/lib/orders-psql.sh" orders_admin "${STATIC_ORDERS_DB_PASSWORD}" -c \
  "SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = 'orders';"

echo
echo "\$ kubectl -n prod-checkout rollout restart deployment/checkout-service"
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-checkout rollout restart deployment/checkout-service

echo
echo "\$ psql -U orders_admin -c \"SELECT customer_id, card_last4, balance_cents FROM billing_accounts;\""
"${SCRIPT_DIR}/../scripts/lib/orders-psql.sh" orders_admin "${STATIC_ORDERS_DB_PASSWORD}" -c \
  "SELECT customer_id, card_last4, balance_cents FROM billing_accounts;"

echo
echo "\$ kubectl -n prod-billing rollout restart deployment/billing-service"
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-billing rollout restart deployment/billing-service

rm -f "${EPHEMERAL_KUBECONFIG}"
