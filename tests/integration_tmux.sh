#!/usr/bin/env bash
# Isolated tmux integration test. Never touches the user's default tmux server.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="nightguardian-test-$$"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nightguardian.XXXXXX")"
RUNTIME="$TMP_ROOT/runtime"
WATCHER="$ROOT/src/guardian-watch.sh"
RC=0

fail() { printf 'FAIL[integration]: %s\n' "$*"; RC=1; }
pass() { printf 'PASS[integration]: %s\n' "$*"; }
cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$RUNTIME/config" "$RUNTIME/manifest" "$RUNTIME/logs"
cat > "$RUNTIME/config/sessions.json" <<'JSON'
{
  "safe": {"resume_prompt": "printf 'NG_RESUMED\\n'"},
  "changed": {"resume_prompt": "printf 'SHOULD_NOT_RUN\\n'"},
  "multi": {"resume_prompt": "printf 'MULTI_RESUMED\\n'"}
}
JSON

scan() {
  GUARDIAN_CONFIG_DIR="$RUNTIME" \
  GUARDIAN_TMUX_SOCKET="$SOCKET" \
  GUARDIAN_ALLOWED_COMMAND_RE='(^|/)(bash)$' \
  bash "$WATCHER" --scan-once
}

scan_default_policy() {
  GUARDIAN_CONFIG_DIR="$RUNTIME" \
  GUARDIAN_TMUX_SOCKET="$SOCKET" \
  bash "$WATCHER" --scan-once
}

force_due() {
  local file="$1" now
  now=$(date +%s)
  python3 - "$file" "$((now - 61))" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
reset = sys.argv[2]
lines = path.read_text().splitlines()
path.write_text("\n".join(reset.join(line.split("=", 1)[:1]) + "=" + reset if False else (f"reset_epoch={reset}" if line.startswith("reset_epoch=") else line) for line in lines) + "\n")
PY
}

pane_state() {
  local pane_id="$1" key
  key=$(printf '%s' "$pane_id" | tr -c 'A-Za-z0-9_.-' '_')
  printf '%s/manifest/pane_%s.state\n' "$RUNTIME" "$key"
}

pane_history() {
  local pane_id="$1" key
  key=$(printf '%s' "$pane_id" | tr -c 'A-Za-z0-9_.-' '_')
  printf '%s/manifest/pane_%s.history\n' "$RUNTIME" "$key"
}

# Exact pane resume.
tmux -L "$SOCKET" new-session -d -s safe -n work bash
SAFE_PANE=$(tmux -L "$SOCKET" display-message -p -t safe '#{pane_id}')
tmux -L "$SOCKET" send-keys -t "$SAFE_PANE" "printf '%s\\n' \"You've hit your usage limit. try again in 5 minutes\"" C-m
sleep 0.2
scan >/dev/null
SAFE_STATE=$(pane_state "$SAFE_PANE")
[ -f "$SAFE_STATE" ] || fail "verified Claude-compatible pane did not create state"
force_due "$SAFE_STATE"
scan >/dev/null
sleep 0.2
SAFE_CONTENT=$(tmux -L "$SOCKET" capture-pane -p -t "$SAFE_PANE")
printf '%s' "$SAFE_CONTENT" | grep -q 'NG_RESUMED' || fail "resume prompt was not sent to pinned pane"
[ -f "$(pane_history "$SAFE_PANE")" ] || fail "resume history missing"
[ "$RC" -ne 0 ] || pass "exact pane resumed and history recorded"

# Limit-looking text outside an allowed foreground command must be ignored.
tmux -L "$SOCKET" new-session -d -s ignored -n work zsh
IGNORED_PANE=$(tmux -L "$SOCKET" display-message -p -t ignored '#{pane_id}')
tmux -L "$SOCKET" send-keys -t "$IGNORED_PANE" "printf '%s\\n' \"You've hit your usage limit. try again in 5 minutes\"" C-m
sleep 0.2
scan >/dev/null
[ ! -f "$(pane_state "$IGNORED_PANE")" ] || fail "non-Claude pane created state"
[ "$RC" -ne 0 ] || pass "non-Claude pane ignored"

# If the command changes after detection, automatic input must fail closed.
tmux -L "$SOCKET" new-session -d -s changed -n work bash
CHANGED_PANE=$(tmux -L "$SOCKET" display-message -p -t changed '#{pane_id}')
tmux -L "$SOCKET" send-keys -t "$CHANGED_PANE" "printf '%s\\n' \"You've hit your usage limit. try again in 5 minutes\"" C-m
sleep 0.2
scan >/dev/null
CHANGED_STATE=$(pane_state "$CHANGED_PANE")
[ -f "$CHANGED_STATE" ] || fail "changed-command setup state missing"
force_due "$CHANGED_STATE"
tmux -L "$SOCKET" send-keys -t "$CHANGED_PANE" "exec python3 -c 'import time; time.sleep(20)'" C-m
sleep 0.3
scan >/dev/null
[ ! -f "$(pane_history "$CHANGED_PANE")" ] || fail "resume was sent after foreground command changed"
CHANGED_CONTENT=$(tmux -L "$SOCKET" capture-pane -p -t "$CHANGED_PANE")
printf '%s' "$CHANGED_CONTENT" | grep -q 'SHOULD_NOT_RUN' && fail "blocked prompt appeared in changed pane"
[ "$RC" -ne 0 ] || pass "foreground command change blocks resume"

