#!/usr/bin/env bash
# Replaces `docker exec orders-db psql ...` now that orders-db is RDS, not a
# local container. Talks to it through the orders-db-proxy port-forward
# (scripts/bootstrap-eks.sh), same port docker-compose used to publish.
#
# libpq's psql is keg-only under Homebrew (not on PATH by default) --
# resolved via `brew --prefix libpq` with a plain `psql` fallback for
# non-Homebrew setups.
#
# Usage: scripts/lib/orders-psql.sh <user> <password> <psql-args...>
set -euo pipefail

DB_USER="$1"
DB_PASS="$2"
shift 2

PSQL_BIN="psql"
if LIBPQ_PREFIX=$(brew --prefix libpq 2>/dev/null) && [ -x "${LIBPQ_PREFIX}/bin/psql" ]; then
  PSQL_BIN="${LIBPQ_PREFIX}/bin/psql"
fi

# RDS rejects unencrypted connections -- force SSL rather than let libpq's
# default sslmode=prefer retry unencrypted and fail with a confusing
# "no pg_hba.conf entry ... no encryption" error on top of the real one.
PGPASSWORD="${DB_PASS}" PGSSLMODE=require "${PSQL_BIN}" \
  -h "${ORDERS_DB_HOST:-127.0.0.1}" \
  -p "${ORDERS_DB_PORT:-5433}" \
  -U "${DB_USER}" \
  -d orders \
  "$@"
