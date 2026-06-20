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

# 이 스크립트가 있는 디렉토리(심볼릭 링크 통해 src/) → parse_reset.py 위치.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PARSE_PY="${SELF_DIR}/parse_reset.py"
# 시각 파싱 실패 시 영구 포기 금지: 이 시간(초) 뒤 일단 재개 시도, 여전히 막혀 있으면 자동 재감지→재시도.
GUARDIAN_FALLBACK_WAIT="${GUARDIAN_FALLBACK_WAIT:-1800}"
# 재개(resume) 직후 쿨다운(초): 화면에 남은 동일 리밋 배너 / resume 프롬프트 잔상을
# 다시 '새 리밋'으로 오인해 무한 루프 도는 것을 차단한다. 쿨다운이 끝나도 여전히
# 리밋이면 자연히 재감지→재개되므로(=루프백) 진짜 막힘은 계속 자동 복구된다.
GUARDIAN_RESUME_COOLDOWN="${GUARDIAN_RESUME_COOLDOWN:-600}"
# 리밋 감지 정규식. 실제 'limit hit/reached' 하드스톱만 매칭한다.
# ⚠️ 과거 버그: 느슨한 'rate.?limit' 가 가디언 자신의 resume 프롬프트("rate limit 해제됨")를
#    재감지해 무한 self-trigger 루프를 만들었다. 따라서 bare 'rate limit' 은 매칭하지 않고,
#    'rate_limit_error' / 'rate limit exceeded' API 에러 형태만 매칭한다.
#    'approaching ... limit'(경고 단계)도 제외 — 실제 차단됐을 때만 재개해야 하므로.
GUARDIAN_DETECT_RE="${GUARDIAN_DETECT_RE:-(you.?ve (hit|reached) your (session|usage|weekly|[0-9]+[ -]?hour) limit|(claude )?(session|usage|weekly|[0-9]+[ -]?hour) limit reached|rate.?limit_error|rate.?limit exceeded)}"
# 차단 다이얼로그(숫자 선택지) 감지. resume 자유텍스트 주입이 메뉴를 망가뜨리므로
# "먼저 Escape 로 닫고 resume" 판단에 사용한다(과거: 영구 보류 → 5am 자동 이어가기 실패의 원인).
# ⚠️ '(shift+tab' 은 평상시 권한 상태바에도 나오므로 절대 신호로 쓰지 않는다(오탐).
GUARDIAN_DIALOG_RE="${GUARDIAN_DIALOG_RE:-❯ +[0-9]+\. (Yes|No|Allow|Proceed)|^ *[0-9]+\. (Yes|No)\b|Do you want to .+\?}"
# 피드백/선택 오버레이 감지. "How is Claude doing this session?" 같은 비파괴적 프롬프트.
# 이게 떠 있으면 resume 가 입력창에 안 들어가므로, 보류가 아니라 Escape 로 닫고 진행한다.
GUARDIAN_FEEDBACK_RE="${GUARDIAN_FEEDBACK_RE:-How is Claude doing this session|[0-9]+: (Bad|Fine|Good|Dismiss)}"

log() {
  local msg="[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
  echo "$msg"  # also to stdout for tmux visibility
}

# ───────────────────────────────────────────────────────────────
# Parse reset time from captured pane content -> epoch(stdout). 못 찾으면 빈 출력.
# 모든 형식 처리는 parse_reset.py 에 위임:
#   상대시간(in 2h 15m / try again in 30 seconds), 12h(분 유무), 24h(14:30),
#   midnight/noon, 타임존(Asia/Seoul·UTC·PST·KST 등) 변환, tomorrow.
# ───────────────────────────────────────────────────────────────
parse_reset_time() {
  local content="$1"
  [ -f "$PARSE_PY" ] || { echo ""; return; }
  printf '%s' "$content" | python3 "$PARSE_PY" 2>/dev/null
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
    print(data.get('${session}', {}).get('resume_prompt', '이어서 진행해줘 — 중단된 지점부터 남은 작업 계속.'))
except Exception:
    print('이어서 진행해줘 — 중단된 지점부터 남은 작업 계속.')
" 2>/dev/null
  else
    echo "이어서 진행해줘 — 중단된 지점부터 남은 작업 계속."
  fi
}

