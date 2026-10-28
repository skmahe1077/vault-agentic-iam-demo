#!/usr/bin/env bash
# Beat 1: the anti-pattern. sre-incident-agent-insecure holds a static,
# standing DB password and a long-lived, broad Kubernetes ServiceAccount
# token. No Vault involved, no per-task scoping, no expiry, no link back to
# an incident ticket or an approving human -- just a credential that works,
# forever, on everything.
#
# It "fixes" the incident, but it can also do this: read billing data and
# restart billing-service, neither of which has anything to do with the
# checkout-service incident it was asked about. That overreach is the point.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${STATIC_ORDERS_DB_PASSWORD:?set to the static orders_admin password (the standing credential)}"
: "${STATIC_K8S_TOKEN:?set to a long-lived, broad ServiceAccount token (the standing credential)}"

K8S_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' --context "${CLUSTER_NAME}")
# Route through an isolated kubeconfig so this genuinely exercises
# STATIC_K8S_TOKEN -- kubectl --token=X silently falls back to the active
# context's embedded admin cert instead of honoring the flag, which would
# make this script "work" via the wrong credential entirely.
EPHEMERAL_KUBECONFIG=$("${SCRIPT_DIR}/../../scripts/lib/ephemeral-kubeconfig.sh" "${STATIC_K8S_TOKEN}" "${K8S_SERVER}")

echo "=== insecure agent: diagnosing (using standing DB credential) ==="
"${SCRIPT_DIR}/../../scripts/lib/orders-psql.sh" orders_admin "${STATIC_ORDERS_DB_PASSWORD}" -c \
  "SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = 'orders';"

echo "=== insecure agent: fixing checkout-service (using standing K8s credential) ==="
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-checkout rollout restart deployment/checkout-service

echo
echo "=== insecure agent: nothing stopped it from going further ==="
echo "--- reading billing_accounts (never asked for, never scoped) ---"
"${SCRIPT_DIR}/../../scripts/lib/orders-psql.sh" orders_admin "${STATIC_ORDERS_DB_PASSWORD}" -c \
  "SELECT customer_id, card_last4, balance_cents FROM billing_accounts;"

echo "--- restarting billing-service (never asked for, never scoped) ---"
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-billing rollout restart deployment/billing-service

rm -f "${EPHEMERAL_KUBECONFIG}"
