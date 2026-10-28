#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

[ -f /tmp/vault-session.env ] && source /tmp/vault-session.env
if [ -f "${REPO_ROOT}/.env" ]; then
  source "${REPO_ROOT}/.env"
  export ORDERS_DB_ADMIN_PASSWORD
fi
export CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
export MOCK_IDP_ISSUER="${MOCK_IDP_ISSUER:-https://test-tenant.verify.ibm.com/oidc/endpoint/default}"
export ONCALL_ENGINEER_SUBJECT="${ONCALL_ENGINEER_SUBJECT:-oncall-engineer-test-subject}"
export SRE_AGENT_SUBJECT="${SRE_AGENT_SUBJECT:-sre-incident-agent-test-subject}"

: "${VAULT_ADDR:?set VAULT_ADDR, or confirm /tmp/vault-session.env exists on this machine}"
: "${VAULT_TOKEN:?set VAULT_TOKEN, or confirm /tmp/vault-session.env exists on this machine}"
: "${ORDERS_DB_ADMIN_PASSWORD:?set to the orders-db admin password, or confirm .env exists at the repo root}"

pause() {
  if [ -t 0 ]; then
    read -r -p "" _ || true
  fi
}

"${SCRIPT_DIR}/../scripts/trigger-incident.sh"
eval "$("${SCRIPT_DIR}/../scripts/create-insecure-demo-credentials.sh" | grep '^export')"
"${SCRIPT_DIR}/insecure-agent.sh"
pause

"${SCRIPT_DIR}/../scripts/trigger-incident.sh"
"${SCRIPT_DIR}/secure-agent.sh"
