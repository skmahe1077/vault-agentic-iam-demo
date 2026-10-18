#!/usr/bin/env bash
# Registers IBM Verify as the OAuth resource server Vault trusts for OBO
# token exchange. Requires an IBM Verify tenant + an app registration that
# issues JWTs carrying the RFC 8693 `act.sub` actor claim and RFC 9396
# `authorization_details` (RAR) — see docs/TALK-NOTES.md for the console
# steps, since those are tenant-admin-console-driven, not CLI-driven.
set -euo pipefail

: "${IBM_VERIFY_ISSUER:?set to the IBM Verify tenant issuer URL}"
: "${IBM_VERIFY_JWKS_URI:?set to the IBM Verify tenant JWKS endpoint}"

cat > /tmp/verify-oauth.json <<EOF
{
  "issuer_id":            "${IBM_VERIFY_ISSUER}",
  "use_jwks":             true,
  "user_claim":           "sub",
  "supported_algorithms": ["RS256"],
  "jwks_uri":             "${IBM_VERIFY_JWKS_URI}"
}
EOF

vault write sys/config/oauth-resource-server/verify @/tmp/verify-oauth.json
rm -f /tmp/verify-oauth.json

echo "IBM Verify registered as OAuth resource server 'verify'."
