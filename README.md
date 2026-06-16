# 🌙 NightGuardian

ForgeChain SmartResume Daemon — Claude Code 세션의 rate limit 자동 감지 및 작업 재개 데몬.

## 기능

- tmux 세션 실시간 감시 (30초 간격)
- "You've hit your session limit" 메시지 자동 감지
- reset 시간 파싱 (`resets 6:50am`) → epoch 변환
- reset 시간까지 자동 대기 후 각 세션에 resume 프롬프트 전송
- 세션별 커스텀 재개 프롬프트 설정 지원

## 설치

```bash
# 1. 클론/다운로드 후
make install

# 또는 수동
mkdir -p ~/.forgechain-nightguardian
ln -s "$(pwd)/src" ~/.forgechain-nightguardian/bin
ln -s "$(pwd)/config" ~/.forgechain-nightguardian/config
mkdir -p ~/.forgechain-nightguardian/{manifest,logs}

# 2. PATH 추가
export PATH="${HOME}/.local/bin:${PATH}"

# 3. 데몬 시작
nightguardian start
```

## 사용

```bash
nightguardian status      # 상태 확인
nightguardian logs        # 로그 tail
nightguardian simulate    # 테스트 시뮬레이션
nightguardian stop        # 중지
nightguardian start       # 재시작
```

## 세션별 재개 프롬프트 설정

`config/sessions.json`을 수정합니다.

```json
{
  "1": {
    "name": "예시 세션",
    "resume_prompt": "중단된 지점부터 작업을 이어서 진행해줘."
  }
}
```

키는 tmux 창 번호, `name`/`resume_prompt`는 자유롭게 채웁니다.

## 런타임 구조

```
~/.forgechain-nightguardian/
├── bin      -> <project>/src          (symlink)
├── config   -> <project>/config       (symlink)
├── manifest/   (rate-limit state 파일)
└── logs/       (daemon 로그)
```

## 라이선스

MIT
