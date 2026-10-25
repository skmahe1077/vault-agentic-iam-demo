# vault-agentic-iam

Demo repo for **TLK-2725** (IBM TechXchange) — *No Standing Access for AI Agents with
HashiCorp Vault Agentic IAM and Ephemeral Authorization*.

An autonomous SRE incident-response agent diagnoses and fixes a `checkout-service` incident
using Vault Enterprise's Agentic IAM: a distinct **Agent Registry** identity, **delegated
(on-behalf-of) authorization**, **ceiling policies** that cap blast radius regardless of what's
requested or approved, and **ephemeral per-request authorization** (RAR) that scopes every
grant to one task and expires it right after.

Two variants of the same incident, side by side:
- `agent/insecure/` — the anti-pattern: a static, standing credential that can touch anything
- `agent/secure/` — the real flow: every action runs under a freshly delegated, RAR-scoped,
  short-lived grant

## Quick start

```bash
cp .env.example .env    # fill in ORDERS_DB_ADMIN_PASSWORD
docker compose up -d    # orders-db only -- Vault itself is HCP Vault Dedicated, not local
export VAULT_ADDR=https://<cluster-id>.vault.<region>.aws.hashicorp.cloud:8200
export VAULT_NAMESPACE=admin
vault login              # token/OIDC/userpass -- whatever your cluster's auth method is

cd terraform && terraform init && terraform apply \
  -var='eks_public_access_cidrs=["<your-ip>/32","<HCP egress CIDRs>"]' && cd ..
export AWS_REGION=us-east-1   # match terraform/variables.tf aws_region
./scripts/bootstrap-eks.sh
```

Then follow **[docs/DEMO-SCRIPT.md](docs/DEMO-SCRIPT.md)** for the full presenter run-of-show
(setup + all six beats, exact commands). **[docs/TALK-NOTES.md](docs/TALK-NOTES.md)** has the
build notes, every bug found/fixed along the way, and the mapping from the talk's abstract to
the actual mechanism in this repo.

## Running against HCP Vault Dedicated

This demo is built exclusively against **HCP Vault Dedicated** (Agent Registry already
provisioned there) — there is no local Vault container or Vault Enterprise license in this
repo. `vault-config/*.sh` and `agent/secure/run.sh` just read
`VAULT_ADDR`/`VAULT_TOKEN`/`VAULT_NAMESPACE` from the environment, so pointing them at your
HCP cluster (see Quick start above) is the entire setup.

The Kubernetes side runs on a real **EKS** cluster in AWS (`terraform/`), not a local `kind`
cluster — HCP Vault Dedicated reaches its API server directly over a public endpoint
restricted to HCP's published egress CIDRs plus your own IP (`eks_public_access_cidrs`, no
default on purpose — see terraform/variables.tf). `orders-db` still runs locally via
docker-compose, so two things remain to arrange before the
`vault-config/01-enable-secrets-engines.sh` step:

- **`orders-db` reachability**: HCP Vault Dedicated needs a network path to reach it — a
  tunnel (ngrok/cloudflared) for now. (The EKS side no longer needs this — its public endpoint
  solves that half directly.)
- **Audit trail (beat 6)**: `scripts/show-audit-trail.sh` tails a local `file` audit device,
  which isn't how HCP Vault Dedicated exposes audit data (it uses HCP's own audit log
  streaming to an external sink instead). This is a known gap — see docs/TALK-NOTES.md.

## Prerequisites

- Docker, `kubectl`, the `vault` CLI, the `aws` CLI (authenticated), `terraform`, `jq`
- An **HCP Vault Dedicated** cluster with Agent Registry available (confirm the cluster's
  Vault version supports Agent Registry/OBO/RAR)
- An AWS account to provision the EKS cluster in (`terraform/`)
- An IBM Verify tenant for the real delegated-authorization flow — or use **mock-IdP mode**
  (`scripts/dev/`) to rehearse the entire flow for real without one; see DEMO-SCRIPT.md

## Layout

| Path | What |
|---|---|
| `docker-compose.yml` | Postgres (`orders` DB) only -- Vault is HCP Vault Dedicated, not local |
| `terraform/` | EKS cluster + VPC (replaces the local `kind` cluster) |
| `k8s_manifests/` | checkout-service/billing-service + RBAC for the EKS cluster |
| `vault-config/` | Secrets engines, policies, Agent Registry registration, IBM Verify config |
| `agent/insecure/`, `agent/secure/` | The two agent variants |
| `scripts/` | Incident simulation, reset, audit correlation, ephemeral-kubeconfig helper |
| `scripts/dev/` | Mock IdP for rehearsing OBO+RAR without a real IBM Verify tenant |
| `docs/` | Presenter run-of-show + build/debug notes |
