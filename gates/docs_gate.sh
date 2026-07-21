#!/usr/bin/env bash
set -u
ROOT="${1:-$(pwd)}"
RC=0
fail() { echo "FAIL[docs]: $1"; RC=1; }

for token in "Safety model" "Requirements" "Install" "Update" "Rollback" "Uninstall" "GUARDIAN_FALLBACK_MODE" "make test"; do
  grep -qi "$token" "$ROOT/README.md" || fail "README missing: $token"
done
grep -q 'R10' "$ROOT/REQUIREMENTS.md" || fail "requirements SSoT incomplete"
grep -q 'session name' "$ROOT/config/sessions.json.template" || fail "config template does not describe session-name keys"

if [ "$RC" -eq 0 ]; then
  echo "PASS[docs]: public usage and safety documentation present"
fi
exit "$RC"
