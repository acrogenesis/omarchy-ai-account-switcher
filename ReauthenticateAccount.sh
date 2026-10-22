#!/bin/bash

set -euo pipefail
umask 077

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$plugin_dir/ai_accounts.sh"
provider=${1:-}
account_id=${2:-}
login_home=""

finish() {
  local result=$?
  trap - EXIT
  if [[ -n $login_home ]]; then rm -rf -- "$login_home"; fi
  if (( result != 0 )); then
    printf '\nSign-in was not completed. You can try again from the account panel.\n'
  fi
  if [[ -t 0 ]]; then read -r -p 'Press Enter to close...' _ || true; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[[ $provider == codex || $provider == claude ]] && [[ -n $account_id ]] || {
  echo "Usage: $0 codex|claude ACCOUNT_ID" >&2
  exit 2
}
command -v "$provider" >/dev/null || { echo "${provider^} is not installed" >&2; exit 1; }
if ! result=$(bash "$helper" prepare-reauth "$provider" "$account_id"); then
  jq -r '.error // "Could not prepare sign-in"' <<<"$result" >&2
  exit 1
fi
login_home=$(jq -er '.home' <<<"$result")
name=$(jq -r '.name' <<<"$result")
email=$(jq -r '.email // empty' <<<"$result")
auth_mode=$(jq -r '.auth_mode // empty' <<<"$result")
printf '%s · Sign in again\n\nAccount: %s\n' "${provider^}" "$name"
if [[ -n $email ]]; then printf 'Sign in as: %s\n' "$email"; fi
printf '\nYour saved login will be updated after sign-in succeeds.\n\n'

if [[ $provider == codex ]]; then
  if [[ $auth_mode == api_key ]]; then
    read -rs -p 'New OpenAI API key: ' api_key
    printf '\n'
    [[ -n $api_key ]] || exit 1
    printf '%s\n' "$api_key" | CODEX_HOME="$login_home" codex login \
      -c 'cli_auth_credentials_store="file"' --with-api-key
    unset api_key
  else
    CODEX_HOME="$login_home" codex login -c 'cli_auth_credentials_store="file"'
  fi
else
  login_args=(auth login)
  if [[ -n $email ]]; then login_args+=(--email "$email"); fi
  CLAUDE_CONFIG_DIR="$login_home" claude "${login_args[@]}"
fi

if ! result=$(bash "$helper" complete-reauth "$provider" "$account_id" "$login_home"); then
  jq -r '.error // "Could not update the saved login"' <<<"$result" >&2
  exit 1
fi
jq -r '.message' <<<"$result"
