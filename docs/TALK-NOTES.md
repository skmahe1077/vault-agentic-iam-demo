# TLK-2725 — No Standing Access for AI Agents with Vault Agentic IAM

## The three-layer model (source: developer.hashicorp.com/vault/ai/iam)

HashiCorp's own framing for Vault Agentic IAM is a three-layer access model, Vault acting as
an OAuth resource server validating JWTs from an authorization server (IBM Verify here).
Access is granted only where all three layers agree — this is the structure every beat below
maps onto directly:

| Layer | What it is | This repo |
|---|---|---|
| 1. Human baseline ACL policy | What the approving person can do | `oncall-engineer` policy (vault-config/oncall-engineer-policy.hcl) |
| 2. Agent ceiling policy | Max permissions the Agent Registry caps the agent to, regardless of what's requested | `ceiling-sre-incident-agent` policy (vault-config/ceiling-policy.hcl), tied to the agent's Agent Registry entry (vault-config/03) |
| 3. Per-session RAR claim | What this one token may access, for this one request | `authorization_details` in the delegation JWT (agent/secure/request-delegation-token.sh) |

## Learning outcomes -> demo mechanism

| Abstract promise | Demo mechanism |
|---|---|
| Every agent gets a distinct identity | `sre-incident-agent` Vault entity + entity-alias, registered via `agent-registry/register` (vault-config/03) |
| Delegated authorization | RFC 8693 token exchange: subject = on-call engineer, actor = agent (agent/secure/request-delegation-token.sh) |
| Granular identity-based policy + ceiling policies to control blast radius | Layers 1+2 above: `ceiling-sre-incident-agent` intersected with `oncall-engineer`'s own policy; beat 4 proves the ceiling holds even when the human's own policy would allow more |
| Ephemeral per-request authorization: scoped, expires after use, auditable | Layer 3 above: RAR `authorization_details` scoped to one Vault path per request; delegation tokens ~30s/single-use; `database/creds/*` and `kubernetes/creds/*` leases TTL in 2-10 min; scripts/show-audit-trail.sh correlates it all |

## Ephemeral authorization — the RAR claim (source: HashiCorp Vault Agentic IAM docs)

> The policy intersection defines the maximum set of actions an agent can take. In addition,
> Vault now supports per-request authorization to provide tight scopes for agents, a
> capability built into the authorization token (based on OAuth 2.0 Rich Authorization
> Request specification). This addition of transaction context works in concert with ceiling
> policies, allowing customers to limit what access credentials are granted on a per-request
> basis to avoid the risk of over-authorization.
>
> To enable ephemeral authorization, the Authorization Server specifies a set of permissions
> in the `authorization_details` claim of the JWT's body. **This binds the permission to the
> token's lifecycle rather than the agent's identity, so when the token expires, the agent
> cannot take further action.** This provides per-request resource control that is more
> secure than entity-based policies alone. Rather than issuing broadly scoped standing
> permissions, Vault evaluates authorization in the context of a specific request or
> workflow.

```json
"authorization_details": [
  {
    "capabilities": ["read"],
    "path": "secrets/my-secret",
    "type": "vault:path_access"
  }
]
```

This is the exact shape `agent/secure/request-delegation-token.sh` builds (`type:
vault:path_access`, `path`, `capabilities`) — confirmed matching, no changes needed there.
The bolded line above is the sharpest one-sentence framing for the talk: the grant is bound
to **the token's lifecycle, not the agent's identity** — that's *why* it dies on expiry
regardless of what the agent's standing identity could otherwise do, and it's the precise
distinction from entity-based policy alone (ceiling + human policy) that beat 5 needs to land.

## Scenario

`checkout-service` crash-loops from DB connection-pool exhaustion.
`sre-incident-agent` needs two tools to resolve it: a read-only diagnostic
query against `orders`, and a scoped Kubernetes rollout-restart. Neither
grant pre-exists; both are requested, scoped, and expire per-incident.

## Run order

**Confirmed working end-to-end 2026-10-18** against local dev-mode Vault (since retired --
see "HCP Vault Dedicated as the real demo target" below) except the IBM Verify OBO exchange
itself (see "Known rough edges" below).

