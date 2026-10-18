# The on-call engineer's own Vault policy. Deliberately broader than the
# agent's ceiling — this engineer is also allowed to manage billing-service
# restarts directly, since that's a normal part of their job. The point of
# beat 4 is that this breadth does NOT flow through to the agent: OBO access
# is the intersection of ceiling_policies AND this policy AND RAR, so the
# ceiling still blocks the agent even though the human "could" approve it.
path "database/creds/readonly-orders" {
  capabilities = ["read"]
}

# "update", not "read" -- see the comment on this same path in
# ceiling-policy.hcl for why.
path "kubernetes/creds/checkout-restart-role" {
  capabilities = ["update"]
}

path "kubernetes/creds/billing-restart-role" {
  capabilities = ["update"]
}