# ───────────────────────────────────────────────────────────────
# Scan a single tmux session
# ───────────────────────────────────────────────────────────────
scan_session() {
  local session="$1"
  local state_file="${MANIFEST_DIR}/session_${session}.state"
  local cooldown_file="${MANIFEST_DIR}/session_${session}.cooldown"
  local pane_content

  pane_content=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -80 || true)
  [ -z "$pane_content" ] && return 0

  local now_epoch
  now_epoch=$(date +%s)

  # ── CASE 2 우선: 이미 대기 중이면 reset 도래 여부만 본다.
  #    (state 가 있는 동안에는 감지를 돌리지 않아 중복 트리거가 원천적으로 불가능)
  # ───────────────────────────────────────────────────────────────
  if [ -f "$state_file" ]; then
    local reset_epoch
    reset_epoch=$(sed -n '2p' "$state_file")
    [ -z "$reset_epoch" ] && { rm -f "$state_file"; return 0; }

    if [ "$now_epoch" -ge "$((reset_epoch + 60))" ]; then
      local resume_prompt
      resume_prompt=$(get_resume_prompt "$session")

      # ── 리셋 도래 → 무조건 전진. 영구 보류 절대 금지(=과거 5am 실패 원인).
      # 화면에 오버레이(피드백 프롬프트/확인 다이얼로그)가 떠 있으면 자유 텍스트
      # resume 가 메뉴를 망가뜨리므로, 먼저 Escape 로 닫는다.
      #   - Escape = 취소/No = 안전 기본값(파괴적 동작 미수행).
      #   - 1차 Escape: 오버레이 닫기, 2차 Escape: 입력창 잔여 텍스트 비우기.
      if printf '%s' "$pane_content" | grep -qiE "$GUARDIAN_DIALOG_RE|$GUARDIAN_FEEDBACK_RE"; then
        log "[$session] 🧹 오버레이(다이얼로그/피드백) 감지 → Escape 로 닫고 resume 진행."
        tmux send-keys -t "$session" Escape 2>/dev/null || true
        sleep 1
        tmux send-keys -t "$session" Escape 2>/dev/null || true
        sleep 1
      fi

      log "[$session] ☀️ RESET time passed! Auto-resuming session..."
      # 텍스트 주입 → 짧은 대기 → Enter 분리 전송(레이스로 Enter 가 먼저 가는 것 방지).
      tmux send-keys -t "$session" "$resume_prompt" 2>/dev/null || true
      sleep 1
      tmux send-keys -t "$session" C-m 2>/dev/null || true
      log "[$session] ✅ Resume prompt sent: ${resume_prompt:0:60}..."
      echo "resumed_at_epoch:$now_epoch" > "${MANIFEST_DIR}/session_${session}.history"
      echo "prompt:${resume_prompt}" >> "${MANIFEST_DIR}/session_${session}.history"

      # 재개 직후 쿨다운 설정 → 잔존 배너/프롬프트 잔상 재감지로 인한 무한 루프 차단.
      echo "$((now_epoch + GUARDIAN_RESUME_COOLDOWN))" > "$cooldown_file"
      rm -f "$state_file"
    else
      local remaining=$((reset_epoch + 60 - now_epoch))
      local min=$((remaining / 60))
      if [ "$((now_epoch % 300))" -lt "$CHECK_INTERVAL" ]; then
        log "[$session] ⏳ Still waiting... ${min}m until reset"
      fi
    fi
    return 0
  fi

  # ── 쿨다운 가드: 방금 resume 한 세션은 일정 시간 재감지를 건너뛴다.
  #    쿨다운 만료 후에도 여전히 리밋이면 아래 CASE 1 에서 다시 감지→재개(=루프백).
  # ───────────────────────────────────────────────────────────────
  if [ -f "$cooldown_file" ]; then
    local cd_until
    cd_until=$(sed -n '1p' "$cooldown_file")
    if [ -n "$cd_until" ] && [ "$now_epoch" -lt "$cd_until" ]; then
      return 0
    fi
    rm -f "$cooldown_file"
  fi

  # ── CASE 1: 신규 리밋 감지 (state 없음 + 쿨다운 아님)
  # ───────────────────────────────────────────────────────────────
  printf '%s' "$pane_content" | grep -qiE "$GUARDIAN_DETECT_RE" || return 0

  local reset_epoch
  reset_epoch=$(parse_reset_time "$pane_content")

  if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt 0 ]; then
    local human_reset
    human_reset=$(TZ=Asia/Seoul date -r "$reset_epoch" '+%H:%M %Z' 2>/dev/null || date -d "@$reset_epoch" '+%H:%M %Z' 2>/dev/null || echo "epoch:$reset_epoch")
    {
      echo "rate_limited"
      echo "$reset_epoch"
      echo "$now_epoch"
      echo "$session"
    } > "$state_file"
    log "[$session] 🌙 Rate limit DETECTED. Waiting until ${human_reset} (epoch ${reset_epoch})"
  else
    # 파싱 실패라도 영구 포기 금지: 보수적 fallback 후 재개 시도.
    local fb_epoch=$(( now_epoch + GUARDIAN_FALLBACK_WAIT ))
    local fb_min=$(( GUARDIAN_FALLBACK_WAIT / 60 ))
    {
      echo "rate_limited_fallback"
      echo "$fb_epoch"
      echo "$now_epoch"
      echo "$session"
    } > "$state_file"
    log "[$session] ⚠️ reset 시각 파싱 실패 → ${fb_min}분 뒤 자동 재개 예약(fallback). 메시지 형식 점검 권장."
  fi
}