# Multi-pane session: only the detected pane gets state and input.
tmux -L "$SOCKET" new-session -d -s multi -n work bash
FIRST_PANE=$(tmux -L "$SOCKET" display-message -p -t multi '#{pane_id}')
SECOND_PANE=$(tmux -L "$SOCKET" split-window -d -P -F '#{pane_id}' -t multi bash)
tmux -L "$SOCKET" send-keys -t "$SECOND_PANE" "printf '%s\\n' \"You've hit your usage limit. try again in 5 minutes\"" C-m
sleep 0.2
scan >/dev/null
[ ! -f "$(pane_state "$FIRST_PANE")" ] || fail "clean sibling pane created state"
SECOND_STATE=$(pane_state "$SECOND_PANE")
[ -f "$SECOND_STATE" ] || fail "detected sibling pane state missing"
force_due "$SECOND_STATE"
scan >/dev/null
sleep 0.2
FIRST_CONTENT=$(tmux -L "$SOCKET" capture-pane -p -t "$FIRST_PANE")
SECOND_CONTENT=$(tmux -L "$SOCKET" capture-pane -p -t "$SECOND_PANE")
printf '%s' "$FIRST_CONTENT" | grep -q 'MULTI_RESUMED' && fail "resume leaked into sibling pane"
printf '%s' "$SECOND_CONTENT" | grep -q 'MULTI_RESUMED' || fail "detected pane did not resume"
[ "$RC" -ne 0 ] || pass "multi-pane targeting is exact"

# Parser failure is hold-by-default and only schedules with explicit opt-in.
tmux -L "$SOCKET" new-session -d -s fallback -n work bash
FALLBACK_PANE=$(tmux -L "$SOCKET" display-message -p -t fallback '#{pane_id}')
tmux -L "$SOCKET" send-keys -t "$FALLBACK_PANE" "printf '%s\\n' \"You've hit your usage limit. reset time unavailable\"" C-m
sleep 0.2
GUARDIAN_FALLBACK_MODE=hold scan >/dev/null
[ ! -f "$(pane_state "$FALLBACK_PANE")" ] || fail "default hold mode scheduled fallback"
GUARDIAN_FALLBACK_MODE=resume scan >/dev/null
[ -f "$(pane_state "$FALLBACK_PANE")" ] || fail "opt-in fallback did not create state"
[ "$RC" -ne 0 ] || pass "fallback is fail-closed unless opted in"

# Default process policy must not trust Claude-looking text in process arguments.
tmux -L "$SOCKET" new-session -d -s spoof -n work bash
tmux -L "$SOCKET" send-keys -t spoof "exec python3 -c 'import time; print(\"You have hit your usage limit. try again in 5 minutes\", flush=True); time.sleep(20)' '@anthropic-ai/claude-code'" C-m
SPOOF_PANE=$(tmux -L "$SOCKET" display-message -p -t spoof '#{pane_id}')
sleep 0.3
scan_default_policy >/dev/null
[ ! -f "$(pane_state "$SPOOF_PANE")" ] || fail "Claude-looking argv bypassed executable verification"
[ "$RC" -ne 0 ] || pass "process arguments cannot spoof Claude executable"

# Two concurrent scans may produce only one resume submission.
cat > "$RUNTIME/config/sessions.json" <<JSON
{
  "race": {"resume_prompt": "printf 'x\\n' >> $RUNTIME/race.count"}
}
JSON
tmux -L "$SOCKET" new-session -d -s race -n work bash
RACE_PANE=$(tmux -L "$SOCKET" display-message -p -t race '#{pane_id}')
tmux -L "$SOCKET" send-keys -t "$RACE_PANE" "printf '%s\\n' \"You've hit your usage limit. try again in 5 minutes\"" C-m
sleep 0.2
scan >/dev/null
RACE_STATE=$(pane_state "$RACE_PANE")
[ -f "$RACE_STATE" ] || fail "race setup state missing"
force_due "$RACE_STATE"
scan >/dev/null &
PID_A=$!
scan >/dev/null &
PID_B=$!
wait "$PID_A" || fail "first concurrent scan failed"
wait "$PID_B" || fail "second concurrent scan failed"
sleep 0.2
RACE_COUNT=$(wc -l < "$RUNTIME/race.count" 2>/dev/null | tr -d ' ' || printf '0')
[ "$RACE_COUNT" -eq 1 ] || fail "concurrent scans submitted resume $RACE_COUNT times"
[ "$RC" -ne 0 ] || pass "pane lock prevents duplicate concurrent resume"

exit "$RC"
