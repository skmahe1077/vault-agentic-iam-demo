#!/usr/bin/env bash
# Builds a standalone kubeconfig containing ONLY a bearer token -- no
# client-certificate/exec-plugin, no reference to the ambient admin context.
#
# `kubectl --token=X --server=Y` while a kubeconfig context with an
# embedded client-certificate or exec-based auth plugin is already current
# does NOT override auth the way the flags suggest: kubectl silently falls
# back to the context's own credentials (confirmed empirically -- even a
# garbage --token value "succeeded" because it was actually authenticating
# as the admin context's cert/IAM identity, not the token at all -- true of
# both kind's own admin context and `aws eks update-kubeconfig`'s default
# context). The agent must never have access to that admin context in the
# first place, so route every kubectl call in the agent scripts through a
# throwaway kubeconfig built here instead of flag overrides on top of the
# current context.
#
# Usage: KUBECONFIG_PATH=$(scripts/lib/ephemeral-kubeconfig.sh "$TOKEN" "$SERVER")
#        kubectl --kubeconfig="$KUBECONFIG_PATH" ...
set -euo pipefail

TOKEN="$1"
SERVER="$2"
TMPFILE="$(mktemp)"

kubectl --kubeconfig="${TMPFILE}" config set-cluster ephemeral \
  --server="${SERVER}" --insecure-skip-tls-verify=true >/dev/null
kubectl --kubeconfig="${TMPFILE}" config set-credentials ephemeral --token="${TOKEN}" >/dev/null
kubectl --kubeconfig="${TMPFILE}" config set-context ephemeral --cluster=ephemeral --user=ephemeral >/dev/null
kubectl --kubeconfig="${TMPFILE}" config use-context ephemeral >/dev/null

echo "${TMPFILE}"
