#!/usr/bin/env bash
# The single TLK-2725 demo -- one script, one continuous story, matching the
# talk abstract exactly rather than a numbered list of "beats":
#
#   the gap:  traditional IAM assumes a predictable human, not an autonomous
#             agent that requests access, uses tools, and acts for someone else
#   1. a distinct, governed identity          -- Agent Registry
#   2. delegated authorization                -- OBO, acting on the human's behalf
#   3. ceiling policies cap blast radius       -- holds even when the human's own
#                                                  policy would allow more
#   4. ephemeral per-request authorization     -- RAR-scoped, expires after use,
#                                                  the agent actually does the fix
#
# No standing-credential anti-pattern here by design -- this demo shows only
# the solution, end to end. (agent/insecure/run.sh still exists separately if
# that contrast is ever wanted for a different cut of the talk.)
#
# Prereqs: everything in "Before you go on stage" in docs/DEMO-SCRIPT.md has
# already run -- secrets engines configured, mock IdP (or real IBM Verify)
# configured, identities registered. This script is the on-stage part only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Self-sufficient from any fresh terminal on this machine: pulls in the
# Vault session (VAULT_ADDR/VAULT_NAMESPACE/VAULT_TOKEN, written once by
# terraform apply) and .env (ORDERS_DB_ADMIN_PASSWORD) if present, so you
# don't have to re-export them by hand every time. Falls through to the
# precondition checks below if either file is missing -- e.g. a different
# machine that was never set up, or /tmp/vault-session.env got cleared.
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

banner "THE GAP"
cat <<'EOF'
AI agents are entering infrastructure pipelines, but traditional IAM was
built for predictable users and workflows -- not autonomous actors that
request access, use tools, and act on behalf of humans.
EOF
pause

banner "SCENE: checkout-service is degrading"
"${SCRIPT_DIR}/../scripts/trigger-incident.sh"
pause

banner "1. A DISTINCT, GOVERNED IDENTITY -- Agent Registry"
AGENT_ENTITY_ID=$(vault read -field=id identity/entity/name/sre-incident-agent)
vault read agent-registry/registration/entity-id/"${AGENT_ENTITY_ID}"
echo
vault policy read ceiling-sre-incident-agent
pause

banner "2, 3, 4. DELEGATED AUTHORIZATION, CEILING, EPHEMERAL GRANT"
"${SCRIPT_DIR}/secure/run.sh"

banner "THE OUTCOME"
cat <<'EOF'
Every grant above was scoped to one task, delegated on behalf of a specific
human, and already expiring or expired. Controlled, traceable, and auditable
-- by construction, not by policy you hope holds.
EOF
