#!/bin/bash

set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$plugin_dir/ai_accounts.sh"
login_home=""
source_home="${GROK_HOME:-$HOME/.grok}"

cleanup() {
  if [[ -n $login_home && -d $login_home ]]; then
    rm -rf -- "$login_home"
  fi
}

trap cleanup EXIT

run_helper() {
  local output status
  set +e
  output="$(bash "$helper" "$@")"
  status=$?
  set -e
  jq -r '.message // .error // "Done"' <<<"$output"
  return "$status"
}

if [[ -t 1 ]]; then clear; fi
echo "AI Account Switcher · Grok"
echo

if [[ -f ${GROK_HOME:-$HOME/.grok}/auth.json ]]; then
  run_helper import-current grok
fi

login_home="$(mktemp -d)"
GROK_HOME="$login_home" grok login

echo
read -r -p "Name for the new login (Enter uses its email): " new_name
GROK_HOME="$login_home" OMARCHY_AI_SOURCE_GROK_HOME="$source_home" \
  run_helper import-current grok "$new_name" --inactive

echo
echo "The new account is saved. Select and open it from the bar whenever you want."
read -r -p "Press Enter to close..."
