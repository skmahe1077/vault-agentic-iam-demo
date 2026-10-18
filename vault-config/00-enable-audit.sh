#!/usr/bin/env bash
# Enables the file audit device beat 6 (audit correlation) reads from.
# Run this first, before any of the other vault-config scripts, so every
# subsequent setup/demo action is captured.
set -euo pipefail

vault audit enable file file_path=/vault/logs/audit.log 2>/dev/null || echo "already enabled"
echo "File audit device enabled at /vault/logs/audit.log"
