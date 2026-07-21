# Changelog

[Keep a Changelog](https://keepachangelog.com/) / [SemVer](https://semver.org/).

## [Unreleased]
### Added
- Exact pane-ID tracking across every tmux window and pane.
- Foreground Claude process verification before detection and immediately before key injection.
- Isolated tmux integration coverage for exact targeting, command changes, non-Claude panes, multi-pane sessions, and fallback policy.
- Fail-closed `gates/verify_nightguardian.sh` master QA gate and GitHub Actions verification.
- Public install, update, rollback, autostart, and safety-model documentation.

### Changed
- Reset-time parsing failure now holds by default. Delayed fallback requires `GUARDIAN_FALLBACK_MODE=resume`.
- State, cooldown, and history files are pane-scoped instead of session-scoped.
- Session configuration keys are documented as tmux session names.

### Fixed
- Automatic resume can no longer drift to whichever pane is active when the reset time arrives.
- Limit-looking text in shells, logs, and editors no longer schedules automatic input.
- Existing detached `claude-retry-*` reaping is retained while active Claude and attached sessions remain protected.

## [1.1.0] - 2026-06-17
### Fixed
- **리밋 리셋 시각 파싱이 "5pm"처럼 분(:MM) 없는 메시지에서 실패하던 버그.** 기존 정규식
  `[0-9]{1,2}:[0-9]{2}[ ]?[ap]m` 은 `시:분` 형식만 매칭해, Claude 가 정시만 알려줄 때
  파싱 실패 → 자동 재개가 영구 중단("Manual intervention required")되었다.
### Added
- **`src/parse_reset.py`** — 견고한 리셋 시각 파서. 상대시간(`in 2h 15m`, `try again in 30 seconds`),
  12h(분 유무), 24h(`14:30`), `midnight`/`noon`, 타임존 변환(Asia/Seoul·UTC·PST·KST 등),
  `tomorrow` 처리. 21개 형식 셀프테스트 내장(`--selftest`).
- **never-give-up fallback (legacy)** — 시각 파싱 실패 시 `GUARDIAN_FALLBACK_WAIT`
  (기본 30분) 뒤 재개를 예약했다. Unreleased 버전부터는 안전을 위해 기본 `hold`로 변경되며,
  기존 동작은 `GUARDIAN_FALLBACK_MODE=resume`으로 명시적으로 활성화한다.
- **감지 정규식 확장** — `GUARDIAN_DETECT_RE` 로 session/usage/N-hour/`rate_limit_error` 변형 포괄(override 가능).
- `make test` — 파서 셀프테스트 + 셸 구문검사 회귀 게이트.

## [1.0.0] - 2026-06-16
### Added
- NightGuardian v1.0 — ForgeChain SmartResume Daemon
