#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo
echo "\$ vault read database/creds/readonly-orders"
DIAG_TOKEN=$(RAR_PATH="database/creds/readonly-orders" RAR_CAPABILITY="read" \
  "${SCRIPT_DIR}/../scripts/lib/request-delegation-token.sh")
DB_CREDS=$(VAULT_TOKEN="${DIAG_TOKEN}" vault read -format=json database/creds/readonly-orders)
echo "${DB_CREDS}" | jq 'del(.data.password)'
DB_USER=$(echo "${DB_CREDS}" | jq -r '.data.username')
DB_PASS=$(echo "${DB_CREDS}" | jq -r '.data.password')

echo
echo "\$ psql -U ${DB_USER} -c \"SELECT count(*) FROM pg_stat_activity WHERE datname = 'orders';\""
"${SCRIPT_DIR}/../scripts/lib/orders-psql.sh" "${DB_USER}" "${DB_PASS}" -c \
  "SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = 'orders';"

echo
echo "\$ vault write kubernetes/creds/billing-restart-role kubernetes_namespace=prod-billing"
set +e
OVERREACH_TOKEN=$(RAR_PATH="kubernetes/creds/billing-restart-role" RAR_CAPABILITY="update" \
  "${SCRIPT_DIR}/../scripts/lib/request-delegation-token.sh")
VAULT_TOKEN="${OVERREACH_TOKEN}" vault write kubernetes/creds/billing-restart-role kubernetes_namespace=prod-billing
STATUS=$?
set -e
if [ ${STATUS} -eq 0 ]; then
  echo "UNEXPECTED: overreach succeeded -- ceiling policy is not holding. Investigate."
  exit 1
fi

echo
echo "\$ vault write kubernetes/creds/checkout-restart-role kubernetes_namespace=prod-checkout"
FIX_TOKEN=$(RAR_PATH="kubernetes/creds/checkout-restart-role" RAR_CAPABILITY="update" \
  "${SCRIPT_DIR}/../scripts/lib/request-delegation-token.sh")
K8S_CREDS=$(VAULT_TOKEN="${FIX_TOKEN}" vault write -format=json kubernetes/creds/checkout-restart-role kubernetes_namespace=prod-checkout)
echo "${K8S_CREDS}" | jq 'del(.data.service_account_token)'
K8S_TOKEN=$(echo "${K8S_CREDS}" | jq -r '.data.service_account_token')
K8S_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' --context "${CLUSTER_NAME}")
EPHEMERAL_KUBECONFIG=$("${SCRIPT_DIR}/../scripts/lib/ephemeral-kubeconfig.sh" "${K8S_TOKEN}" "${K8S_SERVER}")

echo
echo "\$ kubectl -n prod-checkout rollout restart deployment/checkout-service"
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-checkout rollout restart deployment/checkout-service

echo
echo "\$ kubectl -n prod-checkout get deployment checkout-service"
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-checkout get deployment checkout-service

rm -f "${EPHEMERAL_KUBECONFIG}"
