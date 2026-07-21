#!/usr/bin/env bash
set -u
ROOT="${1:-$(pwd)}"

if ! make -C "$ROOT" test; then
  echo "FAIL[tests]: make test failed"
  exit 1
fi

if [ "${NIGHTGUARDIAN_CLI_VERIFY:-0}" != "1" ]; then
  TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/nightguardian-install.XXXXXX") || {
    echo "FAIL[tests]: could not create install test home"
    exit 1
  }
  cleanup() { rm -rf "$TMP_HOME"; }
  trap cleanup EXIT INT TERM

  if ! HOME="$TMP_HOME" make -C "$ROOT" install >/dev/null; then
    echo "FAIL[tests]: isolated install failed"
    exit 1
  fi
  if ! HOME="$TMP_HOME" "$TMP_HOME/.local/bin/nightguardian" verify >/dev/null; then
    echo "FAIL[tests]: installed symlinked CLI could not run master gate"
    exit 1
  fi
fi

echo "PASS[tests]: tests and isolated installed CLI verification passed"
exit 0
