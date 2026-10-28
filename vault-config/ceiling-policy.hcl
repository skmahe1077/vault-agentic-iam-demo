# Blast-radius cap for sre-incident-agent. "update", not "read", on the
# kubernetes path -- generating K8s secrets engine creds is a PUT, unlike
# the database engine's plain GET.
path "database/creds/readonly-orders" {
  capabilities = ["read"]
}

path "kubernetes/creds/checkout-restart-role" {
  capabilities = ["update"]
}

# billing-restart-role deliberately absent -- the demo's overreach target.
