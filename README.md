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

Two things to arrange before the `vault-config/01-enable-secrets-engines.sh` step, since Vault
runs in HashiCorp's own cloud, not on the same docker network as `orders-db`/`kind`:

- **Reachability**: HCP Vault Dedicated needs a network path to reach `orders-db` and the
  `kind` cluster's API server — a tunnel (ngrok/cloudflared) for quick rehearsal, or HVN
  peering to a VPC that hosts them for something closer to production. Whatever `K8S_HOST`
  resolves to must be reachable *from HCP's network*, not just from your laptop.
- **Audit trail (beat 6)**: `scripts/show-audit-trail.sh` tails a local `file` audit device,
  which isn't how HCP Vault Dedicated exposes audit data (it uses HCP's own audit log
  streaming to an external sink instead). This is a known gap — see docs/TALK-NOTES.md.

## Prerequisites

- Docker, `kind`, `kubectl`, the `vault` CLI, `jq`
- An **HCP Vault Dedicated** cluster with Agent Registry available (confirm the cluster's
  Vault version supports Agent Registry/OBO/RAR)
- An IBM Verify tenant for the real delegated-authorization flow — or use **mock-IdP mode**
  (`scripts/dev/`) to rehearse the entire flow for real without one; see DEMO-SCRIPT.md

## Layout

| Path | What |
|---|---|
| `docker-compose.yml` | Postgres (`orders` DB) only -- Vault is HCP Vault Dedicated, not local |
| `k8s_manifests/` | checkout-service/billing-service + RBAC for the kind cluster |
| `vault-config/` | Secrets engines, policies, Agent Registry registration, IBM Verify config |
| `agent/insecure/`, `agent/secure/` | The two agent variants |
| `scripts/` | Incident simulation, reset, audit correlation, ephemeral-kubeconfig helper |
| `scripts/dev/` | Mock IdP for rehearsing OBO+RAR without a real IBM Verify tenant |
| `docs/` | Presenter run-of-show + build/debug notes |
