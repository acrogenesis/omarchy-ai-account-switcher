#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_CODEX_LOG"

if [[ ${1:-} == "login" ]]; then
  mkdir -p "$CODEX_HOME"
  cp "$FAKE_CODEX_AUTH" "$CODEX_HOME/auth.json"
elif [[ $# == 0 ]]; then
  jq -cn --arg home "$CODEX_HOME" --arg account "$(jq -r '.tokens.account_id // empty' "$CODEX_HOME/auth.json")" \
    '{launched: true, home: $home, account_id: $account}'
else
  echo "Unexpected fake Codex command: $*" >&2
  exit 2
fi
