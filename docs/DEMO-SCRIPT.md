# Demo script — TLK-2725

A presenter run-of-show: what to type, in what order, and what to say. Rehearsed end-to-end
on 2026-10-18 using the mock IdP (`MOCK_IDP_ISSUER` mode) standing in for IBM Verify — swap
to the real tenant's env vars once validated (see "Switching to the real IBM Verify tenant"
at the bottom); nothing else in this script changes either way.

## Before you go on stage (not shown live)

```bash
cp .env.example .env            # fill in ORDERS_DB_ADMIN_PASSWORD
docker compose up -d
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root

./scripts/bootstrap-kind.sh
docker network connect kind vault-agentic-iam
kubectl --context kind-vault-agentic-iam apply -f k8s_manifests/vault-k8s-secrets-engine-rbac.yaml

./vault-config/00-enable-audit.sh

mkdir -p /tmp/vault-k8s-config
kubectl --context kind-vault-agentic-iam config view --raw \
  -o jsonpath='{.clusters[?(@.name=="kind-vault-agentic-iam")].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/vault-k8s-config/ca.pem
kubectl --context kind-vault-agentic-iam -n vault create token vault --duration=87600h \
  > /tmp/vault-k8s-config/reviewer.jwt

ORDERS_DB_ADMIN_PASSWORD=changeme-local-only \
K8S_HOST="https://vault-agentic-iam-control-plane:6443" \
K8S_CA_CERT=/tmp/vault-k8s-config/ca.pem \
K8S_REVIEWER_JWT=/tmp/vault-k8s-config/reviewer.jwt \
  ./vault-config/01-enable-secrets-engines.sh

# Mock-IdP mode (today) -- swap for the real IBM_VERIFY_* values once validated.
export MOCK_IDP_ISSUER="https://test-tenant.verify.ibm.com/oidc/endpoint/default"
MOCK_ISSUER="${MOCK_IDP_ISSUER}" ./scripts/dev/configure_mock_idp.sh

export ONCALL_ENGINEER_SUBJECT="oncall-engineer-test-subject"
export SRE_AGENT_SUBJECT="sre-incident-agent-test-subject"
IBM_VERIFY_ISSUER="${MOCK_IDP_ISSUER}" \
  ./vault-config/03-register-identities-and-agent.sh

# Sanity check everything is live before walking on stage:
vault status
vault secrets list
vault read agent-registry/registration/entity-id/"$(vault read -field=id identity/entity/name/sre-incident-agent)"
```

For a genuinely clean audit log on stage, also do this right before going on (everything
above produces audit noise during setup):

```bash
vault audit disable file
rm -f docker-compose/vault/logs/audit.log
vault audit enable file file_path=/vault/logs/audit.log
```

## On stage — the six beats

Export these once per terminal session (keeps every beat's commands short):

```bash
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
export CLUSTER_NAME=vault-agentic-iam
export MOCK_IDP_ISSUER="https://test-tenant.verify.ibm.com/oidc/endpoint/default"
export ONCALL_ENGINEER_SUBJECT="oncall-engineer-test-subject"
export SRE_AGENT_SUBJECT="sre-incident-agent-test-subject"
```

### Beat 0 — fire the incident

```bash
./scripts/trigger-incident.sh
kubectl --context kind-vault-agentic-iam -n prod-checkout get pods   # watch READY/RESTARTS climb
```
Say: "checkout-service is degrading — a connection leak against the orders database, and the
pod can't stay healthy."

### Beat 1 — the anti-pattern: standing, unscoped access

```bash
eval "$(./scripts/create-insecure-demo-credentials.sh | grep '^export')"
./agent/insecure/run.sh
```
Say, pointing at the last two blocks of output: "same static credential that fixed the
incident just read billing card data and restarted billing-service — neither one was asked
for. No identity, no task scope, no expiry, no audit trail tying any of it back to this
incident."

### Beat 2 — the agent gets a real, distinct identity

```bash
vault read agent-registry/registration/entity-id/"$(vault read -field=id identity/entity/name/sre-incident-agent)"
```
Say: "sre-incident-agent is a real Vault entity, registered in the Agent Registry with its
own ceiling policy — not a shared service account, not a static password."

### Beats 3–5 — delegated, ceiling-capped, ephemeral grant does the real fix

```bash
./agent/secure/run.sh
```
This single script runs all three beats:
- **Beat 3 (delegated authorization)**: diagnoses via `database/creds/readonly-orders`, on
  behalf of the approving on-call engineer.
- **Beat 4 (ceiling blocks overreach)**: attempts `kubernetes/creds/billing-restart-role` —
  denied with `CEILING_POLICY_DENIED`, even though the on-call engineer's own policy allows
  it. Say: "the human could approve this. The ceiling still says no."
- **Beat 5 (ephemeral grant fixes it)**: restarts checkout-service via a token minted and
  expiring in minutes, scoped by RAR to exactly this one Vault path.

### Beat 6 — audit closes the loop

```bash
./scripts/show-audit-trail.sh
```
Say, pointing at columns left to right: "`ACTOR` — the agent. `ON_BEHALF_OF_ENTITY` — the
human who approved it. `GRANTING_POLICIES` — the exact two policies that had to agree,
logged by Vault itself. `TTL` — capped to the delegation token's own lifetime, not the role's
default. Every action, scoped, expiring, and traceable back to a person."

## Reset between rehearsals

```bash
./scripts/reset.sh
```
Clears leaked DB connections and restores checkout-service's probes. Does not clear the
audit log or revoke outstanding leases — do that separately if a fully clean state is needed
(see the audit-log reset above; `vault lease revoke -prefix database/` /
`kubernetes/` for leases).

## Switching to the real IBM Verify tenant

Nothing in `agent/secure/run.sh` or this script changes. Only swap the env vars in the setup
step and in the "export once per session" block:

```bash
unset MOCK_IDP_ISSUER ONCALL_ENGINEER_SUBJECT SRE_AGENT_SUBJECT
export IBM_VERIFY_TOKEN_ENDPOINT="https://<tenant>.verify.ibm.com/oauth2/token"
export ONCALL_SUBJECT_TOKEN="<real on-call engineer access token>"
export SRE_AGENT_ACTOR_TOKEN="<real sre-incident-agent access token>"
```
`agent/secure/request-delegation-token.sh` picks the real RFC 8693 token-exchange path
automatically once `MOCK_IDP_ISSUER` is unset. Validate this exchange against the real tenant
*before* the talk — it's the one leg of this whole demo that hasn't been proven live (see
docs/TALK-NOTES.md "Known rough edges").
