#!/usr/bin/env bash
# Points kubectl at the EKS cluster created by terraform/ and applies the
# demo's K8s manifests. The cluster itself is provisioned by Terraform
# (terraform apply in terraform/), not this script -- this just wires up
# kubectl access and applies manifests, same role bootstrap-kind.sh used to
# play for the local kind cluster it replaced.
#
# Also applies orders-db-proxy.yaml (a socat forwarder to the RDS instance
# -- orders-db is private, see terraform/rds.tf) and
# vault-k8s-secrets-engine-rbac.yaml (Vault's own standing RBAC for the
# kubernetes secrets engine, previously a manual step in DEMO-SCRIPT.md),
# then starts a background port-forward so local `psql` (via
# scripts/lib/orders-psql.sh) can reach it at 127.0.0.1:5433 -- the same
# port docker-compose used to publish.
#
# Prereqs: aws CLI (authenticated), kubectl on PATH, terraform apply already run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
AWS_REGION="${AWS_REGION:?set to the region the EKS cluster was created in, e.g. us-west-2}"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}"
kubectl config use-context "${CLUSTER_NAME}"

kubectl apply -f "${SCRIPT_DIR}/../k8s_manifests/checkout-service.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s_manifests/checkout-restart-role.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s_manifests/billing-restart-role.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s_manifests/vault-k8s-secrets-engine-rbac.yaml"

ORDERS_DB_ADDRESS="$(terraform -chdir="${TERRAFORM_DIR}" output -raw orders_db_address)"
sed "s/ORDERS_DB_HOST_PLACEHOLDER/${ORDERS_DB_ADDRESS}/" \
  "${SCRIPT_DIR}/../k8s_manifests/orders-db-proxy.yaml" | kubectl apply -f -

echo "Waiting for checkout-service to become ready..."
kubectl -n prod-checkout rollout status deployment/checkout-service --timeout=180s

echo "Waiting for orders-db-proxy to become ready..."
kubectl -n default rollout status deployment/orders-db-proxy --timeout=60s

echo "Starting background port-forward: 127.0.0.1:5433 -> orders-db-proxy -> RDS"
pkill -f "port-forward.*orders-db-proxy" 2>/dev/null || true
kubectl -n default port-forward svc/orders-db-proxy 5433:5432 >/tmp/orders-db-proxy-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!
sleep 2

echo "EKS cluster '${CLUSTER_NAME}' ready. Context: ${CLUSTER_NAME}"
echo "orders-db reachable locally at 127.0.0.1:5433 (port-forward PID ${PORT_FORWARD_PID}, log /tmp/orders-db-proxy-port-forward.log)"
