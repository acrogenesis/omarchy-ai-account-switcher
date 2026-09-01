#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_CLAUDE_LOG"

if [[ ${1:-} == "auth" && ${2:-} == "login" ]]; then
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cp "$FAKE_CLAUDE_CREDENTIALS" "$CLAUDE_CONFIG_DIR/.credentials.json"
  cp "$FAKE_CLAUDE_STATE" "$CLAUDE_CONFIG_DIR/.claude.json"
elif [[ ${1:-} == "auth" && ${2:-} == "status" ]]; then
  jq '{
    loggedIn: true,
    authMethod: "claude.ai",
    email: .oauthAccount.emailAddress,
    orgName: .oauthAccount.organizationName,
    subscriptionType: "team"
  }' "$CLAUDE_CONFIG_DIR/.claude.json"
elif [[ " $* " == *" -p /usage "* ]]; then
  jq -cn '{type:"result",subtype:"success",is_error:false,result:(
    "You are currently using your subscription to power your Claude Code usage\n\n" +
    "Current session: 34% used\nCurrent week (all models): 72% used\n"
  )}'
elif [[ $# == 0 ]]; then
  jq -cn --arg home "$CLAUDE_CONFIG_DIR" \
    --arg email "$(jq -r '.oauthAccount.emailAddress // empty' "$CLAUDE_CONFIG_DIR/.claude.json")" \
    '{launched: true, home: $home, email: $email}'
else
  echo "Unexpected fake Claude command: $*" >&2
  exit 2
fi
