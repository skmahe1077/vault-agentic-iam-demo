#!/usr/bin/env bash
# The Vault Agentic IAM + Ephemeral Authorization demo, in talk-abstract order:
# delegated authorization (diagnose) -> ceiling policy caps blast radius (the
# denied overreach) -> ephemeral per-request authorization doing the real,
# necessary fix. Every Vault action below runs under a freshly-exchanged
# delegation token, scoped by RAR to exactly one path + capability, requested
# on behalf of the approving on-call engineer, acting as sre-incident-agent.
# Access is only granted where ceiling-sre-incident-agent AND oncall-engineer's
# own policy AND the RAR claim all agree -- see vault-config/ceiling-policy.hcl.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== delegated authorization: diagnosing (database/creds/readonly-orders) ==="
DIAG_TOKEN=$(RAR_PATH="database/creds/readonly-orders" RAR_CAPABILITY="read" \
  "${SCRIPT_DIR}/request-delegation-token.sh")
DB_CREDS=$(VAULT_TOKEN="${DIAG_TOKEN}" vault read -format=json database/creds/readonly-orders)
DB_USER=$(echo "${DB_CREDS}" | jq -r '.data.username')
DB_PASS=$(echo "${DB_CREDS}" | jq -r '.data.password')
DB_TTL=$(echo "${DB_CREDS}" | jq -r '.lease_duration')
"${SCRIPT_DIR}/../../scripts/lib/orders-psql.sh" "${DB_USER}" "${DB_PASS}" -c \
  "SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = 'orders';"
# The role's own default_ttl is 3m, but the *effective* TTL here is
# min(role TTL, delegation JWT's remaining validity) -- in mock-IdP mode
# that JWT defaults to 60s (RAR_TTL env var overrides it), so report what
# Vault actually issued, not the role's configured ceiling.
echo "(credential ${DB_USER} expires in ${DB_TTL}s, read-only on orders, never touches billing_accounts)"

echo
echo "=== ceiling policy caps blast radius: overreach attempt (kubernetes/creds/billing-restart-role) ==="
echo "Requesting a delegation token scoped to billing-restart-role -- oncall-engineer's" \
     "own policy allows this, but the agent's ceiling policy does not."
set +e
OVERREACH_TOKEN=$(RAR_PATH="kubernetes/creds/billing-restart-role" RAR_CAPABILITY="update" \
  "${SCRIPT_DIR}/request-delegation-token.sh")
RESULT=$(VAULT_TOKEN="${OVERREACH_TOKEN}" vault write kubernetes/creds/billing-restart-role kubernetes_namespace=prod-billing 2>&1)
STATUS=$?
set -e
if [ ${STATUS} -ne 0 ]; then
  echo "DENIED as expected:"
  echo "${RESULT}"
else
  echo "UNEXPECTED: overreach succeeded -- ceiling policy is not holding. Investigate."
  exit 1
fi

echo
echo "=== ephemeral per-request authorization: fixing checkout-service (kubernetes/creds/checkout-restart-role) ==="
# "update", not "read" -- generating K8s secrets engine creds takes a body
# param (kubernetes_namespace) via `vault write`, a PUT, unlike the
# database engine's plain GET above. A read-only RAR/ceiling/policy here
# gets a bare "permission denied" with no ceiling-specific hint.
FIX_TOKEN=$(RAR_PATH="kubernetes/creds/checkout-restart-role" RAR_CAPABILITY="update" \
  "${SCRIPT_DIR}/request-delegation-token.sh")
K8S_CREDS=$(VAULT_TOKEN="${FIX_TOKEN}" vault write -format=json kubernetes/creds/checkout-restart-role kubernetes_namespace=prod-checkout)
K8S_TOKEN=$(echo "${K8S_CREDS}" | jq -r '.data.service_account_token')
K8S_TTL=$(echo "${K8S_CREDS}" | jq -r '.lease_duration')
K8S_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' --context "${CLUSTER_NAME}")
EPHEMERAL_KUBECONFIG=$("${SCRIPT_DIR}/../../scripts/lib/ephemeral-kubeconfig.sh" "${K8S_TOKEN}" "${K8S_SERVER}")
kubectl --kubeconfig="${EPHEMERAL_KUBECONFIG}" \
  -n prod-checkout rollout restart deployment/checkout-service
rm -f "${EPHEMERAL_KUBECONFIG}"
# Same capping as the DB credential above -- role default is 10m, actual
# issued TTL is min(that, delegation JWT's remaining validity).
echo "(token expires in ${K8S_TTL}s, RBAC-limited to get/list/patch on checkout-service only)"

echo
echo "Diagnose + fix ran on task-scoped, short-lived, single-use grants. The" \
     "ceiling held even against a request the human approver's own policy permits."
