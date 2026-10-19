#!/usr/bin/env bash
# Demonstrates real OBO (delegated authorization) against the actual IBM
# Verify tenant -- distinct from the RAR/ceiling-scoping demo, which uses
# the mock IdP instead (see docs/TALK-NOTES.md "IBM Verify real-tenant
# integration" for why: authorization_details isn't supported end-to-end
# by this tenant/HashiCorp's own doc gap, confirmed 2026-10-19).
#
# This proves the OTHER half for real: act.sub delegation, real entity
# resolution, real ceiling-intersected policy grant, all against the
# genuine devopstronaut.verify.ibm.com tenant. Requires the "verify-real"
# oauth-resource-server profile and the *-real entity-aliases to already
# be configured (see docs/TALK-NOTES.md for the one-time setup commands).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.ibmverify.local"
: "${ENV_FILE:?}"
if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE} -- fill in real IBM Verify credentials first."
  exit 1
fi
set -a
source "${ENV_FILE}"
set +a

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

echo "=== minting agent actor token (client_credentials) ==="
SRE_AGENT_ACTOR_TOKEN=$(curl -s -X POST "${IBM_VERIFY_TOKEN_ENDPOINT}" \
  -d "grant_type=client_credentials" \
  -d "client_id=${IBM_VERIFY_CLIENT_ID}" \
  -d "client_secret=${IBM_VERIFY_CLIENT_SECRET}" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "=== minting human subject token (ROPC) ==="
ONCALL_SUBJECT_TOKEN=$(curl -s -X POST "${IBM_VERIFY_TOKEN_ENDPOINT}" \
  -d "grant_type=password" \
  -d "username=${IBM_VERIFY_HUMAN_USERNAME}" \
  -d "password=${IBM_VERIFY_HUMAN_PASSWORD}" \
  -d "client_id=${IBM_VERIFY_HUMAN_CLIENT_ID}" \
  -d "client_secret=${IBM_VERIFY_HUMAN_CLIENT_SECRET}" \
  -d "scope=openid" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "=== real RFC 8693 token-exchange: subject=human, actor=agent ==="
EXCHANGE_TOKEN=$(curl -s -X POST "${IBM_VERIFY_TOKEN_ENDPOINT}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=${ONCALL_SUBJECT_TOKEN}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "actor_token=${SRE_AGENT_ACTOR_TOKEN}" \
  -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "client_id=${IBM_VERIFY_CLIENT_ID}" \
  -d "client_secret=${IBM_VERIFY_CLIENT_SECRET}" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "=== presenting the real delegation token to Vault (no RAR -- ceiling ∩ human policy only) ==="
VAULT_TOKEN="${EXCHANGE_TOKEN}" vault read database/creds/readonly-orders