```bash
cp .env.example .env            # fill in ORDERS_DB_ADMIN_PASSWORD
docker compose up -d            # orders-db only
export VAULT_ADDR=https://<cluster-id>.vault.<region>.aws.hashicorp.cloud:8200
export VAULT_NAMESPACE=admin
vault login                     # token/OIDC/userpass -- whatever this cluster's auth method is

# EKS cluster (replaces the local kind cluster used earlier) -- provision
# first with `terraform -chdir=terraform apply`, see "EKS on AWS replaces
# kind" below. CLUSTER_NAME defaults to vault-agentic-iam, matching
# terraform/variables.tf's cluster_name default.
export AWS_REGION=us-east-1
./scripts/bootstrap-eks.sh

# Vault's own RBAC for managing the K8s API (ServiceAccount "vault" in
# namespace "vault", plus `bind` grants scoped to the two target Roles --
# see "Kubernetes secrets engine wiring" below for why).
kubectl --context vault-agentic-iam apply -f k8s_manifests/vault-k8s-secrets-engine-rbac.yaml

# orders-db still runs locally via docker-compose, so HCP Vault Dedicated
# still needs a network path to reach it specifically (a tunnel, since
# there's no local Vault container on orders-db's docker network anymore).
# EKS's API server is a real public endpoint now, so K8S_HOST below needs
# no tunnel. ./vault-config/00-enable-audit.sh is a known gap against HCP
# (see below) -- omitted here.

ORDERS_DB_ADMIN_PASSWORD=... \
K8S_HOST="$(terraform -chdir=terraform output -raw cluster_endpoint)" \
K8S_CA_CERT=/tmp/vault-k8s-config/ca.pem \
K8S_REVIEWER_JWT=/tmp/vault-k8s-config/reviewer.jwt \
  ./vault-config/01-enable-secrets-engines.sh
# (generate those two files first -- see "Kubernetes secrets engine wiring" below)

IBM_VERIFY_ISSUER=... IBM_VERIFY_JWKS_URI=... ./vault-config/02-configure-ibm-verify.sh
IBM_VERIFY_ISSUER=... ONCALL_ENGINEER_SUBJECT=... SRE_AGENT_SUBJECT=... \
  ./vault-config/03-register-identities-and-agent.sh

./scripts/trigger-incident.sh                    # beat 0

eval "$(./scripts/create-insecure-demo-credentials.sh | grep '^export')"
./agent/insecure/run.sh                          # beat 1

IBM_VERIFY_TOKEN_ENDPOINT=... ONCALL_SUBJECT_TOKEN=... SRE_AGENT_ACTOR_TOKEN=... \
  ./agent/secure/run.sh                          # beats 2-5 (register already done above)

./scripts/show-audit-trail.sh                    # beat 6 -- known gap against HCP, see below

./scripts/reset.sh                               # between rehearsals
```

## Kubernetes secrets engine wiring (resolved 2026-10-18)

Generating `K8S_CA_CERT` / `K8S_REVIEWER_JWT` for the run order above:

```bash
mkdir -p /tmp/vault-k8s-config
kubectl --context vault-agentic-iam config view --raw \
  -o jsonpath='{.clusters[?(@.name=="vault-agentic-iam")].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/vault-k8s-config/ca.pem
kubectl --context vault-agentic-iam -n vault create token vault --duration=87600h \
  > /tmp/vault-k8s-config/reviewer.jwt
```

Things that weren't obvious and cost real debugging time:

