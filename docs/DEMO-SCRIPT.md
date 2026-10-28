# Demo script — TLK-2725

A presenter run-of-show: what to type, in what order, and what to say. Rehearsed end-to-end
on 2026-10-18 using the mock IdP (`MOCK_IDP_ISSUER` mode) standing in for IBM Verify. Re-
rehearsed end-to-end against **real** AWS + HCP infrastructure (EKS, RDS, HCP Vault Dedicated
v2.1.2, HVN peering) on 2026-10-27 — run well over a dozen times that night without a single
failure. Every command below is copy-pasteable as written.

## Setup steps (run once, not part of the demo itself)

This demo targets **HCP Vault Dedicated** exclusively -- no local Vault container, no Vault
Enterprise license. `terraform/` provisions the Vault cluster itself, a real **EKS** cluster,
and `orders-db` on **RDS**. HCP Vault Dedicated reaches EKS's public endpoint directly over
the internet (IAM+RBAC authenticated -- there's no static egress-IP list to lock it down to)
and reaches RDS privately over an HVN peering connection -- see "Running against HCP Vault
Dedicated" in README.md for why those two paths differ.

```bash
cp .env.example .env            # fill in ORDERS_DB_ADMIN_PASSWORD
export TF_VAR_orders_db_admin_password="$(grep ORDERS_DB_ADMIN_PASSWORD .env | cut -d= -f2)"

cd terraform
terraform init
cat > terraform.tfvars <<EOF
presenter_ip_cidr = "$(curl -s https://checkip.amazonaws.com)/32"
hcp_project_id    = "<your HCP project ID -- \`hcp profile display\`>"
EOF
terraform apply
cd ..

export AWS_REGION=us-west-2     # match terraform/variables.tf aws_region / the HVN's region
./scripts/bootstrap-eks.sh      # applies manifests incl. vault-k8s-secrets-engine-rbac.yaml,
                                 # starts the orders-db port-forward on 127.0.0.1:5433
./scripts/load-orders-schema.sh

export VAULT_ADDR="$(terraform -chdir=terraform output -raw vault_public_endpoint_url)"
export VAULT_NAMESPACE=admin
# terraform apply also created an admin token for this cluster (hcp_vault_cluster_admin_token
# in terraform/hcp.tf) -- simplest path in, no separate auth method to configure:
export VAULT_TOKEN="$(terraform -chdir=terraform output -raw vault_admin_token)"
vault login -no-print "${VAULT_TOKEN}"
```

```bash
mkdir -p /tmp/vault-k8s-config
# --minify, not a name match on "vault-agentic-iam" -- `--alias` names the
# *context*, but the cluster entry it points to keeps its full ARN name
# (arn:aws:eks:<region>:<account>:cluster/vault-agentic-iam), so a jsonpath
# match on the alias finds nothing and silently writes an empty ca.pem.
kubectl --context vault-agentic-iam config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/vault-k8s-config/ca.pem
kubectl --context vault-agentic-iam -n vault create token vault --duration=87600h \
  > /tmp/vault-k8s-config/reviewer.jwt

ORDERS_DB_ADMIN_PASSWORD=changeme-local-only \
ORDERS_DB_HOST="$(terraform -chdir=terraform output -raw orders_db_address)" \
K8S_HOST="$(terraform -chdir=terraform output -raw cluster_endpoint)" \
K8S_CA_CERT=/tmp/vault-k8s-config/ca.pem \
K8S_REVIEWER_JWT=/tmp/vault-k8s-config/reviewer.jwt \
  ./vault-config/01-enable-secrets-engines.sh

# Mock-IdP mode -- swap for the real IBM_VERIFY_* values if a real tenant is available.
# The mock IdP serves its JWKS from localhost:8787, but HCP Vault Dedicated is a
# remote cluster -- it can't reach your laptop's loopback. Tunnel the port first
# (no account needed) and pass the tunnel URL in as JWKS_PUBLIC_URL:
cloudflared tunnel --url http://localhost:8787 > /tmp/cloudflared.log 2>&1 &
sleep 8
JWKS_PUBLIC_URL="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log | head -1)"
echo "JWKS tunnel: ${JWKS_PUBLIC_URL}"

export MOCK_IDP_ISSUER="https://test-tenant.verify.ibm.com/oidc/endpoint/default"
MOCK_ISSUER="${MOCK_IDP_ISSUER}" JWKS_PUBLIC_URL="${JWKS_PUBLIC_URL}" ./scripts/dev/configure_mock_idp.sh

export ONCALL_ENGINEER_SUBJECT="oncall-engineer-test-subject"
export SRE_AGENT_SUBJECT="sre-incident-agent-test-subject"
IBM_VERIFY_ISSUER="${MOCK_IDP_ISSUER}" \
  ./vault-config/03-register-identities-and-agent.sh

# Sanity check everything is live before running the demo:
vault status
vault secrets list
vault read agent-registry/registration/entity-id/"$(vault read -field=id identity/entity/name/sre-incident-agent)"
```

## Running the demo

Two scripts, both self-sufficient, both printing nothing but real commands and their real
output -- no narration, no banners. Say the talking points yourself, live, over the output;
the terminal only shows what actually happened.

`scripts/preflight-check.sh`, `agent/secure-demo.sh`, and `agent/insecure-demo.sh` each
source `/tmp/vault-session.env` (VAULT_ADDR/VAULT_NAMESPACE/VAULT_TOKEN, written once by
`terraform apply`) and `.env` (ORDERS_DB_ADMIN_PASSWORD) themselves, and default the
mock-IdP values if not already set. From any fresh terminal on this machine, just `cd` into
the repo and run them -- no manual export block needed. (A different machine that was never
set up won't have `/tmp/vault-session.env`; the scripts fail with a clear message telling
you what's missing, rather than silently misbehaving.)

Run the preflight check before the demo -- it verifies Vault, the Agent Registry entry,
checkout-service's pods, the orders-db-proxy port-forward, and the mock-IdP tunnel, and
auto-fixes the two that have been seen dropping silently between rehearsals (the
port-forward and the tunnel):

```bash
./scripts/preflight-check.sh
```
Wait for `ALL CLEAR` before continuing. If checkout-service isn't `2/2 ready`, run
`./scripts/reset.sh` first (pods take a few seconds to settle after any reset/restart --
re-check with `kubectl -n prod-checkout get pods` before moving on).

**`agent/secure-demo.sh`** -- the secure way, matching the abstract's claims in order:

```bash
./agent/secure-demo.sh
```

1. Fires the incident (`scripts/trigger-incident.sh`): a connection leak against the orders
   database, then a broken readiness probe on checkout-service.
2. `vault read agent-registry/registration/entity-id/...` -- `sre-incident-agent`'s real
   Agent Registry entry. `vault policy read ceiling-sre-incident-agent` -- its ceiling.
3. Runs `agent/secure-agent.sh`:
   - `vault read database/creds/readonly-orders` -- a credential minted on the spot, used to
     diagnose via `psql`.
   - `vault write kubernetes/creds/billing-restart-role` -- denied, `403 permission denied`.
     The on-call engineer's own policy allows this; the ceiling doesn't.
   - `vault write kubernetes/creds/checkout-restart-role` -- succeeds, real `lease_duration`
     visible in the JSON response, used to restart checkout-service.

Pauses for enter between the three sections above (`pause()` in the script) so you can talk
over each one -- run non-interactively instead (e.g. for a recording) with
`./agent/secure-demo.sh < /dev/null`.

**`agent/insecure-demo.sh`** -- the same incident, the insecure way:

```bash
./agent/insecure-demo.sh
```

Fires the incident, then runs `agent/insecure-agent.sh`: opens with
`vault read agent-registry/registration/display-name/sre-incident-agent-insecure` --
fails, `agent with provided display_name does not exist`, because this identity was never
registered with Vault at all. Then a static DB password and a long-lived Kubernetes
ServiceAccount token fix checkout-service, and keep going -- reading `billing_accounts` and
restarting billing-service, neither of which was asked for.

Run both scripts back to back for direct contrast -- fire `agent/secure-demo.sh` right after
`agent/insecure-demo.sh` (or vice versa) and the difference shows up in the actual command
output, not narration.

## Reset between rehearsals

```bash
./scripts/reset.sh
```
Clears leaked DB connections and restores checkout-service's probes. Does not revoke
outstanding leases — do that separately if a fully clean state is needed (`vault lease revoke
-prefix database/` / `kubernetes/`).
