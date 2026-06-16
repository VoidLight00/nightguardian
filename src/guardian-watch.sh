#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# NightGuardian v1.0 — ForgeChain SmartResume Daemon
# Claude Code 세션 rate limit 자동 감지 + 재개
# ═══════════════════════════════════════════════════════════════

# set -e removed for resilience — individual errors are handled per-command
set -uo pipefail

CONFIG_DIR="${HOME}/.forgechain-nightguardian"
MANIFEST_DIR="${CONFIG_DIR}/manifest"
LOG_DIR="${CONFIG_DIR}/logs"
LOG_FILE="${LOG_DIR}/guardian.log"
CONFIG_FILE="${CONFIG_DIR}/config/sessions.json"
CHECK_INTERVAL=30

log() {
  local msg="[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
  echo "$msg"  # also to stdout for tmux visibility
}

# ───────────────────────────────────────────────────────────────
# Parse reset time from captured pane content
# e.g. "resets 6:50am (Asia/Seoul)" → epoch
# ───────────────────────────────────────────────────────────────
parse_reset_time() {
  local content="$1"
  local time_str tz_str

  time_str=$(echo "$content" | grep -oE '[0-9]{1,2}:[0-9]{2}[ ]?[ap]m' | head -1)
  [ -z "$time_str" ] && return 1

  # Normalize spacing & uppercase AM/PM (BSD date requires uppercase)
  time_str=$(echo "$time_str" | sed 's/ //g' | tr '[:lower:]' '[:upper:]')

  tz_str=$(echo "$content" | grep -oE 'Asia/[^ )]+' | head -1)
  [ -z "$tz_str" ] && tz_str="Asia/Seoul"

  # Convert to epoch using Python (reliable across macOS/Linux)
  local epoch
  epoch=$(python3 -c "
import time
try:
    t = time.strptime('${time_str}', '%I:%M%p')
    now = time.localtime()
    reset = (now.tm_year, now.tm_mon, now.tm_mday, t.tm_hour, t.tm_min, 0, now.tm_wday, now.tm_yday, now.tm_isdst)
    epoch = int(time.mktime(reset))
    if epoch < time.time():
        epoch += 86400
    print(epoch)
except Exception:
    print('')
" 2>/dev/null)

  if [ -z "$epoch" ] || [ "$epoch" = "" ]; then
    echo ""
    return
  fi

  # If still in the past, add 24h
  local now_epoch
  now_epoch=$(date +%s)
  if [ "$epoch" -lt "$now_epoch" ]; then
    epoch=$((epoch + 86400))
  fi

  echo "$epoch"
}

# ───────────────────────────────────────────────────────────────
# Get resume prompt for a session from config
# ───────────────────────────────────────────────────────────────
get_resume_prompt() {
  local session="$1"
  if [ -f "$CONFIG_FILE" ] && command -v python3 &>/dev/null; then
    python3 -c "
import sys, json
try:
    with open('${CONFIG_FILE}') as f:
        data = json.load(f)
    print(data.get('${session}', {}).get('resume_prompt', 'rate limit 해제됨. 남은 작업 계속 진행해줘.'))
except Exception:
    print('rate limit 해제됨. 남은 작업 계속 진행해줘.')
" 2>/dev/null
  else
    echo "rate limit 해제됨. 남은 작업 계속 진행해줘."
  fi
}

# ───────────────────────────────────────────────────────────────
# Scan a single tmux session
# ───────────────────────────────────────────────────────────────
scan_session() {
  local session="$1"
  local state_file="${MANIFEST_DIR}/session_${session}.state"
  local pane_content

  pane_content=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -60 || true)
  [ -z "$pane_content" ] && return 0

  # ── CASE 1: rate limit DETECTED (not yet handled)
  # ───────────────────────────────────────────────────────────────
  if echo "$pane_content" | grep -q "You've hit your session limit"; then
    # Already tracking?
    if [ -f "$state_file" ]; then
      return 0  # already waiting, nothing to do
    fi

    local reset_epoch
    reset_epoch=$(parse_reset_time "$pane_content")

    if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt 0 ]; then
      local human_reset
      human_reset=$(TZ=Asia/Seoul date -r "$reset_epoch" '+%H:%M %Z' 2>/dev/null || date -d "@$reset_epoch" '+%H:%M %Z' 2>/dev/null || echo "epoch:$reset_epoch")

      echo "rate_limited" > "$state_file"
      echo "$reset_epoch" >> "$state_file"
      echo "$(date +%s)" >> "$state_file"  # detection epoch
      echo "$session" >> "$state_file"

      log "[$session] 🌙 Rate limit DETECTED. Waiting until ${human_reset} (epoch ${reset_epoch})"
    else
      log "[$session] ⚠️ Rate limit message found but could not parse reset time. Manual intervention required."
    fi
    return 0
  fi

  # ── CASE 2: previously rate limited, check if reset time passed
  # ───────────────────────────────────────────────────────────────
  if [ -f "$state_file" ]; then
    local state_phase reset_epoch detection_epoch ses_name
    state_phase=$(sed -n '1p' "$state_file")
    reset_epoch=$(sed -n '2p' "$state_file")
    detection_epoch=$(sed -n '3p' "$state_file")
    ses_name=$(sed -n '4p' "$state_file")

    [ -z "$reset_epoch" ] && { rm -f "$state_file"; return 0; }

    local now_epoch
    now_epoch=$(date +%s)

    # Add 60s buffer after stated reset time for safety
    if [ "$now_epoch" -ge "$((reset_epoch + 60))" ]; then
      log "[$session] ☀️ RESET time passed! Auto-resuming session..."

      local resume_prompt
      resume_prompt=$(get_resume_prompt "$session"
)      # Send the prompt
      tmux send-keys -t "$session" "$resume_prompt" C-m

      # Record completion
      log "[$session] ✅ Resume prompt sent: ${resume_prompt:0:80}..."
      echo "resumed_at_epoch:$now_epoch" > "${MANIFEST_DIR}/session_${session}.history"
      echo "prompt:${resume_prompt}" >> "${MANIFEST_DIR}/session_${session}.history"

      # Clean up state file
      rm -f "$state_file"
    else
      local remaining=$((reset_epoch + 60 - now_epoch))
      local min=$((remaining / 60))
      if [ "$((now_epoch % 300))" -lt "$CHECK_INTERVAL" ]; then
        log "[$session] ⏳ Still waiting... ${min}m until reset"
      fi
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════
# Main loop
# ═══════════════════════════════════════════════════════════════

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "🌙 NightGuardian started. Monitoring all tmux sessions..."
log "   Config:   $CONFIG_FILE"
log "   Manifest: $MANIFEST_DIR"
log "   Log:      $LOG_FILE"
log "   Interval: ${CHECK_INTERVAL}s"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Clean stale state files on startup (older than 12h)
find "$MANIFEST_DIR" -name 'session_*.state' -mmin +720 -delete 2>/dev/null || true

while true; do
  local session_list
  session_list=$(tmux ls 2>/dev/null | cut -d: -f1 || true)

  if [ -z "$session_list" ]; then
    if [ "$(($(date +%s) % 60))" -lt "$CHECK_INTERVAL" ]; then
      log "No active tmux sessions found."
    fi
  else
    for session in $session_list; do
      # Skip the guardian's own session and control sessions.
      # 추가 제외 패턴은 GUARDIAN_SKIP_SESSIONS(공백 구분 glob)로 지정.
      case "$session" in
        forge-night|claude-retry-*|main) continue ;;
      esac
      for _skip in ${GUARDIAN_SKIP_SESSIONS:-}; do
        case "$session" in $_skip) continue 2 ;; esac
      done

      scan_session "$session"
    done
  fi

  sleep "$CHECK_INTERVAL"
done
