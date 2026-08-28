#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_CODEX_LOG"

if [[ ${1:-} != "login" ]]; then
  echo "Unexpected fake Codex command: $*" >&2
  exit 2
fi

mkdir -p "$CODEX_HOME"
cp "$FAKE_CODEX_AUTH" "$CODEX_HOME/auth.json"