- **RBAC privilege escalation**: `k8s_manifests/vault-k8s-secrets-engine-rbac.yaml`'s
  ClusterRole alone (serviceaccounts/token:create, serviceaccounts:create+delete,
  roles/rolebindings/clusterroles/clusterrolebindings:create+delete — verbatim from
  HashiCorp's own tutorial repo) is **not sufficient**. Kubernetes RBAC blocks creating a
  RoleBinding to a Role whose permissions you don't already hold, unless you also have the
  `bind` verb on that *specific* Role. The fix isn't to mirror checkout-restart-role's
  deployment-patch permissions onto Vault's own ClusterRole (that would hand Vault's standing
  credential the very rights it's only supposed to delegate per-request) — it's a narrow,
  per-namespace `bind` grant scoped to exactly `checkout-restart-role` /
  `billing-restart-role` by resourceName. Already in the manifest.
- **The CA-cert + JWT `@file` combo bug**: passing both `kubernetes_ca_cert=@file` and
  `service_account_jwt=@file` in the same `vault write kubernetes/config` call kills the
  connection with a bare `EOF` (reproduced reliably on Vault 2.2.0+ent). `vault-config/01-
  enable-secrets-engines.sh` already works around this with two sequential writes.
- **`name_template` syntax**: `{{.random}}` errors ("can't evaluate field random"); the
  correct form is `{{ random 8 | lowercase }}` — the `| lowercase` matters because K8s
  rejects a generated ServiceAccount/RoleBinding name with uppercase characters as an invalid
  RFC 1123 name. Already fixed in the script.
- **10-minute TTL floor**: Kubernetes' own TokenRequest API rejects `expirationSeconds < 600`
  regardless of what Vault's `token_default_ttl` requests. Roles are set to 10m/15m, not the
  originally-planned 2m/5m.
- **`kubectl --token=X` does nothing if a cert-/exec-based context is current**: if the active
  kubeconfig context already has an embedded client-certificate or exec-based auth plugin
  (true for kind's own admin context, and for `aws eks update-kubeconfig`'s default
  IAM-authenticator context), `kubectl --token=X --server=Y` silently authenticates via that
  instead of the token — confirmed by passing a garbage token and watching it "succeed." Both
  agent scripts
  now route through `scripts/lib/ephemeral-kubeconfig.sh`, which builds a throwaway kubeconfig
  containing *only* the token, before touching the K8s API. This matters for the demo's
  integrity, not just correctness: without it, beat 4's "ceiling blocks this" moment would
  silently pass for the wrong reason (ambient admin cert) rather than actually being blocked
  by the minted token's real RBAC scope.
- Host had no `psql` client — both agent scripts now run `psql` via `docker exec orders-db
  psql ...` instead of a host-installed client, so the demo doesn't depend on that being
  installed on talk day.

Verified for real (not just "should work"): a Vault-minted `kubernetes/creds/checkout-restart-
role` token successfully restarts `checkout-service` and gets a genuine `403 Forbidden` from
the real K8s API when pointed at `billing-service`; a Vault-minted `database/creds/readonly-
orders` credential reads `orders` fine and gets `permission denied for table
billing_accounts`. `agent/insecure/run.sh` runs end-to-end and dramatizes the opposite: the
same static credential does all four actions, scoped or not.

## IBM Verify console setup (not CLI-driven)

These steps happen in the IBM Verify admin console, not via a Vault or
Verify CLI, so they're not scripted:

1. Create (or reuse) an application registration for `sre-incident-agent`
   that can mint a client-credentials access token — this becomes the
   **actor token** in the OBO exchange.
2. Create a second identity/application for the on-call engineer's login
   flow (or reuse an existing human user) — this produces the **subject
   token**.
3. Confirm the tenant's token endpoint supports the RFC 8693
   token-exchange grant (`urn:ietf:params:oauth:grant-type:token-exchange`)
   and accepts an `authorization_details` parameter (RFC 9396 / RAR) on
   that grant. Record the exact parameter names the tenant expects —
   `agent/secure/request-delegation-token.sh` follows the RFC 8693/9396
   shape, but IBM Verify's token endpoint wasn't available to verify the
   exact request format against during setup; **validate this end-to-end
   before the live demo**, Auth0 is documented with a concrete worked
   example if a fallback is needed.
4. Note the tenant issuer URL and JWKS URI — these feed
   `IBM_VERIFY_ISSUER` / `IBM_VERIFY_JWKS_URI` in vault-config/02.
5. Record each identity's `sub` claim — these feed
   `ONCALL_ENGINEER_SUBJECT` / `SRE_AGENT_SUBJECT` in vault-config/03. The
   `issuer` field on every `identity/entity-alias` write must match exactly
   or Vault returns a misleading "no alias found" error despite the JWT
   itself validating fine.

## Vault license + image (retired 2026-10-24 -- local dev-mode Vault removed)

**Historical note, no longer applicable.** Early builds of this demo ran Vault locally in
dev mode via docker-compose, licensed with `vault_techxchange_Mahendran-Selvakumar.hclic` (an
**IBM Passport Advantage** license, edition `platform-standard`). That container, the
`*.hclic` file, the `license_entitlement` stanza (`docker-compose/vault/config/license-
entitlement.hcl`), and the `hashicorp/vault-enterprise:2.2-ent` image pin have all been
removed from this repo — the demo now runs exclusively against **HCP Vault Dedicated**, which
manages its own licensing/entitlement. Kept below only as a record of what was debugged, in
case local dev-mode Vault is ever reintroduced:

1. Image had to be **`hashicorp/vault-enterprise:2.2-ent`**, not `1.21-ent`.
   `license_entitlement` config support and Agentic IAM (Agent Registry/OBO/RAR)
   both need 2.x; 1.21 rejects the license outright (`invalid module:
   "platform-standard"`) and doesn't recognize the stanza at all (`unknown or
   unsupported field license_entitlement`).
2. A `license_entitlement { edition = "platform-standard" }` stanza, merged in via
   `-config=` alongside `-dev` on the command line.
3. Don't pass `-dev-plugin-dir=/vault/plugins` unless that directory is actually mounted — an
   unmounted plugin dir made the container unseal fully, print all its mount logs, then
   exit(1) silently with no banner and no visible panic. Dropping the flag (this demo uses no
   external plugins) fixed it.

Confirmed live at the time (local dev-mode Vault, now retired): `vault status` reported
`Version 2.2.0+ent`, `agent-registry/` showed up in `vault secrets list` as a real
`agent_registry`-type mount, file audit device enabled at `/vault/logs/audit.log`.

## HCP Vault Dedicated as the real demo target (2026-10-24)

The actual demo target is an **HCP Vault Dedicated** cluster with Agent Registry already
provisioned — HCP manages licensing/entitlement itself, so none of the retired license/image
concerns above apply; just confirm the cluster's Vault version supports Agent Registry/OBO/RAR
(same 2.x requirement as above).

What carries over unchanged: every `vault-config/*.sh` script and `agent/secure/run.sh` only
ever touch Vault through `VAULT_ADDR`/`VAULT_TOKEN`/`VAULT_NAMESPACE` — there's no
Vault-target-specific logic in any of them. Pointing `VAULT_ADDR` at the HCP cluster, setting
`VAULT_NAMESPACE=admin`, and authenticating via `vault login` is the entire swap.

What doesn't carry over:

- **No `docker network connect kind vault-agentic-iam` trick.** That only worked because local
  dev-mode Vault was itself a container on the same docker bridge network as `kind`. HCP Vault
  Dedicated runs in HashiCorp's own cloud (an HVN) — `K8S_HOST` (and the Postgres host for the
  database secrets engine) must be reachable *from HCP's network*, not just the laptop running
  these scripts. **Resolved for the K8s side (2026-10-24)**: `kind` was replaced with a real
  EKS cluster in AWS (`terraform/`). See "EKS on AWS replaces kind" below for how it's actually
  reached — the "HCP's published egress CIDRs" plan mentioned there turned out not to be
  possible; see "HCP Vault Dedicated publishes no static egress IPs" (2026-10-27) for why, and
  how `orders-db` (now RDS, not local-only) is reached instead.
- **Beat 6 (`scripts/show-audit-trail.sh`) doesn't work as-is.** It tails a local `file` audit
  device at `docker-compose/vault/logs/audit.log`, which only existed because local dev-mode
  Vault mounted that path from the container — now removed. HCP Vault Dedicated has no
  equivalent local filesystem to mount — audit instead goes through HCP's own audit log
  streaming to an external sink (CloudWatch/Datadog/etc., configured in the HCP portal). Known
  gap: this repo doesn't yet adapt beat 6 to query a streamed sink.

## EKS on AWS replaces kind (2026-10-24)

`scripts/bootstrap-kind.sh` is gone, renamed `scripts/bootstrap-eks.sh`; the cluster itself is
now provisioned by `terraform/` (an EKS module + a public-subnet-only VPC module, both from
`terraform-aws-modules`) instead of `kind create cluster`. Reasoning: the kubernetes secrets
engine's `K8S_HOST` needs to be reachable *from HCP Vault Dedicated's network*, and a real EKS
public endpoint is a more durable answer to that than a tunnel into a laptop-local `kind`
cluster — closer to how this would actually run, not just a rehearsal trick.

What changed mechanically:

- kubectl context is now just `vault-agentic-iam` (no `kind-` prefix) — every script that used
  to do `kubectl --context "kind-${CLUSTER_NAME}"` now does `kubectl --context
  "${CLUSTER_NAME}"`. `scripts/bootstrap-eks.sh` sets this via `aws eks update-kubeconfig
  --alias "${CLUSTER_NAME}"`.
- `k8s_manifests/*.yaml` (the Deployments, the two Vault-targeted Roles, Vault's own RBAC)
  needed **zero changes** — they're plain K8s manifests with nothing kind-specific in them.
- The EKS API server is given a public endpoint controlled via `eks_public_access_cidrs`
  (terraform/variables.tf), default `["0.0.0.0/0"]`. **Correction (2026-10-27)**: the original
  plan here was to restrict this to "HCP Vault Dedicated's published egress CIDR ranges" —
  no such list exists (see the new section below). It's open to the internet instead, same as
  the AWS/eksctl default for a public endpoint; IAM+RBAC auth on every request is what actually
  protects it.
- Nodes sit in public subnets with no NAT gateway, to keep this cheap for a short-lived demo
  cluster. **Unverified**: whether the EKS-managed node group's own launch template overrides
  the subnet's `map_public_ip_on_launch` for the nodes' network interfaces (module-version-
  dependent AWS launch-template behavior) — check with `aws ec2 describe-instances` after
  `terraform apply`; if nodes come up without a public IP, the fallback is `enable_nat_gateway
  = true` on `module.vpc` (small added cost, not yet needed/tested).
- `orders-db` moved from local docker-compose to RDS (2026-10-27) — see the new section below.
- `enable_cluster_creator_admin_permissions = true` grants the Terraform-applying IAM
  principal cluster-admin via an EKS access entry — no hand-rolled `aws-auth` ConfigMap.
- Not yet run live against a real AWS account/HCP Vault Dedicated cluster at the time of this
  note — `terraform validate` and `terraform init` (module/provider resolution) pass, but
  `terraform apply` + the full K8S_HOST/CA/reviewer-JWT handoff into
  `vault-config/01-enable-secrets-engines.sh` hasn't been rehearsed end-to-end yet. Treat as
  the next thing to validate before relying on it live.

## HCP Vault Dedicated publishes no static egress IPs, and orders-db moves to RDS (2026-10-27)

Discovered while actually trying to provision this for the first time (prior notes above
assumed "HCP Vault Dedicated's published egress CIDRs" existed — checked HashiCorp's own docs
and confirmed they don't). HashiCorp's supported ways for Vault Dedicated to reach a customer
resource are HVN peering, transit gateway, or PrivateLink/VPC Lattice — not a CIDR allowlist on
the customer's side. This changes both reachability stories at once:

- **EKS**: peering doesn't help, because the EKS public hostname resolves to public IPs even
  from inside a peered network — Vault's connection takes the internet path regardless. Settled
  on leaving the endpoint open (`0.0.0.0/0`), same as the AWS default; IAM+RBAC is the real
  control, not a CIDR list that was never obtainable.
- **orders-db**: moved off local docker-compose onto RDS, specifically *because* RDS can be
  reached privately where EKS can't — `publicly_accessible = false` means AWS publishes the
  instance's private IP in public DNS, so Vault resolves the plain hostname to `10.90.x.x` and
  routes it over an HVN peering connection (`terraform/hcp.tf`: `hcp_aws_network_peering` +
  `aws_vpc_peering_connection_accepter` + `hcp_hvn_route`, following the pattern in the
  `terraform-provider-hcp` docs). This retires the old "tunnel (ngrok/cloudflared) for
  orders-db" plan entirely — no tunnel needed once it's RDS behind peering.
- The existing HVN (`hvn`, AWS us-west-2, `172.25.16.0/20`) was created out-of-band, not by this
  repo's Terraform — `terraform/hcp.tf` reads it via `data "hcp_hvn"`, doesn't create it.
  `aws_region` default moved from us-east-1 to **us-west-2** to match it; peering is
  region-locked.
- The presenter's local `psql` still needs to reach RDS despite it being private now:
  `k8s_manifests/orders-db-proxy.yaml` (a `socat` forwarder) plus a `kubectl port-forward` in
  `scripts/bootstrap-eks.sh`, landing on `127.0.0.1:5433` — the same port docker-compose used to
  publish. `scripts/lib/orders-psql.sh` is the single call site every script (trigger-incident,
  reset, both agent/*/run.sh) routes through now.