# ═══════════════════════════════════════════════════════════════
# Selftest — 무한 self-trigger 루프 회귀 방지(HARD).
#   감지 정규식이 가디언 자신의 resume 프롬프트를 다시 잡으면 안 되고,
#   다이얼로그 가드가 평상시 권한 상태바를 오탐하면 안 된다.
# 사용: guardian-watch.sh --selftest  (exit 0 = green, 1 = 회귀 발생)
# ═══════════════════════════════════════════════════════════════
run_selftest() {
  local fails=0
  _m(){ # label text expect(Y/N) regex
    local g; if printf '%s' "$2" | grep -qiE "$4"; then g=Y; else g=N; fi
    if [ "$g" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got=$g want=$3)"; fails=$((fails+1)); fi
  }
  echo "[detect regex] 진짜 리밋만 매칭, 자기 프롬프트는 비매칭:"
  _m "real: You've hit your usage limit"        "You've hit your usage limit. resets 3pm (Asia/Seoul)" Y "$GUARDIAN_DETECT_RE"
  _m "real: 5-hour limit reached"               "5-hour limit reached"                                 Y "$GUARDIAN_DETECT_RE"
  _m "real: Claude usage limit reached"         "Claude usage limit reached"                           Y "$GUARDIAN_DETECT_RE"
  _m "real: weekly limit"                       "You've reached your weekly limit"                     Y "$GUARDIAN_DETECT_RE"
  _m "real: rate_limit_error"                   '{"type":"rate_limit_error"}'                          Y "$GUARDIAN_DETECT_RE"
  _m "BUG GUARD: 'rate limit 해제됨' 비매칭"     "rate limit 해제됨. 남은 작업 계속 진행해줘."           N "$GUARDIAN_DETECT_RE"
  _m "new resume prompt 비매칭"                 "이어서 진행해줘 — 중단된 지점부터 남은 작업 계속."     N "$GUARDIAN_DETECT_RE"
  _m "status bar 비매칭"                        "5시간: 34% (44분) │ 7일: 전체 6%"                     N "$GUARDIAN_DETECT_RE"
  _m "approaching(경고) 비매칭"                 "Approaching usage limit · resets 3pm"                 N "$GUARDIAN_DETECT_RE"
  echo "[dialog regex] 진짜 다이얼로그만 매칭, 권한 상태바는 비매칭:"
  _m "real: ❯ 1. Yes"                           "❯ 1. Yes"                                             Y "$GUARDIAN_DIALOG_RE"
  _m "real: Do you want to ...?"                "Do you want to create STATE.md?"                      Y "$GUARDIAN_DIALOG_RE"
  _m "BUG GUARD: bypass permissions 비매칭"     "bypass permissions on (shift+tab to cycle)"           N "$GUARDIAN_DIALOG_RE"
  _m "idle 프롬프트 비매칭"                     "❯ "                                                   N "$GUARDIAN_DIALOG_RE"
  echo "[feedback regex] 피드백 오버레이 매칭(→Escape 후 resume, 보류 금지):"
  _m "real: How is Claude doing"                "How is Claude doing this session? (optional)"          Y "$GUARDIAN_FEEDBACK_RE"
  _m "real: 1: Bad 2: Fine 3: Good"             "  1: Bad    2: Fine   3: Good   0: Dismiss"            Y "$GUARDIAN_FEEDBACK_RE"
  _m "status bar 비매칭(피드백)"                "5시간: 34% (44분) │ 7일: 전체 6%"                     N "$GUARDIAN_FEEDBACK_RE"
  _m "resume prompt 비매칭(피드백)"             "이어서 진행해줘 — 중단된 지점부터 남은 작업 계속."     N "$GUARDIAN_FEEDBACK_RE"
  echo "──────────────────────────────"
  if [ "$fails" -eq 0 ]; then echo "SELFTEST: ALL GREEN"; return 0
  else echo "SELFTEST: ${fails} FAILED"; return 1; fi
}

if [ "${1:-}" = "--selftest" ]; then
  run_selftest
  exit $?
fi

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
  # NOTE: 'local' 은 함수 밖에서 에러를 내므로 사용 금지(매 스캔 stderr 오염).
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
