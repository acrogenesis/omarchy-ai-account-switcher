#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_GROK_LOG"

if [[ ${1:-} == "login" ]]; then
  mkdir -p "$GROK_HOME"
  cp "$FAKE_GROK_AUTH" "$GROK_HOME/auth.json"
elif [[ $# == 0 ]]; then
  jq -cn --arg home "$GROK_HOME" \
    --arg principal "$(jq -r '[.[] | .principal_id] | first // empty' "$GROK_HOME/auth.json")" \
    '{launched: true, home: $home, principal_id: $principal}'
else
  echo "Unexpected fake Grok command: $*" >&2
  exit 2
fi
