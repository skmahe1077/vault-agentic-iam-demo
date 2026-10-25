#!/usr/bin/env bash
# Points kubectl at the EKS cluster created by terraform/ and applies the
# demo's K8s manifests. The cluster itself is provisioned by Terraform
# (terraform apply in terraform/), not this script -- this just wires up
# kubectl access and applies manifests, same role bootstrap-kind.sh used to
# play for the local kind cluster it replaced.
# Prereqs: aws CLI (authenticated), kubectl on PATH, terraform apply already run.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-vault-agentic-iam}"
AWS_REGION="${AWS_REGION:?set to the region the EKS cluster was created in, e.g. us-east-1}"

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}"
kubectl config use-context "${CLUSTER_NAME}"

kubectl apply -f "$(dirname "$0")/../k8s_manifests/checkout-service.yaml"
kubectl apply -f "$(dirname "$0")/../k8s_manifests/checkout-restart-role.yaml"
kubectl apply -f "$(dirname "$0")/../k8s_manifests/billing-restart-role.yaml"

echo "Waiting for checkout-service to become ready..."
kubectl -n prod-checkout rollout status deployment/checkout-service --timeout=180s

echo "EKS cluster '${CLUSTER_NAME}' ready. Context: ${CLUSTER_NAME}"
