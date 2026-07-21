#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# NightGuardian launchd keepalive
# 로그인 시(RunAtLoad) + 주기적(StartInterval)으로 데몬 생존을 보장한다.
#
# 핵심: TMUX_TMPDIR 를 설정하지 않는다 → tmux 기본 소켓
# (/tmp/tmux-$UID/default)을 사용 → 사용자의 실제 작업 tmux 서버와
# 동일한 서버를 보게 된다. (이 값을 건드리면 별도 서버가 생겨 감시 실패)
#
# 판정 기준: guardian-watch.sh '프로세스'의 생존(SSoT). tmux 세션만
# 남고 프로세스가 죽은 좀비 상태도 정상 복구한다.
# ═══════════════════════════════════════════════════════════════

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LOG="${HOME}/.forgechain-nightguardian/logs/keepalive.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# 이미 워커 프로세스가 살아 있으면 아무것도 하지 않는다.
if pgrep -f guardian-watch.sh >/dev/null 2>&1; then
  exit 0
fi

# 프로세스가 죽었다 → 잔존 tmux 세션을 정리하고 새로 띄운다.
ts="$(date '+%Y-%m-%d %H:%M:%S')"
tmux kill-session -t forge-night 2>/dev/null || true
echo "[$ts] guardian 프로세스 부재 감지 → 재시작" >> "$LOG"
nightguardian start >> "$LOG" 2>&1
echo "[$ts] 재시작 결과 pid: $(pgrep -f guardian-watch.sh 2>/dev/null || echo NONE)" >> "$LOG"
exit 0
