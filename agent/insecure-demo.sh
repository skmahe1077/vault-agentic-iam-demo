#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/pause.sh"

[ -f /tmp/vault-session.env ] && source /tmp/vault-session.env
if [ -f "${REPO_ROOT}/.env" ]; then
  source "${REPO_ROOT}/.env"
  export ORDERS_DB_ADMIN_PASSWORD
fi
export CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"

: "${VAULT_ADDR:?set VAULT_ADDR, or confirm /tmp/vault-session.env exists on this machine}"
: "${VAULT_TOKEN:?set VAULT_TOKEN, or confirm /tmp/vault-session.env exists on this machine}"
: "${ORDERS_DB_ADMIN_PASSWORD:?set to the orders-db admin password, or confirm .env exists at the repo root}"

"${SCRIPT_DIR}/../scripts/trigger-incident.sh"
eval "$("${SCRIPT_DIR}/../scripts/create-insecure-demo-credentials.sh" | grep '^export')"
"${SCRIPT_DIR}/insecure-agent.sh"
pause

"${SCRIPT_DIR}/../scripts/reset.sh"
