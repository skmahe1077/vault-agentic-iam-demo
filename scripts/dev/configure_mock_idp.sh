#!/usr/bin/env bash
# Serves the JWKS mint_rar_jwt.py produces and points Vault's
# oauth-resource-server config at it, so beats 3-5 can be rehearsed with
# OBO+RAR for real -- no IBM Verify tenant required. Run once per session;
# mint_rar_jwt.py can be called repeatedly after.
#
# Not a substitute for validating against the real tenant before the talk
# (IBM Verify's token endpoint behavior is still unconfirmed) -- this only
# proves Vault's side of OBO+RAR, which is the side this repo controls.
set -euo pipefail

MOCK_ISSUER="${MOCK_ISSUER:?set to the same issuer string used as IBM_VERIFY_ISSUER in vault-config/03}"
JWKS_PORT="${JWKS_PORT:-8787}"
# host.docker.internal only resolves from inside a container on the same
# Docker host as this server -- true for the old local dev-mode Vault, not
# for HCP Vault Dedicated (a remote cluster with no path to your laptop's
# loopback). Against HCP, set JWKS_PUBLIC_URL to a tunnel pointed at this
# port (e.g. `cloudflared tunnel --url http://localhost:${JWKS_PORT}`,
# no account needed) and this script uses that instead.
JWKS_BASE_URL="${JWKS_PUBLIC_URL:-http://host.docker.internal:${JWKS_PORT}}"

python3 "$(dirname "$0")/mint_rar_jwt.py" "${MOCK_ISSUER}" bootstrap bootstrap database/creds/readonly-orders read >/dev/null

if ! lsof -i ":${JWKS_PORT}" >/dev/null 2>&1; then
  (cd /tmp && nohup python3 -m http.server "${JWKS_PORT}" --bind 127.0.0.1 --directory /tmp \
    > /tmp/mock_idp_jwks_server.log 2>&1 &)
  sleep 1
fi

vault write sys/config/oauth-resource-server/verify \
  issuer_id="${MOCK_ISSUER}" \
  use_jwks=true \
  user_claim=sub \
  supported_algorithms="RS256" \
  jwks_uri="${JWKS_BASE_URL}/mock_idp_jwks.json"

echo "Mock IdP JWKS serving on :${JWKS_PORT} (${JWKS_BASE_URL}), Vault pointed at it for issuer ${MOCK_ISSUER}."
echo "Mint a delegation JWT with:"
echo "  python3 $(dirname "$0")/mint_rar_jwt.py \"${MOCK_ISSUER}\" <human-sub> <agent-sub> <vault-path> <capability> [--ttl seconds]"
