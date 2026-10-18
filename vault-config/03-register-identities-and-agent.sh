#!/usr/bin/env bash
# Creates the Vault entities for the human (on-call engineer) and the agent,
# binds each to its IBM Verify external identity via entity-alias, writes
# the two policies, and registers the agent in the Agent Registry.
#
# The `issuer` field on entity-alias is mandatory -- omitting it produces a
# misleading "no alias found" error later even though JWT validation
# succeeds (confirmed against the OBO setup docs).
set -euo pipefail

: "${IBM_VERIFY_ISSUER:?set to the IBM Verify tenant issuer URL}"
: "${ONCALL_ENGINEER_SUBJECT:?set to the on-call engineer IBM Verify sub claim}"
: "${SRE_AGENT_SUBJECT:?set to the sre-incident-agent IBM Verify sub claim, i.e. its app registration client/sub}"

vault policy write ceiling-sre-incident-agent "$(dirname "$0")/ceiling-policy.hcl"
vault policy write oncall-engineer "$(dirname "$0")/oncall-engineer-policy.hcl"

# `vault write identity/entity name=X` is create-only: re-running it against
# an already-existing name returns an EMPTY response (no `id` field) rather
# than erroring or updating, which breaks `-field=id` on reruns. Look the
# entity up by name first so this script is safe to rerun during rehearsal.
lookup_or_create_entity() {
  local name="$1"; shift
  local existing
  existing=$(vault read -field=id "identity/entity/name/${name}" 2>/dev/null) || true
  if [ -n "${existing}" ]; then
    echo "${existing}"
  else
    vault write -field=id identity/entity name="${name}" "$@"
  fi
}

echo "--- human entity: on-call engineer ---"
ONCALL_ENTITY_ID=$(lookup_or_create_entity "oncall-engineer" policies="oncall-engineer")

vault write identity/entity-alias \
    name="jwt-binding-subject" \
    canonical_id="${ONCALL_ENTITY_ID}" \
    issuer="${IBM_VERIFY_ISSUER}" \
    external_id="${ONCALL_ENGINEER_SUBJECT}"

echo "--- agent entity: sre-incident-agent ---"
AGENT_ENTITY_ID=$(lookup_or_create_entity "sre-incident-agent")

vault write identity/entity-alias \
    name="jwt-binding-actor" \
    canonical_id="${AGENT_ENTITY_ID}" \
    issuer="${IBM_VERIFY_ISSUER}" \
    external_id="${SRE_AGENT_SUBJECT}"

echo "--- agent registry ---"
# The registration's own `id` is a SEPARATE uuid from entity_id -- despite
# what the setup docs suggest, they do not match. Look it up by entity-id
# afterward so reruns don't create a second registration for the same agent.
if ! REGISTRATION_ID=$(vault read -field=id "agent-registry/registration/entity-id/${AGENT_ENTITY_ID}" 2>/dev/null); then
  REGISTRATION_ID=$(vault write -field=id agent-registry/register \
      display_name="sre-incident-agent" \
      description="Diagnoses and remediates checkout-service incidents via ephemeral, task-scoped grants" \
      entity_id="${AGENT_ENTITY_ID}" \
      ceiling_policies='["ceiling-sre-incident-agent"]')
fi

echo "ONCALL_ENTITY_ID=${ONCALL_ENTITY_ID}"
echo "AGENT_ENTITY_ID=${AGENT_ENTITY_ID}"
echo "REGISTRATION_ID=${REGISTRATION_ID}"
echo "Registered sre-incident-agent with ceiling-sre-incident-agent."
echo "Inspect with: vault read agent-registry/registration/id/${REGISTRATION_ID}"
