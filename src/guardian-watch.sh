#!/bin/bash
# NightGuardian — Claude Code rate-limit watcher and safe tmux resume daemon.
# Automatic input is fail-closed: it is sent only to the exact pane that was
# detected and only while that pane still runs Claude Code.

set -uo pipefail

CONFIG_DIR="${GUARDIAN_CONFIG_DIR:-${HOME}/.forgechain-nightguardian}"
MANIFEST_DIR="${CONFIG_DIR}/manifest"
LOG_DIR="${CONFIG_DIR}/logs"
LOG_FILE="${LOG_DIR}/guardian.log"
CONFIG_FILE="${CONFIG_DIR}/config/sessions.json"
CHECK_INTERVAL="${GUARDIAN_CHECK_INTERVAL:-30}"
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PARSE_PY="${SELF_DIR}/parse_reset.py"

# Parser failure is fail-closed by default. Set GUARDIAN_FALLBACK_MODE=resume
# to opt into a delayed retry when Claude does not expose a reset time.
GUARDIAN_FALLBACK_MODE="${GUARDIAN_FALLBACK_MODE:-hold}"
GUARDIAN_FALLBACK_WAIT="${GUARDIAN_FALLBACK_WAIT:-1800}"
GUARDIAN_RESUME_COOLDOWN="${GUARDIAN_RESUME_COOLDOWN:-600}"
GUARDIAN_REAP="${GUARDIAN_REAP:-1}"
GUARDIAN_REAP_IDLE="${GUARDIAN_REAP_IDLE:-1800}"
GUARDIAN_ALLOWED_COMMAND_RE="${GUARDIAN_ALLOWED_COMMAND_RE:-(^|/)(claude|claude\.exe)$}"
GUARDIAN_DETECT_RE="${GUARDIAN_DETECT_RE:-(you.?ve (hit|reached) your (session|usage|weekly|[0-9]+[ -]?hour) limit|(claude )?(session|usage|weekly|[0-9]+[ -]?hour) limit reached|rate.?limit_error|rate.?limit exceeded)}"
GUARDIAN_DIALOG_RE="${GUARDIAN_DIALOG_RE:-❯ +[0-9]+\. (Yes|No|Allow|Proceed)|^ *[0-9]+\. (Yes|No)\b|Do you want to .+\?}"
GUARDIAN_FEEDBACK_RE="${GUARDIAN_FEEDBACK_RE:-How is Claude doing this session|[0-9]+: (Bad|Fine|Good|Dismiss)}"

mkdir -p "$MANIFEST_DIR" "$LOG_DIR"

log() {
  local msg="[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$msg" >> "$LOG_FILE"
  printf '%s\n' "$msg"
}

