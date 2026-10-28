#!/usr/bin/env bash
# One-time load of sql/orders-schema.sql into the orders-db RDS instance.
# Replaces the postgres image's docker-entrypoint-initdb.d auto-load, which
# RDS has no equivalent for. Run once after scripts/bootstrap-eks.sh has
# the orders-db-proxy port-forward up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${ORDERS_DB_ADMIN_PASSWORD:?set to the orders-db admin password (from .env)}"

"${SCRIPT_DIR}/lib/orders-psql.sh" orders_admin "${ORDERS_DB_ADMIN_PASSWORD}" \
  -f "${SCRIPT_DIR}/../sql/orders-schema.sql"

echo "orders-db schema loaded."