- **Apostrophes inside `${VAR:?message}` silently swallow the rest of the script on macOS's
  system bash.** Found while debugging why `vault-config/01-enable-secrets-engines.sh`'s whole
  database section (its echo, both `vault write`s) never printed anything and never errored --
  `set -euo pipefail`, `bash -n`, everything looked clean. Root cause: macOS ships bash 3.2.57
  (GPLv3 licensing, `/bin/bash` and `/usr/bin/env bash` both resolve to it, no Homebrew bash
  installed here) and its parser does not treat a `'` inside `${VAR:?message}` as inert even
  when the whole expansion sits inside `"..."` -- confirmed in total isolation:
  `: "${FOO:?it's fine}"` fails `bash -n` with "unexpected EOF while looking for matching `''`".
  The lone apostrophe becomes an *opening* quote that bash then pairs with the next `'` it finds
  anywhere later in the file (here, one inside the `creation_statements` value), silently
  turning everything in between into one inert string literal passed to `:` -- no syntax error,
  exit 0, just missing output. Two more live instances found and fixed the same way in
  `agent/secure/request-delegation-token.sh` (`ONCALL_ENGINEER_SUBJECT`/`SRE_AGENT_SUBJECT`
  guards, the mock-IdP path beats 3-5 actually exercise) -- those two apostrophes happened to
  pair with *each other*, so execution wasn't broken downstream, but the SRE_AGENT_SUBJECT
  precondition check was silently merged into the other and never ran standalone. Fix was just
  dropping the apostrophe from each message (`cluster's` -> `clusters`, etc.) -- grepped the
  whole repo afterward for the same pattern (`\$\{[A-Za-z_]+:\?[^}]*'`) and confirmed clean.
