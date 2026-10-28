#!/usr/bin/env bash
# The same incident, fixed twice -- once with a standing credential, once
# with Vault Agentic IAM -- so the difference is in the actual command
# output, not narration. agent/demo.sh is the solution-only cut for the
# talk abstract; this is the side-by-side version when you want the
# audience to see the anti-pattern fail before the fix holds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Self-sufficient from any fresh terminal on this machine -- same pattern
# as agent/demo.sh and scripts/preflight-check.sh.
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
    read -r -p "-- press enter -- " _ || true
  fi
}

banner() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

banner "THE ANTI-PATTERN: standing, unscoped access"
"${SCRIPT_DIR}/../scripts/trigger-incident.sh"
eval "$("${SCRIPT_DIR}/../scripts/create-insecure-demo-credentials.sh" | grep '^export')"
"${SCRIPT_DIR}/insecure/run.sh"
pause

banner "THE FIX: delegated, ceiling-capped, ephemeral authorization"
"${SCRIPT_DIR}/../scripts/trigger-incident.sh"
"${SCRIPT_DIR}/secure/run.sh"
