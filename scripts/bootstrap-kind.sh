#!/usr/bin/env bash
# Stands up (or reuses) the local kind cluster used for the incident-response demo.
# Prereqs: docker, kind, kubectl on PATH.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists, skipping create."
else
  kind create cluster --name "${CLUSTER_NAME}" --wait 90s
fi

kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl apply -f "$(dirname "$0")/../k8s_manifests/checkout-service.yaml"
kubectl apply -f "$(dirname "$0")/../k8s_manifests/checkout-restart-role.yaml"
kubectl apply -f "$(dirname "$0")/../k8s_manifests/billing-restart-role.yaml"

echo "Waiting for checkout-service to become ready..."
kubectl -n prod-checkout rollout status deployment/checkout-service --timeout=90s

echo "kind cluster '${CLUSTER_NAME}' ready. Context: kind-${CLUSTER_NAME}"