- **hcp_vault_cluster's `tier` field has no literal `"essential"` value** in the Terraform
  provider schema — only `dev`, `standard_small/medium/large`, `plus_small/medium/large`.
  Agentic IAM needs Standard or Essential (Vault 2.1.2+) per HashiCorp's docs, so landed on
  `standard_small` as the cheapest tier that's both a valid Terraform value and satisfies that
  requirement. Worth re-checking if a literal Essential tier shows up in a future provider
  release.

## Agent Registry + identity wiring (resolved 2026-10-18)

Ran `vault-config/02-configure-ibm-verify.sh` and `03-register-identities-and-agent.sh` live
against this repo's Vault for the first time (with placeholder IBM Verify values, since a real
tenant wasn't available) and found three real things:

- **02 must actually run before 03, not just logically**: `identity/entity-alias` validates its
  `issuer` against an *already-configured* `sys/config/oauth-resource-server/<name>` at
  creation time, not just at token-exchange time later. Skipping straight to 03 fails with
  `oauth config not found for <issuer>`.
- **`vault write identity/entity name=X` is create-only**: rerunning it against a name that
  already exists returns an *empty* response (no `id` field) instead of erroring or updating,
  which silently breaks `-field=id` on reruns. Fixed with a lookup-by-name-first helper in the
  script (`lookup_or_create_entity`) — confirmed safe to rerun twice in a row now, same
  entity/registration IDs both times.
