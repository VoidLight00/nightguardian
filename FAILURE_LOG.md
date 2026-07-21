# nightguardian — Failure Log

> 실패할 때마다 1행. 같은 실패 재발 방지용 게이트를 추가하고 여기 기록.

| date | id | symptom | root cause | fix | gate added |
|---|---|---|---|---|---|
| 2026-07-22 | NG-001 | Concurrent watchers sent duplicate resume input | No atomic claim around due pane state | Added pane-scoped `mkdir` lock and atomic state writes | `tests_gate.sh`, `safety_gate.sh` |
| 2026-07-22 | NG-002 | Installed `nightguardian verify` resolved the wrong root | CLI derived paths from the symlink location | Resolve the executable realpath before deriving project root | `tests_gate.sh` |
| 2026-07-22 | NG-003 | Claude-looking process arguments could pass validation | Full command lines were matched as unstructured text | Match executable paths/names from `ps comm` only | `tests_gate.sh`, `safety_gate.sh` |
| 2026-07-22 | NG-004 | An unrelated clock time could be parsed as reset time | Absolute-time parser searched the whole pane | Scope absolute times to reset/retry context | `tests_gate.sh` |
