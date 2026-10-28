#!/usr/bin/env bash
# Run this before walking on stage. Checks everything that's been seen to
# drop silently between rehearsals (the orders-db-proxy port-forward, the
# mock-IdP JWKS tunnel) and fixes those two automatically since they're
# local-only and safe to restart. Everything else is reported with the
# exact command to fix it -- this script never touches Vault policy/data
# or cluster workload state, only local plumbing.
#
# Usage: source the same env vars agent/live-demo.sh needs, then run this.
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
JWKS_PORT="${JWKS_PORT:-8787}"
PASS=0
FAIL=0

ok()    { echo "[OK]    $1"; PASS=$((PASS+1)); }
fixed() { echo "[FIXED] $1"; PASS=$((PASS+1)); }
bad()   { echo "[FAIL]  $1"; FAIL=$((FAIL+1)); }

echo "=== env vars ==="
for v in VAULT_ADDR VAULT_NAMESPACE VAULT_TOKEN CLUSTER_NAME ORDERS_DB_ADMIN_PASSWORD \
         MOCK_IDP_ISSUER ONCALL_ENGINEER_SUBJECT SRE_AGENT_SUBJECT; do
  if [ -n "${!v:-}" ]; then
    ok "${v} set"
  else
    bad "${v} not set -- see docs/DEMO-SCRIPT.md \"export once per terminal session\""
  fi
done

echo
echo "=== vault ==="
if VAULT_STATUS=$(vault status -format=json 2>/dev/null); then
  SEALED=$(echo "${VAULT_STATUS}" | jq -r '.sealed')
  if [ "${SEALED}" = "false" ]; then
    ok "vault reachable, unsealed ($(echo "${VAULT_STATUS}" | jq -r '.version'))"
  else
    bad "vault reachable but SEALED"
  fi
else
  bad "vault unreachable -- check VAULT_ADDR/VAULT_TOKEN"
fi

if AGENT_ID=$(vault read -field=id identity/entity/name/sre-incident-agent 2>/dev/null) && [ -n "${AGENT_ID}" ]; then
  if vault read -field=id "agent-registry/registration/entity-id/${AGENT_ID}" >/dev/null 2>&1; then
    ok "sre-incident-agent registered in Agent Registry"
  else
    bad "sre-incident-agent entity exists but has no Agent Registry registration -- rerun vault-config/03-register-identities-and-agent.sh"
  fi
else
  bad "sre-incident-agent entity not found -- rerun vault-config/03-register-identities-and-agent.sh"
fi

CURRENT_JWKS_URI=$(vault read -field=jwks_uri sys/config/oauth-resource-server/verify 2>/dev/null || true)

echo
echo "=== kubernetes ==="
if kubectl --context "${CLUSTER_NAME}" -n prod-checkout get deployment checkout-service >/dev/null 2>&1; then
  READY=$(kubectl --context "${CLUSTER_NAME}" -n prod-checkout get deployment checkout-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  DESIRED=$(kubectl --context "${CLUSTER_NAME}" -n prod-checkout get deployment checkout-service -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  if [ "${READY:-0}" = "${DESIRED:-0}" ] && [ "${DESIRED:-0}" != "0" ]; then
    ok "checkout-service ${READY}/${DESIRED} ready"
  else
    bad "checkout-service ${READY:-0}/${DESIRED:-0} ready -- run ./scripts/reset.sh before demoing"
  fi
else
  bad "can't reach checkout-service deployment -- check kubectl context '${CLUSTER_NAME}'"
fi

echo
echo "=== orders-db-proxy port-forward (127.0.0.1:5433) ==="
if lsof -i :5433 >/dev/null 2>&1; then
  ok "port-forward already listening"
else
  kubectl --context "${CLUSTER_NAME}" -n default port-forward svc/orders-db-proxy 5433:5432 \
    >/tmp/orders-db-proxy-port-forward.log 2>&1 &
  sleep 2
  if lsof -i :5433 >/dev/null 2>&1; then
    fixed "port-forward was down, restarted it (PID $!)"
  else
    bad "port-forward failed to start -- check /tmp/orders-db-proxy-port-forward.log"
  fi
fi

if [ -n "${ORDERS_DB_ADMIN_PASSWORD:-}" ]; then
  if "$(dirname "$0")/lib/orders-psql.sh" orders_admin "${ORDERS_DB_ADMIN_PASSWORD}" -c "SELECT 1;" >/dev/null 2>&1; then
    ok "psql round-trip to orders-db succeeds"
  else
    bad "psql round-trip to orders-db failed -- proxy pod or RDS instance may be down"
  fi
fi

echo
echo "=== mock-IdP JWKS tunnel ==="
TUNNEL_URL=""
if pgrep -f "cloudflared tunnel --url http://localhost:${JWKS_PORT}" >/dev/null 2>&1; then
  TUNNEL_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | tail -1)
fi

if [ -n "${TUNNEL_URL}" ] && [ -n "${CURRENT_JWKS_URI}" ] && [[ "${CURRENT_JWKS_URI}" == "${TUNNEL_URL}"* ]]; then
  ok "tunnel alive and matches Vault's configured jwks_uri (${TUNNEL_URL})"
elif [ -n "${MOCK_IDP_ISSUER:-}" ]; then
  pkill -f "cloudflared tunnel --url http://localhost:${JWKS_PORT}" 2>/dev/null || true
  cloudflared tunnel --url "http://localhost:${JWKS_PORT}" >/tmp/cloudflared.log 2>&1 &
  sleep 8
  TUNNEL_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | tail -1)
  if [ -n "${TUNNEL_URL}" ]; then
    MOCK_ISSUER="${MOCK_IDP_ISSUER}" JWKS_PUBLIC_URL="${TUNNEL_URL}" "$(dirname "$0")/dev/configure_mock_idp.sh" >/dev/null 2>&1
    fixed "tunnel was down/stale, restarted it and reconfigured Vault (${TUNNEL_URL})"
  else
    bad "cloudflared failed to produce a tunnel URL -- check /tmp/cloudflared.log"
  fi
else
  bad "tunnel down and MOCK_IDP_ISSUER not set, can't auto-reconfigure"
fi

echo
echo "============================================================"
if [ "${FAIL}" -eq 0 ]; then
  echo "ALL CLEAR: ${PASS} checks passed. Go run ./agent/live-demo.sh"
else
  echo "${FAIL} check(s) failed, ${PASS} passed -- fix those before walking on stage"
fi
echo "============================================================"

exit "${FAIL}"
