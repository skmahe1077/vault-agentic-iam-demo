#!/usr/bin/env bash
# Mints the standing, broad credential beat 1 (agent/insecure/run.sh) uses
# to dramatize the anti-pattern: a cluster-admin ServiceAccount token with
# no expiry tied to it, no task scope, no link to Vault at all. Run once
# per rehearsal, export the two values it prints, then run
# agent/insecure/run.sh.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"

kubectl --context "kind-${CLUSTER_NAME}" create serviceaccount sre-incident-agent-insecure -n default \
  --dry-run=client -o yaml | kubectl --context "kind-${CLUSTER_NAME}" apply -f -

kubectl --context "kind-${CLUSTER_NAME}" create clusterrolebinding sre-incident-agent-insecure-admin \
  --clusterrole=cluster-admin --serviceaccount=default:sre-incident-agent-insecure \
  --dry-run=client -o yaml | kubectl --context "kind-${CLUSTER_NAME}" apply -f -

STATIC_K8S_TOKEN=$(kubectl --context "kind-${CLUSTER_NAME}" -n default create token sre-incident-agent-insecure --duration=24h)

echo
echo "export STATIC_K8S_TOKEN=\"${STATIC_K8S_TOKEN}\""
echo "export STATIC_ORDERS_DB_PASSWORD=\"\${ORDERS_DB_ADMIN_PASSWORD:-changeme-local-only}\"  # from .env"
