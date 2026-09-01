#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_CODEX_LOG"

if [[ ${1:-} == "login" ]]; then
  mkdir -p "$CODEX_HOME"
  cp "$FAKE_CODEX_AUTH" "$CODEX_HOME/auth.json"
elif [[ ${1:-} == "app-server" ]]; then
  while IFS= read -r request; do
    if jq -e '.id == 1' >/dev/null 2>&1 <<<"$request"; then
      jq -cn '{id:1,result:{userAgent:"fake",codexHome:env.CODEX_HOME}}'
    elif jq -e '.id == 2 and .method == "account/rateLimits/read"' >/dev/null 2>&1 <<<"$request"; then
      jq -cn '{id:2,result:{rateLimits:{
        primary:{usedPercent:27,windowDurationMins:300,resetsAt:2000000000},
        secondary:{usedPercent:61,windowDurationMins:10080,resetsAt:2000500000},
        planType:"plus"
      }}}'
    fi
  done
elif [[ $# == 0 ]]; then
  jq -cn --arg home "$CODEX_HOME" --arg account "$(jq -r '.tokens.account_id // empty' "$CODEX_HOME/auth.json")" \
    '{launched: true, home: $home, account_id: $account}'
else
  echo "Unexpected fake Codex command: $*" >&2
  exit 2
fi
