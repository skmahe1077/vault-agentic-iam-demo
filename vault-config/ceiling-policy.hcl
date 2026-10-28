# Blast-radius cap for sre-incident-agent. See docs/TALK-NOTES.md
# "Agent Registry + identity wiring" for the full rationale and the
# capability choices below (update, not read, on the kubernetes paths).
path "database/creds/readonly-orders" {
  capabilities = ["read"]
}

path "kubernetes/creds/checkout-restart-role" {
  capabilities = ["update"]
}

# billing-restart-role deliberately absent -- the demo's overreach target.