- **The registration's own `id` is a separate UUID from `entity_id`** — the setup docs implied
  they'd match ("the returned id matches the entity's canonical ID"); empirically they don't.
  There's also no `agent-registry/<id>` or `vault list agent-registry` path — the real paths
  are `agent-registry/registration/id/<id>`, `.../entity-id/<entity_id>`, and
  `.../display-name/<name>` (found via `vault path-help agent-registry`). The script now looks
  up by entity-id first so reruns don't create a duplicate registration, and prints the
  inspect command.
- Reading a registration back also shows Vault auto-appends two policies beyond what you
  submit: `default` and `default-ceiling`. `default-ceiling` just lets the entity read its own
  registration (`agent-registry/registration/entity-id/{{identity.entity.id}}`) and read the
  `default`/`default-ceiling` policy bodies — harmless, but worth knowing before being
  surprised by it live on `vault read agent-registry/registration/id/<id>`.

## OBO+RAR proven end-to-end with a mock IdP (resolved 2026-10-18)

The entire Vault-side OBO+RAR mechanism is now proven for real, not just configured --
rehearsed with `scripts/dev/mint_rar_jwt.py` + `scripts/dev/configure_mock_idp.sh` standing in
for IBM Verify (same protocol, just not the literal tenant, since none was available here).
This is the actual mechanism, not a simulation of it: a real RS256-signed JWT, carrying
`sub`/`act.sub`/`authorization_details`, verified by Vault against a real JWKS, resolved
through real entity-aliases, intersected against real ACL policies.

**Real bug found and fixed**: the kubernetes secrets engine's creds endpoint
(`vault write kubernetes/creds/<role> kubernetes_namespace=X`) is a PUT and needs the
**`update`** ACL capability -- not `read`, which is what `ceiling-policy.hcl`,
`oncall-engineer-policy.hcl`, and the RAR capability in `agent/secure/run.sh` were all set to.
Root-token testing earlier had masked this completely, since root bypasses ACL checks
entirely. A read-only token gets a bare `permission denied` here with **no**
`CEILING_POLICY_DENIED` hint, since the ACL check fails before the ceiling-intersection logic
even runs -- all three now fixed to `update`.

**Confirmed via two separate tests**: the effective TTL on any grant is
`min(role/engine's configured TTL, remaining validity of the delegation JWT)`. A 60s-TTL JWT
against the K8s role (10m default) got a ~59s token; a 300s-TTL JWT against the DB role (3m
default) got a 180s lease, the role default winning because it was the smaller number. This
is the literal mechanics behind "binds the permission to the token's lifecycle" from the
sourced quote above -- not just true in theory, now watched happening.

**`scripts/show-audit-trail.sh` rewritten** to surface what a single real audit entry already
carries, no joining needed: `.auth.metadata.actor_entity_name` (the agent), `.auth.entity_id`
(the human being delegated for), `.auth.policy_results.granting_policies` (the exact policies
that jointly granted it -- literally `oncall-engineer,ceiling-sre-incident-agent` on a GRANT,
empty on a DENY), and `.auth.token_ttl` (the capped value above). This is the single best
"controlled, traceable, auditable" artifact in the whole repo -- worth pulling up raw on
stage, not just through the script.

**Another instance of the earlier `@file`-combo EOF bug, different trigger this time**:
`vault policy write <name> <file>` reproducibly dies with a bare `EOF` once the policy file
crosses somewhere between 1174 and 1458 bytes (bisected precisely) -- a size threshold, not a
content issue; a trimmed 23-line version of the same file uploads fine every time.
`ceiling-policy.hcl` is kept short because of this; if policy files grow again, watch for this
failure mode and trim rather than assume the policy syntax itself is wrong.

