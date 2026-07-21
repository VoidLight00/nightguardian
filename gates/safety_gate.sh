#!/usr/bin/env bash
set -u
ROOT="${1:-$(pwd)}"
WATCHER="$ROOT/src/guardian-watch.sh"
RC=0
fail() { echo "FAIL[safety]: $1"; RC=1; }

grep -q 'GUARDIAN_FALLBACK_MODE="${GUARDIAN_FALLBACK_MODE:-hold}"' "$WATCHER" || fail "fallback is not fail-closed by default"
grep -q 'pane_runs_claude "$pane_id"' "$WATCHER" || fail "resume path lacks foreground Claude verification"
grep -q 'GUARDIAN_ALLOWED_COMMAND_RE="${GUARDIAN_ALLOWED_COMMAND_RE:-(^|/)(claude|claude\\.exe)$}"' "$WATCHER" || fail "default process allowlist is not executable-only"
grep -q 'acquire_pane_lock' "$WATCHER" || fail "pane-level atomic resume lock missing"
grep -q 'atomic_write_state' "$WATCHER" || fail "atomic state writer missing"
grep -q 'tmux_run send-keys -t "$pane_id"' "$WATCHER" || fail "resume does not target exact pane id"
if grep -q 'tmux_run send-keys -t "$session"' "$WATCHER"; then
  fail "session-wide key injection remains"
fi
grep -q "list-panes -a -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_id}'" "$WATCHER" || fail "all-pane enumeration missing"

if [ "$RC" -eq 0 ]; then
  echo "PASS[safety]: exact-pane and fail-closed guards present"
fi
exit "$RC"
