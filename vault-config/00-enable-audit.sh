#!/usr/bin/env bash
# Enables the file audit device beat 6 (audit correlation) reads from.
# Run this first, before any of the other vault-config scripts, so every
# subsequent setup/demo action is captured.
#
# Known gap against HCP Vault Dedicated: it doesn't expose a writable local
# filesystem for the `file` device the way this script assumes -- audit
# there goes through HCP's own audit log streaming to an external sink
# instead (configured in the HCP portal, not scripted here). This script
# and scripts/show-audit-trail.sh (beat 6) don't work unmodified against
# HCP yet -- see docs/TALK-NOTES.md.
set -euo pipefail

vault audit enable file file_path=/vault/logs/audit.log 2>/dev/null || echo "already enabled"
echo "File audit device enabled at /vault/logs/audit.log"
