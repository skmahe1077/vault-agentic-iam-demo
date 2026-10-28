# Maximum access this agent can ever have.
path "database/creds/readonly-orders" {
  capabilities = ["read"]
}

path "kubernetes/creds/checkout-restart-role" {
  capabilities = ["update"]
}