tmux_run() {
  if [ -n "${GUARDIAN_TMUX_SOCKET:-}" ]; then
    tmux -L "$GUARDIAN_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

parse_reset_time() {
  local content="$1"
  [ -f "$PARSE_PY" ] || { printf '\n'; return; }
  printf '%s' "$content" | python3 "$PARSE_PY" 2>/dev/null
}

safe_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

state_path() {
  printf '%s/pane_%s.state\n' "$MANIFEST_DIR" "$(safe_id "$1")"
}

cooldown_path() {
  printf '%s/pane_%s.cooldown\n' "$MANIFEST_DIR" "$(safe_id "$1")"
}

history_path() {
  printf '%s/pane_%s.history\n' "$MANIFEST_DIR" "$(safe_id "$1")"
}

state_value() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

write_state() {
  local file="$1" phase="$2" reset_epoch="$3" detected_epoch="$4"
  local pane_id="$5" session="$6" window_index="$7" pane_index="$8"
  {
    printf 'phase=%s\n' "$phase"
    printf 'reset_epoch=%s\n' "$reset_epoch"
    printf 'detected_epoch=%s\n' "$detected_epoch"
    printf 'pane_id=%s\n' "$pane_id"
    printf 'session=%s\n' "$session"
    printf 'window_index=%s\n' "$window_index"
    printf 'pane_index=%s\n' "$pane_index"
  } > "$file"
}

get_resume_prompt() {
  local session="$1"
  if [ -f "$CONFIG_FILE" ] && command -v python3 >/dev/null 2>&1; then
    CONFIG_FILE="$CONFIG_FILE" SESSION_NAME="$session" python3 - <<'PY' 2>/dev/null
import json
import os

fallback = "Continue from the interrupted point. Review the current state first, then complete the remaining work."
try:
    with open(os.environ["CONFIG_FILE"], encoding="utf-8") as handle:
        data = json.load(handle)
    print(data.get(os.environ["SESSION_NAME"], {}).get("resume_prompt", fallback))
except Exception:
    print(fallback)
PY
  else
    printf '%s\n' "Continue from the interrupted point. Review the current state first, then complete the remaining work."
  fi
}

pane_exists() {
  tmux_run display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

pane_process_snapshot() {
  local pane_id="$1" pane_pid pid frontier next children child depth executable
  pane_pid=$(tmux_run display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null) || return 1
  frontier="$pane_pid"
  depth=0
  while [ -n "$frontier" ] && [ "$depth" -lt 5 ]; do
    next=""
    for pid in $frontier; do
      executable=$(ps -p "$pid" -o comm= 2>/dev/null || true)
      [ -n "$executable" ] && printf '%s\n' "$executable"
      children=$(pgrep -P "$pid" 2>/dev/null || true)
      for child in $children; do
        next="$next $child"
      done
    done
    frontier="$next"
    depth=$((depth + 1))
  done
}

pane_runs_claude() {
  local snapshot
  pane_exists "$1" || return 1
  snapshot=$(pane_process_snapshot "$1") || return 1
  printf '%s\n' "$snapshot" | grep -qiE "$GUARDIAN_ALLOWED_COMMAND_RE"
}

capture_pane() {
  tmux_run capture-pane -t "$1" -p 2>/dev/null | tail -80
}

is_in_cooldown() {
  local file="$1" now_epoch="$2" cd_until
  [ -f "$file" ] || return 1
  cd_until=$(sed -n '1p' "$file")
  if [ -n "$cd_until" ] && [ "$now_epoch" -lt "$cd_until" ] 2>/dev/null; then
    return 0
  fi
  rm -f "$file"
  return 1
}

acquire_pane_lock() {
  local pane_id="$1" lock_dir
  lock_dir="${MANIFEST_DIR}/pane_$(safe_id "$pane_id").lock"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$lock_dir"
    return 0
  fi
  return 1
}

atomic_write_state() {
  local file="$1" phase="$2" reset_epoch="$3" detected_epoch="$4"
  local pane_id="$5" session="$6" window_index="$7" pane_index="$8" tmp
  tmp="${file}.tmp.$$"
  write_state "$tmp" "$phase" "$reset_epoch" "$detected_epoch" "$pane_id" "$session" "$window_index" "$pane_index" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$file"
}

resume_pane() {
  local pane_id="$1" session="$2" pane_content="$3" state_file="$4"
  local cooldown_file now_epoch resume_prompt lock_dir
  lock_dir=$(acquire_pane_lock "$pane_id") || return 0
  cooldown_file=$(cooldown_path "$pane_id")
  now_epoch=$(date +%s)

  if [ ! -f "$state_file" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi

  if ! pane_runs_claude "$pane_id"; then
    log "[$session $pane_id] BLOCKED: target pane no longer runs Claude Code; no keys sent."
    rm -f "$state_file"
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi

  resume_prompt=$(get_resume_prompt "$session")
  if printf '%s' "$pane_content" | grep -qiE "$GUARDIAN_DIALOG_RE|$GUARDIAN_FEEDBACK_RE"; then
    log "[$session $pane_id] Closing Claude overlay before resume."
    tmux_run send-keys -t "$pane_id" Escape 2>/dev/null || {
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    }
    sleep 1
    tmux_run send-keys -t "$pane_id" Escape 2>/dev/null || {
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    }
    sleep 1
    pane_runs_claude "$pane_id" || {
      log "[$session $pane_id] BLOCKED: target changed after overlay close; no prompt sent."
      rm -f "$state_file"
      rmdir "$lock_dir" 2>/dev/null || true
      return 0
    }
  fi

  log "[$session $pane_id] RESET passed; sending resume to verified Claude pane."
  tmux_run send-keys -t "$pane_id" "$resume_prompt" 2>/dev/null || {
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  }
  sleep 1
  tmux_run send-keys -t "$pane_id" C-m 2>/dev/null || {
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  }
  {
    printf 'resumed_at_epoch=%s\n' "$now_epoch"
    printf 'session=%s\n' "$session"
    printf 'pane_id=%s\n' "$pane_id"
    printf 'prompt=%s\n' "$resume_prompt"
  } > "$(history_path "$pane_id")"
  printf '%s\n' "$((now_epoch + GUARDIAN_RESUME_COOLDOWN))" > "$cooldown_file"
  rm -f "$state_file"
  rmdir "$lock_dir" 2>/dev/null || true
  log "[$session $pane_id] Resume prompt sent."
}

scan_pane() {
  local pane_id="$1" session="$2" window_index="$3" pane_index="$4"
  local state_file cooldown_file pane_content now_epoch reset_epoch stored_pane stored_session
  state_file=$(state_path "$pane_id")
  cooldown_file=$(cooldown_path "$pane_id")
  pane_content=$(capture_pane "$pane_id" || true)
  [ -n "$pane_content" ] || return 0
  now_epoch=$(date +%s)

  if [ -f "$state_file" ]; then
    stored_pane=$(state_value "$state_file" pane_id)
    stored_session=$(state_value "$state_file" session)
    reset_epoch=$(state_value "$state_file" reset_epoch)
    if [ "$stored_pane" != "$pane_id" ] || [ "$stored_session" != "$session" ] || [ -z "$reset_epoch" ]; then
      log "[$session $pane_id] BLOCKED: invalid or stale state; state removed."
      rm -f "$state_file"
      return 0
    fi
    if ! pane_exists "$pane_id"; then
      log "[$session $pane_id] BLOCKED: target pane disappeared; state removed."
      rm -f "$state_file"
      return 0
    fi
    if [ "$now_epoch" -ge "$((reset_epoch + 60))" ]; then
      resume_pane "$pane_id" "$session" "$pane_content" "$state_file"
    elif [ "$((now_epoch % 300))" -lt "$CHECK_INTERVAL" ]; then
      log "[$session $pane_id] Waiting $(((reset_epoch + 60 - now_epoch) / 60))m for reset."
    fi
    return 0
  fi

  is_in_cooldown "$cooldown_file" "$now_epoch" && return 0
  printf '%s' "$pane_content" | grep -qiE "$GUARDIAN_DETECT_RE" || return 0

  if ! pane_runs_claude "$pane_id"; then
    log "[$session $pane_id] IGNORED: limit text found outside a verified Claude pane."
    return 0
  fi

  reset_epoch=$(parse_reset_time "$pane_content")
  if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt 0 ] 2>/dev/null; then
    atomic_write_state "$state_file" rate_limited "$reset_epoch" "$now_epoch" "$pane_id" "$session" "$window_index" "$pane_index"
    log "[$session $pane_id] Rate limit detected; exact pane pinned until epoch $reset_epoch."
  elif [ "$GUARDIAN_FALLBACK_MODE" = "resume" ]; then
    reset_epoch=$((now_epoch + GUARDIAN_FALLBACK_WAIT))
    atomic_write_state "$state_file" rate_limited_fallback "$reset_epoch" "$now_epoch" "$pane_id" "$session" "$window_index" "$pane_index"
    log "[$session $pane_id] Reset time missing; opt-in fallback scheduled in ${GUARDIAN_FALLBACK_WAIT}s."
  else
    log "[$session $pane_id] HOLD: reset time missing; automatic fallback is disabled."
  fi
}

reap_transient_session() {
  local session="$1" attached commands activity now_epoch idle
  attached=$(tmux_run display-message -p -t "$session" '#{session_attached}' 2>/dev/null || printf '0')
  [ "$attached" = "0" ] || return 0
  commands=$(tmux_run list-panes -t "$session" -F '#{pane_current_command}' 2>/dev/null | tr '\n' ' ')
  case "$commands" in *node*|*claude*) return 0 ;; esac
  activity=$(tmux_run display-message -p -t "$session" '#{session_activity}' 2>/dev/null || printf '0')
  now_epoch=$(date +%s)
  [ "$activity" -gt 0 ] 2>/dev/null || return 0
  idle=$((now_epoch - activity))
  [ "$idle" -ge "$GUARDIAN_REAP_IDLE" ] || return 0
  tmux_run kill-session -t "$session" 2>/dev/null && \
    log "[$session] Reaped detached transient session after $((idle / 60))m idle."
}

scan_all_panes() {
  local row session window_index pane_index pane_id
  tmux_run list-panes -a -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_id}' 2>/dev/null |
  while IFS='|' read -r session window_index pane_index pane_id; do
    [ -n "$pane_id" ] || continue
    case "$session" in
      forge-night|main) continue ;;
      claude-retry-*|__cmux_restore_*)
        [ "$GUARDIAN_REAP" = "1" ] && reap_transient_session "$session"
        continue
        ;;
    esac
    for _skip in ${GUARDIAN_SKIP_SESSIONS:-}; do
      case "$session" in $_skip) continue 2 ;; esac
    done
    scan_pane "$pane_id" "$session" "$window_index" "$pane_index"
  done
}

