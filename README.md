# vault-agentic-iam

Demo repo for **TLK-2725** (IBM TechXchange) — *No Standing Access for AI Agents with
HashiCorp Vault Agentic IAM and Ephemeral Authorization*.

An autonomous SRE incident-response agent diagnoses and fixes a `checkout-service` incident
using Vault Enterprise's Agentic IAM: a distinct **Agent Registry** identity, **delegated
(on-behalf-of) authorization**, **ceiling policies** that cap blast radius regardless of what's
requested or approved, and **ephemeral per-request authorization** (RAR) that scopes every
grant to one task and expires it right after.

`agent/demo.sh` runs the whole thing as one continuous story, matching the talk abstract
exactly: identity → delegated authorization → ceiling caps blast radius → ephemeral grant does
the real fix, solution only. `agent/demo-contrast.sh` runs the same incident twice back to
back -- once with a standing credential (`agent/insecure/`), once with Vault Agentic IAM -- so
the difference shows up in the actual command output instead of narration.

## Quick start

Everything here is real AWS + HCP infrastructure (an EKS cluster, an RDS instance, and an HCP
Vault Dedicated cluster) — `terraform apply` creates billable resources; `terraform destroy`
when you're done.

```bash
cp .env.example .env    # fill in ORDERS_DB_ADMIN_PASSWORD
export TF_VAR_orders_db_admin_password="$(grep ORDERS_DB_ADMIN_PASSWORD .env | cut -d= -f2)"

cd terraform && terraform init
cat > terraform.tfvars <<EOF
presenter_ip_cidr = "$(curl -s https://checkip.amazonaws.com)/32"
hcp_project_id    = "<your HCP project ID -- \`hcp profile display\`>"
EOF
terraform apply   # creates EKS+VPC, RDS orders-db, and the HCP Vault Dedicated cluster
cd ..

export AWS_REGION=us-west-2   # match terraform/variables.tf aws_region / the HVN's region
./scripts/bootstrap-eks.sh     # applies k8s manifests, starts the orders-db port-forward
./scripts/load-orders-schema.sh

export VAULT_ADDR="$(terraform -chdir=terraform output -raw vault_public_endpoint_url)"
export VAULT_NAMESPACE=admin
vault login              # token/OIDC/userpass -- whatever your cluster's auth method is
```

Then follow **[docs/DEMO-SCRIPT.md](docs/DEMO-SCRIPT.md)** for the full presenter run-of-show
(setup + the single demo, exact commands). Before running the demo, run
`./scripts/preflight-check.sh` — it checks Vault, the Agent Registry entry, checkout-service's
pods, the orders-db-proxy port-forward, and the mock-IdP JWKS tunnel in one shot, and
auto-restarts the two that are known to drop silently between rehearsals (the port-forward and
the tunnel). **[docs/TALK-NOTES.md](docs/TALK-NOTES.md)** has the build notes, every bug
found/fixed along the way, and the mapping from the talk's abstract to the actual mechanism in
this repo.

## Running against HCP Vault Dedicated

This demo targets **HCP Vault Dedicated** (`terraform/hcp.tf` provisions the cluster itself;
Agent Registry needs Vault 2.1.2+, Standard/Essential tier) — there is no local Vault container
or Vault Enterprise license in this repo. `vault-config/*.sh` and `agent/secure/run.sh` just
read `VAULT_ADDR`/`VAULT_TOKEN`/`VAULT_NAMESPACE` from the environment.

Two different network paths reach the two AWS resources Vault depends on, because **HCP Vault
Dedicated publishes no static egress IP list** — there's nothing to put in a CIDR allowlist on
the AWS side:

- **EKS** (kubernetes secrets engine): public endpoint, open to `0.0.0.0/0`
  (`eks_public_access_cidrs` in terraform/variables.tf). HVN peering can't help here — the
  cluster's public hostname resolves to public IPs from outside the VPC regardless, so Vault's
  traffic takes the internet path either way. What actually protects the endpoint is IAM+RBAC
  auth on every request, the same as any public EKS cluster.
- **orders-db / RDS** (database secrets engine): private, `publicly_accessible = false`, reached
  over an **HVN peering connection** (`terraform/hcp.tf`) to the demo VPC. This one *can* be
  locked down, because Vault connects by private IP, not a public hostname.

`orders-db` is RDS, not a local docker-compose container, so there's a bridge for your local
`psql` to reach it too: `k8s_manifests/orders-db-proxy.yaml` runs a small TCP forwarder inside
the VPC, and `scripts/bootstrap-eks.sh` port-forwards it to `127.0.0.1:5433` — the same port
docker-compose used to publish. `scripts/lib/orders-psql.sh` is the one place every script talks
to it from.

**Audit trail**: `scripts/show-audit-trail.sh` tails a local `file` audit device,
which isn't how HCP Vault Dedicated exposes audit data — it streams audit logs to an external
sink instead (`hcp_vault_cluster`'s `audit_log_config` block supports this, not yet wired up
here). This is a known gap — see docs/TALK-NOTES.md.

## Prerequisites

- `kubectl`, the `vault` CLI, the `aws` CLI (authenticated), `terraform`, the `hcp` CLI
  (authenticated via `hcp auth login`), `jq`, `psql` (e.g. `brew install libpq`)
- An AWS account to provision EKS + RDS in (`terraform/`), and an existing **HCP HVN** in that
  same region for `terraform/hcp.tf` to peer with and create the Vault cluster in — this repo
  doesn't create the HVN itself
- No IBM Verify tenant needed — this demo runs entirely on **mock-IdP mode**
  (`scripts/dev/`), which proves the real Vault-side OBO+RAR mechanism without one; see
  DEMO-SCRIPT.md. The real-tenant RFC 8693 code path still exists in
  `agent/secure/request-delegation-token.sh` but isn't part of the documented run-of-show.

## Layout

| Path | What |
|---|---|
| `terraform/` | EKS cluster + VPC, RDS orders-db, HCP Vault Dedicated cluster + HVN peering |
| `sql/` | orders-db schema, loaded by `scripts/load-orders-schema.sh` |
| `k8s_manifests/` | checkout-service/billing-service + RBAC for the EKS cluster, orders-db-proxy |
| `vault-config/` | Secrets engines, policies, Agent Registry registration, IBM Verify config |
| `agent/demo.sh` | Solution-only demo -- identity, delegated auth, ceiling, ephemeral grant |
| `agent/demo-contrast.sh` | Same incident fixed twice -- standing credential, then Agentic IAM |
| `agent/insecure/`, `agent/secure/` | The two agent variants the demo scripts are built from |
| `scripts/preflight-check.sh` | Run before the demo -- verifies and auto-fixes the environment |
| `scripts/` | Incident simulation, reset, audit correlation, ephemeral-kubeconfig/orders-psql helpers |
| `scripts/dev/` | Mock IdP for rehearsing OBO+RAR without a real IBM Verify tenant |
| `docs/` | Presenter run-of-show + build/debug notes |