**Rehearsing without a real IBM Verify tenant**: run `MOCK_ISSUER=<same string as
IBM_VERIFY_ISSUER> scripts/dev/configure_mock_idp.sh` once per docker-compose session, then
mint delegation JWTs directly with `python3 scripts/dev/mint_rar_jwt.py <issuer> <human-sub>
<agent-sub> <vault-path> <capability> [--ttl seconds]` and use the output as `VAULT_TOKEN` for
any `vault read`/`vault write` call. This proves Vault's side of OBO+RAR for real; it is not a
substitute for validating IBM Verify's actual token endpoint behavior before the talk (still
the one real unknown -- see below).

## IBM Verify real-tenant integration: blocked on a HashiCorp doc gap (found 2026-10-19)

Tried for real against `devopstronaut.verify.ibm.com` (not mock): both `act.sub` (delegation)
and `authorization_details` (RAR) work *individually* against this tenant, confirmed with
real decoded JWTs --

- **Delegation works**: RFC 8693 token-exchange with `subject_token` + `actor_token` reliably
  returns a JWT with a populated `act.sub` claim. Tested repeatedly, works every time.
- **`authorization_details` never appears in the issued token**, even after doing everything
  documented: created an Authorization Detail Type named `vault:path_access` with the exact
  schema from developer.hashicorp.com/vault/ai/iam/providers/verify, confirmed it as a
  selected "Authorization detail type" on the STS client's "Custom scopes and API access"
  settings, confirmed the Name/Schema are byte-for-byte correct, waited for propagation,
  retried multiple times. Still absent.
- Checked IBM's own docs (docs.verify.ibm.com) directly: `authorization_details` is
  documented on the **Authorize**, **PAR**, and **Device Authorization** endpoints -- all
  human-consent-driven flows -- but is **not** documented on the token-exchange grant at all.
  The PAR endpoint's full parameter schema has **no** delegation/actor/on-behalf-of parameter
  either. No documented path combines delegation + RAR in one request/token for IBM Verify
  SaaS.
- **Root cause, confirmed directly from HashiCorp's own setup-obo doc**: the IBM Verify tab
  of the "validate the OBO flow" step contains a literally broken, non-functional curl
  example (`--variable`, `--expand-data` -- not real curl flags, mismatched quoting). The
  only complete, working worked example in that doc is for **Auth0**, not IBM Verify. This
  looks like a genuine gap in HashiCorp's reference material, not a tenant misconfiguration
  on our side -- we correctly configured everything the docs actually describe.

**Decision**: use the mock-IdP path (`scripts/dev/`) for the actual talk. It proves the exact
same protocol mechanics Vault enforces (sub/act.sub/authorization_details, JWKS validation,
ceiling intersection) and has been validated repeatedly end-to-end. Real IBM Verify
integration is a follow-up for after the talk, pursued with IBM/HashiCorp support directly --
not a blocker. `agent/secure/request-delegation-token.sh`'s real (non-mock) branch is left in
place for whenever that gets resolved, unchanged.

**Update 2026-10-19, same day**: split the demo so delegation (OBO) and RAR are shown
*separately*, since delegation genuinely works against the real tenant -- only RAR doesn't.
`scripts/dev/real-ibmverify-obo-demo.sh` performs the real client_credentials + ROPC +
token-exchange sequence against `devopstronaut.verify.ibm.com` and presents the resulting
token straight to Vault. Confirmed live: Vault resolves the real entity/actor via a *second*
set of entity-aliases tied to the real issuer, and grants `database/creds/readonly-orders`
via ceiling ∩ human-policy alone (no RAR claim present). Audit log shows
`metadata.jwt_issuer: https://devopstronaut.verify.ibm.com/oidc/endpoint/default` and
`metadata.actor_entity_name: sre-incident-agent` for real.

