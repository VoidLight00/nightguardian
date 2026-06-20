# Changelog

[Keep a Changelog](https://keepachangelog.com/) / [SemVer](https://semver.org/).

## [1.1.0] - 2026-06-17
### Fixed
- **리밋 리셋 시각 파싱이 "5pm"처럼 분(:MM) 없는 메시지에서 실패하던 버그.** 기존 정규식
  `[0-9]{1,2}:[0-9]{2}[ ]?[ap]m` 은 `시:분` 형식만 매칭해, Claude 가 정시만 알려줄 때
  파싱 실패 → 자동 재개가 영구 중단("Manual intervention required")되었다.
### Added
- **`src/parse_reset.py`** — 견고한 리셋 시각 파서. 상대시간(`in 2h 15m`, `try again in 30 seconds`),
  12h(분 유무), 24h(`14:30`), `midnight`/`noon`, 타임존 변환(Asia/Seoul·UTC·PST·KST 등),
  `tomorrow` 처리. 21개 형식 셀프테스트 내장(`--selftest`).
- **never-give-up fallback** — 시각 파싱 실패해도 영구 포기하지 않고 `GUARDIAN_FALLBACK_WAIT`
  (기본 1h) 뒤 재개 시도, 여전히 막혀 있으면 자동 재감지→재예약(자가치유).
- **감지 정규식 확장** — `GUARDIAN_DETECT_RE` 로 session/usage/N-hour/`rate_limit_error` 변형 포괄(override 가능).
- `make test` — 파서 셀프테스트 + 셸 구문검사 회귀 게이트.

## [1.0.0] - 2026-06-16
### Added
- NightGuardian v1.0 — ForgeChain SmartResume Daemon