run_selftest() {
  local fails=0 got
  check_match() {
    local label="$1" text="$2" expected="$3" regex="$4"
    if printf '%s' "$text" | grep -qiE "$regex"; then got=Y; else got=N; fi
    if [ "$got" = "$expected" ]; then
      printf '  PASS  %s\n' "$label"
    else
      printf '  FAIL  %s (got=%s want=%s)\n' "$label" "$got" "$expected"
      fails=$((fails + 1))
    fi
  }
  check_match "real usage limit" "You've hit your usage limit. resets 3pm" Y "$GUARDIAN_DETECT_RE"
  check_match "real weekly limit" "You've reached your weekly limit" Y "$GUARDIAN_DETECT_RE"
  check_match "API rate_limit_error" '{"type":"rate_limit_error"}' Y "$GUARDIAN_DETECT_RE"
  check_match "self prompt" "rate limit 해제됨. 남은 작업 계속 진행해줘." N "$GUARDIAN_DETECT_RE"
  check_match "new default prompt" "Continue from the interrupted point." N "$GUARDIAN_DETECT_RE"
  check_match "approaching warning" "Approaching usage limit · resets 3pm" N "$GUARDIAN_DETECT_RE"
  check_match "real dialog" "❯ 1. Yes" Y "$GUARDIAN_DIALOG_RE"
  check_match "permission status" "bypass permissions on (shift+tab to cycle)" N "$GUARDIAN_DIALOG_RE"
  check_match "feedback overlay" "How is Claude doing this session?" Y "$GUARDIAN_FEEDBACK_RE"
  if [ "$fails" -eq 0 ]; then
    printf 'SELFTEST: ALL GREEN\n'
    return 0
  fi
  printf 'SELFTEST: %s FAILED\n' "$fails"
  return 1
}

cleanup_legacy_state() {
  local legacy
  for legacy in "$MANIFEST_DIR"/session_*.state "$MANIFEST_DIR"/session_*.cooldown; do
    [ -e "$legacy" ] || continue
    log "Removing legacy session-scoped state: $(basename "$legacy")"
    rm -f "$legacy"
  done
  find "$MANIFEST_DIR" -name 'pane_*.state' -mmin +720 -delete 2>/dev/null || true
}

case "${1:-}" in
  --selftest)
    run_selftest
    exit $?
    ;;
  --scan-once)
    scan_all_panes
    exit $?
    ;;
esac

cleanup_legacy_state
log "NightGuardian started. Monitoring verified Claude panes every ${CHECK_INTERVAL}s."
while true; do
  scan_all_panes
  sleep "$CHECK_INTERVAL"
done
