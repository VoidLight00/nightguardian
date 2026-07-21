# NightGuardian Requirements (SSoT)

The master gate must verify every requirement with an exit code. Documentation alone is not evidence.

| ID | Requirement | Gate |
|---|---|---|
| R1 | Discover and monitor every tmux pane, not only the active pane of each session. | `safety_gate.sh` |
| R2 | Pin rate-limit state to the exact immutable tmux pane ID that produced it. | `safety_gate.sh`, `tests_gate.sh` |
| R3 | Send keys only when the pinned pane still exists and still runs Claude Code. | `safety_gate.sh`, `tests_gate.sh` |
| R4 | Ignore limit-looking text in shells, editors, logs, and other non-Claude panes. | `tests_gate.sh` |
| R5 | Missing reset time must hold by default; delayed fallback requires explicit opt-in. | `safety_gate.sh`, `tests_gate.sh` |
| R6 | Cooldown, atomic state writes, and pane locks must prevent duplicate resume scheduling, concurrent sends, and stale-banner loops. | `safety_gate.sh`, `tests_gate.sh` |
| R7 | Public users can install, configure, test, update, roll back, autostart, and uninstall from the README. | `docs_gate.sh` |
| R8 | Bash/Python syntax, parser selftests, watcher selftests, and isolated tmux integration tests must pass. | `quality_gate.sh`, `tests_gate.sh` |
| R9 | Obvious secrets must be absent from the publishable tree. | `secrets_gate.sh` |
| R10 | The installed symlinked CLI must resolve the repository root and run the master gate. | `tests_gate.sh` |
