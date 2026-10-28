#!/usr/bin/env bash
# Pulls the Vault audit log and correlates every sre-incident-agent action
# back to: agent identity -> grant path -> capability -> expiry, newest
# first. Run after agent/secure-agent.sh.
#
# Audit log entries are HMAC'd (salted), not plaintext, by default -- field
# values like usernames/passwords are hashed. That's expected and fine for
# this demo: the point is the correlation (who/what/when), not recovering
# secret material from the log.
set -euo pipefail

AUDIT_LOG="$(dirname "$0")/../docker-compose/vault/logs/audit.log"

: "${AUDIT_LOG:?}"
if [ ! -f "${AUDIT_LOG}" ]; then
  echo "No audit log found at ${AUDIT_LOG}."
  exit 1
fi

# Vault's own audit entry already carries the full correlation we want --
# no joining needed. .auth.metadata.actor_entity_name is the agent;
# .auth.entity_id is the human being delegated for; .auth.policy_results
# .granting_policies names the exact policies that jointly granted it
# (literally the ceiling-policy + human-policy intersection, logged by
# Vault itself); .auth.token_ttl is capped by the delegation JWT's own
# remaining lifetime, not just the role's configured default.
#
# Shows only the last AUDIT_TAIL rows by default (set AUDIT_TAIL=0 for the
# full log) -- rehearsal/debugging leaves a long tail in this file and a
# live demo only wants the run that just happened. For an actually clean
# show, rm the audit log + `vault audit disable file && vault audit enable
# file file_path=/vault/logs/audit.log` beforehand instead of just tailing.
AUDIT_TAIL="${AUDIT_TAIL:-12}"

# -N (column headers) is GNU-only; macOS/BSD column lacks it, so print the
# header as a regular row instead -- portable either way.
{
  printf 'TIME\tACTOR\tON_BEHALF_OF_ENTITY\tPATH\tTTL\tGRANTING_POLICIES\tOUTCOME\n'
  ROWS=$(jq -r '
    select(.type == "response") |
    select(.request.path | test("database/creds/readonly-orders|kubernetes/creds/.*-restart-role")) |
    [
      .time,
      (.auth.metadata.actor_entity_name // "unknown-actor"),
      (.auth.entity_id // "no-entity"),
      .request.path,
      (.auth.token_ttl | tostring) // "n/a",
      ([.auth.policy_results.granting_policies[]?.name // empty] | join(",")),
      (if .error then "DENIED: " + .error else "GRANTED" end)
    ] | @tsv
  ' "${AUDIT_LOG}")
  if [ "${AUDIT_TAIL}" -eq 0 ]; then
    echo "${ROWS}"
  else
    echo "${ROWS}" | tail -n "${AUDIT_TAIL}"
  fi
} | column -t -s $'\t'
