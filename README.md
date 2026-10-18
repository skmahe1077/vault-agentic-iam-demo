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
docker compose up -d
```

Then follow **[docs/DEMO-SCRIPT.md](docs/DEMO-SCRIPT.md)** for the full presenter run-of-show
(setup + all six beats, exact commands). **[docs/TALK-NOTES.md](docs/TALK-NOTES.md)** has the
build notes, every bug found/fixed along the way, and the mapping from the talk's abstract to
the actual mechanism in this repo.

## Prerequisites

- Docker, `kind`, `kubectl`, the `vault` CLI, `jq`
- A **Vault Enterprise** license (this repo was built against an IBM Passport Advantage
  `platform-standard` license — see TALK-NOTES for the `license_entitlement` config that
  requires)
- An IBM Verify tenant for the real delegated-authorization flow — or use **mock-IdP mode**
  (`scripts/dev/`) to rehearse the entire flow for real without one; see DEMO-SCRIPT.md

## Layout

| Path | What |
|---|---|
| `docker-compose.yml` | Vault Enterprise (dev mode) + Postgres (`orders` DB) |
| `k8s_manifests/` | checkout-service/billing-service + RBAC for the kind cluster |
| `vault-config/` | Secrets engines, policies, Agent Registry registration, IBM Verify config |
| `agent/insecure/`, `agent/secure/` | The two agent variants |
| `scripts/` | Incident simulation, reset, audit correlation, ephemeral-kubeconfig helper |
| `scripts/dev/` | Mock IdP for rehearsing OBO+RAR without a real IBM Verify tenant |
| `docs/` | Presenter run-of-show + build/debug notes |