One-time setup this required, on top of the mock-IdP config (both profiles coexist --
Vault matches by `iss` claim, so there's no conflict):
```bash
# Second oauth-resource-server profile, pointed at the real tenant, with
# optional_authorization_details=true so a token lacking the RAR claim
# isn't rejected outright (the mock profile keeps it required/false).
vault write sys/config/oauth-resource-server/verify-real \
  issuer_id="${IBM_VERIFY_ISSUER}" use_jwks=true user_claim=sub \
  supported_algorithms="RS256" jwks_uri="${IBM_VERIFY_JWKS_URI}" \
  optional_authorization_details=true

# A SECOND entity-alias on each existing entity (Vault allows multiple
# aliases per entity, one per issuer) -- external_id values are the real
# claims confirmed earlier: the human's numeric sub, the agent's client_id
# as act.sub.
vault write identity/entity-alias name="jwt-binding-subject-real" \
  canonical_id="<oncall-engineer entity id>" issuer="${IBM_VERIFY_ISSUER}" \
  external_id="6470002374"
vault write identity/entity-alias name="jwt-binding-actor-real" \
  canonical_id="<sre-incident-agent entity id>" issuer="${IBM_VERIFY_ISSUER}" \
  external_id="${IBM_VERIFY_CLIENT_ID}"
```

Also re-found and this time actually fixed in the script file (not just live via CLI):
`vault-config/03-register-identities-and-agent.sh` still had
`ceiling_policies='["ceiling-sre-incident-agent"]'` (the bracketed-string bug from the
2026-10-18 Agent Registry session) -- the live fix from that session was never saved back
into the file. Now reads `ceiling_policies="ceiling-sre-incident-agent"`.

## UI walkthrough: explored, not worth it (2026-10-28)

Tried to replace the terminal demo with a Vault UI walkthrough, for an audience that would
find clicking through screens easier to follow than reading terminal output. Three findings,
in the order they killed the idea:

- **No Agent Registry page** in this Vault UI build (checked: only "Leases" under Access).
  The closest equivalent is Access → Entities → `sre-incident-agent`, which does show the
  ceiling policy attached -- untested whether this actually renders correctly, conversation
  moved on before confirming.
- **The Leases list page throws a client-side JS error** (`Cannot read properties of
  undefined (reading 'leases')`) on this specific HCP Vault Dedicated cluster/version --
  a bug in Vault's own UI, not something fixable from this repo. `hcp` CLI confirmed (again)
  to have zero Vault Dedicated management commands, so no way to inspect/fix this from there
  either.
- **The actual blocker, independent of the above two bugs**: the ceiling-denial moment
  structurally cannot be shown by clicking around as the logged-in admin user. The denial only
  happens because the request runs under a narrowly-scoped delegation JWT -- to see it in the
  UI you'd have to authenticate the UI session *as that JWT* (confirmed this works: the same
  raw JWT value that works as `VAULT_TOKEN` for the CLI also works pasted into the UI's
  "Token" login method), which is only valid for its TTL window (60s default, overridable via
  `RAR_TTL` -- see below). Tried this live: hit `RAR_NO_MATCH` on the actual generate-credentials
  attempt, most likely because the freshly-logged-in UI session resets to the root namespace
  rather than staying on `admin`, where the kubernetes mount and oauth-resource-server config
  actually live -- never got to confirm the fix because of how narrow the window is to
  navigate three UI pages before the token expires.

Net: terminal is the reliable path. Don't retry this without first fixing namespace handling
*and* confirming the Leases page bug is gone on whatever cluster/version is current then.

## Narration was reporting the wrong TTL (2026-10-28)

`agent/secure/run.sh` printed hardcoded "~3m" / "~10m" strings for the diagnose and fix
credentials -- copied from the roles' `default_ttl`/`token_default_ttl` in
`vault-config/01-enable-secrets-engines.sh`. Those numbers are real for a direct/root-token
request, confirmed by testing one: `lease_duration` comes back as 180 and 600 respectively.
But the live demo never requests credentials that way -- it goes through a delegation JWT
(`scripts/dev/mint_rar_jwt.py`, default `ttl=60`), and Vault caps the issued lease to
`min(role's default_ttl, delegation JWT's remaining validity)`. So every grant in the actual
demo path was really expiring in well under a minute, not 3-10 minutes as narrated -- found
this while trying to catch a lease in the Vault UI before it expired and the timing never
added up.

Fixed by reading `.lease_duration` off the actual API response (`DB_CREDS`/`K8S_CREDS`, both
already captured in the script) instead of hardcoding a guess, and by adding a `RAR_TTL` env
var (forwarded as `mint_rar_jwt.py --ttl`) so the window can be widened when needed --
still bounded by the role's own ceiling (180s/600s), so widening it never makes anything
actually standing.

## Known rough edges to validate before the live run

- **The one real unknown left**: the actual OBO+RAR delegation-token exchange against a real
  IBM Verify tenant (`agent/secure/request-delegation-token.sh`). Every piece downstream of
  receiving that JWT (both secrets engines with corrected capabilities, both ceiling-relevant
  RBAC paths, the audit correlation, the TTL-capping behavior) is now proven live. What's
  *not* yet proven is IBM Verify's token endpoint accepting the RFC 8693 token-exchange grant
  with an `authorization_details` (RAR) parameter in the exact shape the script sends --
  validate this first against the real tenant, with Auth0's documented PAR+PKCE flow as a
  fallback shape to compare against if IBM Verify's endpoint wants something different.
- `vault kv` commands fail OBO preflight checks — every script above uses
  `vault read`/`vault write`, not `vault kv`, intentionally.
- RAR delegation tokens are short-lived (~30s); `agent/secure/run.sh`
  requests a fresh one per Vault action rather than reusing one across
  both the diagnose and fix steps.
