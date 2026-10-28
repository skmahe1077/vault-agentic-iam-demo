#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/pause.sh"

[ -f /tmp/vault-session.env ] && source /tmp/vault-session.env

: "${VAULT_ADDR:?set VAULT_ADDR, or confirm /tmp/vault-session.env exists on this machine}"
: "${VAULT_TOKEN:?set VAULT_TOKEN, or confirm /tmp/vault-session.env exists on this machine}"

AGENT_ENTITY_ID=$(vault read -field=id identity/entity/name/sre-incident-agent)

echo
echo "\$ vault read agent-registry/registration/entity-id/${AGENT_ENTITY_ID}"
vault read agent-registry/registration/entity-id/"${AGENT_ENTITY_ID}"
pause

echo
echo "\$ vault read agent-registry/registration/display-name/sre-incident-agent-insecure"
vault read agent-registry/registration/display-name/sre-incident-agent-insecure || true
