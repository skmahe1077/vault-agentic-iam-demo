# Demo script — TLK-2725

A presenter run-of-show: what to type, in what order, and what to say. Rehearsed end-to-end
on 2026-10-18 using the mock IdP (`MOCK_IDP_ISSUER` mode) standing in for IBM Verify. Re-
rehearsed end-to-end against **real** AWS + HCP infrastructure (EKS, RDS, HCP Vault Dedicated
v2.1.2, HVN peering) on 2026-10-27 — run well over a dozen times that night without a single
failure. Every command below is copy-pasteable as written.

## Setup steps (run once, not part of the demo itself)

This demo targets **HCP Vault Dedicated** exclusively -- no local Vault container, no Vault
Enterprise license. `terraform/` provisions the Vault cluster itself, a real **EKS** cluster
(replacing the local `kind` cluster used earlier), and `orders-db` on **RDS**. HCP Vault
Dedicated reaches EKS's public endpoint directly over the internet (IAM+RBAC authenticated --
there's no static egress-IP list to lock it down to) and reaches RDS privately over an HVN
peering connection -- see "Running against HCP Vault Dedicated" in README.md for why those two
paths differ.

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

# Mock-IdP mode (today) -- swap for the real IBM_VERIFY_* values once validated.
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

## Running the demo — one script, one continuous story

No standing-credential anti-pattern in this cut of the talk — the abstract only promises the
solution, so `agent/demo.sh` only shows the solution, end to end. If you want the audience to
see the anti-pattern fail before the fix holds, run `agent/demo-contrast.sh` instead — same
incident, fixed twice (standing credential, then Agentic IAM), self-sufficient the same way.
Both scripts share `agent/secure-agent.sh`; `demo-contrast.sh` just also runs
`agent/insecure-agent.sh` first.

Neither script explains the concept — every line printed is the real output of a `vault`,
`kubectl`, or `psql` command run against the actual HCP Vault Dedicated cluster. Section
labels (e.g. `=== delegated authorization: diagnosing ===`) just name which command is about
to run; they're not narration. Say the talking points yourself, live, over the real output —
don't expect the terminal to say them for you.

**No manual export block needed** — both `scripts/preflight-check.sh` and `agent/demo.sh` are
self-sufficient: they source `/tmp/vault-session.env` (VAULT_ADDR/VAULT_NAMESPACE/VAULT_TOKEN,
written once by `terraform apply`) and `.env` (ORDERS_DB_ADMIN_PASSWORD) themselves, and
default the mock-IdP values if not already set. From any fresh terminal *on this machine*,
just `cd` into the repo and run them — nothing to re-export first. (A different machine that
was never set up won't have `/tmp/vault-session.env`; both scripts fail with a clear message
telling you what's missing rather than silently misbehaving.)

**Right before running the demo**, run the preflight check — it verifies Vault, the Agent
Registry entry, checkout-service's pods, the orders-db-proxy port-forward, and the mock-IdP
tunnel, and auto-fixes the two that have been seen dropping silently between rehearsals (the
port-forward and the tunnel):

```bash
./scripts/preflight-check.sh
```
Wait for `ALL CLEAR` before continuing. If checkout-service isn't `2/2 ready`, run
`./scripts/reset.sh` first (pods take a few seconds to settle after any reset/restart —
re-check with `kubectl -n prod-checkout get pods` before moving on).

Then one command runs the whole thing, in the exact order the abstract makes its claims,
pausing between sections so you can talk over the real output:

```bash
./agent/demo.sh
```

- **`SCENE: checkout-service is degrading`** — fires the incident
  (`scripts/trigger-incident.sh`): checkout-service degrading, a connection leak against the
  orders database. Say over it: "traditional IAM assumes a predictable human, not an
  autonomous agent."
- **`1. A DISTINCT, GOVERNED IDENTITY -- Agent Registry`** — reads `sre-incident-agent`'s
  Agent Registry entry and its ceiling policy, live. Say: "not a shared service account, not
  a static password."
- **`2, 3, 4. DELEGATED AUTHORIZATION, CEILING, EPHEMERAL GRANT`** — runs
  `agent/secure-agent.sh`, three things happen in order:
  - diagnoses via `database/creds/readonly-orders`, on behalf of the approving on-call
    engineer
  - attempts `kubernetes/creds/billing-restart-role`; denied with a bare
    `403 permission denied` (confirmed live — Vault's ACL check fails before
    ceiling-intersection logic even runs, so there's no ceiling-specific hint in the error
    text itself), even though the on-call engineer's own policy allows it. Say: "the human
    could approve this. The ceiling still says no."
  - fixes checkout-service via a token RAR-scoped to exactly this one path, real TTL printed
    on screen. Say: "every grant above was scoped to one task and already expiring."

**On the actual TTL shown**: the script now prints whatever Vault actually issued (it reads
`.lease_duration` off the API response), not a hardcoded guess. In mock-IdP mode this will
read something like `59s`, not the roles' configured 3m/10m defaults — because the effective
TTL is `min(role's default_ttl, remaining validity of the delegation JWT)`, and the mock JWT
defaults to a 60s window (`scripts/dev/mint_rar_jwt.py`). That's accurate, not a bug: the
narration point still lands ("already expiring or expired"), it's just a shorter window than
the role config alone would suggest. Override with `export RAR_TTL=<seconds>` before running
if you need more breathing room for some reason — still bounded by the role's own ceiling
(180s for the DB role, 600s for the K8s role), so it's never actually standing.

It pauses for enter between sections (`pause()` in the script) so you can talk over each one —
run it non-interactively instead (e.g. in a recording) with `./agent/demo.sh < /dev/null`.

**UI instead of terminal — don't.** Explored this at length: Agent Registry has no page in
this Vault UI build, the Leases list page throws a JS error on this cluster, and even with
both working, the ceiling-denial moment can't be shown in the UI at all — it requires being
authenticated *as* the ephemeral delegation token (not the admin session), which means
pasting a JWT into the login box within its ~60-300s window, live, which isn't realistic to
pull off. Terminal is the reliable path; see docs/TALK-NOTES.md "UI walkthrough: explored, not
worth it" for the full account if this comes up again.

## Reset between rehearsals

```bash
./scripts/reset.sh
```
Clears leaked DB connections and restores checkout-service's probes. Does not revoke
outstanding leases — do that separately if a fully clean state is needed (`vault lease revoke
-prefix database/` / `kubernetes/`).
