#!/usr/bin/env bash
set -u
ROOT="${1:-$(pwd)}"
RC=0

for file in "$ROOT/src/guardian-watch.sh" "$ROOT/src/nightguardian" "$ROOT/src/keepalive.sh" "$ROOT/tests/integration_tmux.sh"; do
  if ! bash -n "$file"; then
    echo "FAIL[quality]: bash syntax error in $file"
    RC=1
  fi
done

if ! python3 -m py_compile "$ROOT/src/parse_reset.py"; then
  echo "FAIL[quality]: parse_reset.py does not compile"
  RC=1
fi

if [ "$RC" -eq 0 ]; then
  echo "PASS[quality]: shell and Python syntax checks passed"
fi
exit "$RC"
