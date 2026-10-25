#!/usr/bin/env bash
# Enables and configures the two secrets engines the incident-response
# agent draws ephemeral grants from. Run against HCP Vault Dedicated
# (export VAULT_ADDR/VAULT_NAMESPACE, then `vault login`). HCP Vault
# Dedicated must have network reachability to K8S_HOST below -- see
# "Running against HCP Vault Dedicated" in README.md.
set -euo pipefail

: "${ORDERS_DB_ADMIN_PASSWORD:?set to the orders-db admin password}"
: "${K8S_HOST:?set to the EKS cluster's API server address (terraform -chdir=terraform output -raw cluster_endpoint) -- see docs/TALK-NOTES.md}"
: "${K8S_CA_CERT:?path to the EKS cluster CA cert}"
: "${K8S_REVIEWER_JWT:?path to a Vault-dedicated ServiceAccount token with the TokenRequest permissions documented in docs/TALK-NOTES.md}"

echo "--- database secrets engine ---"
vault secrets enable -path=database database 2>/dev/null || echo "already enabled"

vault write database/config/orders-db \
    plugin_name=postgresql-database-plugin \
    allowed_roles="readonly-orders" \
    connection_url="postgresql://{{username}}:{{password}}@orders-db:5432/orders?sslmode=disable" \
    username="orders_admin" \
    password="${ORDERS_DB_ADMIN_PASSWORD}"

vault write database/roles/readonly-orders \
    db_name=orders-db \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON orders TO \"{{name}}\";" \
    default_ttl="3m" \
    max_ttl="10m"

echo "--- kubernetes secrets engine ---"
vault secrets enable -path=kubernetes kubernetes 2>/dev/null || echo "already enabled"

# Split into two writes: passing kubernetes_ca_cert=@file and
# service_account_jwt=@file together in one `vault write` reproducibly
# kills the connection with a bare "EOF" (confirmed against Vault 2.2.0+ent
# -- looks like a CLI/plugin bug combining two @file args on this
# endpoint). Fields not included in a write are preserved from the prior
# write, so this two-step sequence ends up equivalent to one.
vault write kubernetes/config \
    kubernetes_host="${K8S_HOST}" \
    kubernetes_ca_cert=@"${K8S_CA_CERT}"

vault write kubernetes/config \
    kubernetes_host="${K8S_HOST}" \
    service_account_jwt=@"${K8S_REVIEWER_JWT}" \
    disable_local_ca_jwt=true

# token_default_ttl can't go below 10m: the K8s API server's own
# TokenRequest floor rejects expirationSeconds < 600 regardless of what
# Vault asks for. name_template must produce a lowercase RFC 1123 name --
# `random 8` alone can emit uppercase, which K8s then rejects as an invalid
# ServiceAccount/RoleBinding name.
vault write kubernetes/roles/checkout-restart-role \
    allowed_kubernetes_namespaces="prod-checkout" \
    kubernetes_role_type="Role" \
    kubernetes_role_name="checkout-restart-role" \
    name_template="agent-checkout-restart-{{ random 8 | lowercase }}" \
    token_default_ttl="10m" \
    token_max_ttl="15m"

# Exists only as the target of the beat-4 ceiling-overreach demo (see
# vault-config/ceiling-policy.hcl) -- sre-incident-agent's ceiling never
# grants this path.
vault write kubernetes/roles/billing-restart-role \
    allowed_kubernetes_namespaces="prod-billing" \
    kubernetes_role_type="Role" \
    kubernetes_role_name="billing-restart-role" \
    name_template="agent-billing-restart-{{ random 8 | lowercase }}" \
    token_default_ttl="10m" \
    token_max_ttl="15m"

echo "Secrets engines configured: database/creds/readonly-orders, kubernetes/creds/checkout-restart-role, kubernetes/creds/billing-restart-role"
