#!/usr/bin/env bash
# Performs one RFC 8693 token-exchange request against IBM Verify, carrying
# an RFC 9396 `authorization_details` (RAR) claim scoped to exactly one
# Vault path + capability. Each call mints a fresh delegation token --
# these are short-lived (~30s) and single-use, so a new one is requested
# per Vault action, never reused.
#
# NOTE: the field names below follow the standard RFC 8693 token-exchange
# grant. Verify them against your IBM Verify tenant's actual token endpoint
# behavior before relying on this for a live demo -- the fetched setup docs
# confirmed the required claims conceptually (subject token, actor token,
# authorization_details) but only gave a fully worked curl example for
# Auth0's PAR+PKCE flow, not IBM Verify's token endpoint specifically.
set -euo pipefail

: "${RAR_PATH:?Vault path this delegation token should be scoped to, e.g. database/creds/readonly-orders}"
: "${RAR_CAPABILITY:?e.g. read}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Dual-mode: set MOCK_IDP_ISSUER to rehearse with scripts/dev/mint_rar_jwt.py
# (proven working end-to-end against this repo's Vault, no real tenant
# needed -- see docs/TALK-NOTES.md). Leave it unset once IBM Verify is
# validated to use the real token-exchange call below instead. Either way
# agent/secure/run.sh itself never changes.
if [ -n "${MOCK_IDP_ISSUER:-}" ]; then
  : "${ONCALL_ENGINEER_SUBJECT:?the on-call engineer's mock-IdP sub, matching vault-config/03}"
  : "${SRE_AGENT_SUBJECT:?sre-incident-agent's mock-IdP sub, matching vault-config/03}"
  python3 "${SCRIPT_DIR}/../../scripts/dev/mint_rar_jwt.py" \
    "${MOCK_IDP_ISSUER}" "${ONCALL_ENGINEER_SUBJECT}" "${SRE_AGENT_SUBJECT}" \
    "${RAR_PATH}" "${RAR_CAPABILITY}"
  exit 0
fi

: "${IBM_VERIFY_TOKEN_ENDPOINT:?e.g. https://<tenant>.verify.ibm.com/oauth2/token}"
: "${ONCALL_SUBJECT_TOKEN:?the on-call engineer IBM Verify access token (the human being delegated for)}"
: "${SRE_AGENT_ACTOR_TOKEN:?sre-incident-agent own IBM Verify access token (the actor doing the acting)}"

# NOTE: the field names below follow the standard RFC 8693 token-exchange
# grant. Verify them against your IBM Verify tenant's actual token endpoint
# behavior before relying on this for the live talk -- the fetched setup
# docs confirmed the required claims conceptually (subject token, actor
# token, authorization_details) but only gave a fully worked curl example
# for Auth0's PAR+PKCE flow, not IBM Verify's token endpoint specifically.
AUTHORIZATION_DETAILS=$(cat <<EOF
[{"type": "vault:path_access", "path": "${RAR_PATH}", "capabilities": ["${RAR_CAPABILITY}"]}]
EOF
)

curl -s -X POST "${IBM_VERIFY_TOKEN_ENDPOINT}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=${ONCALL_SUBJECT_TOKEN}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "actor_token=${SRE_AGENT_ACTOR_TOKEN}" \
  -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "authorization_details=${AUTHORIZATION_DETAILS}" \
  | jq -r '.access_token'
