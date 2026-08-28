#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$test_dir"
}

trap cleanup EXIT

current_home="$test_dir/current-codex"
switcher_dir="$test_dir/switcher"
fake_bin="$test_dir/bin"
new_auth="$test_dir/new-auth.json"
fake_log="$test_dir/codex.log"

mkdir -p "$current_home" "$fake_bin"
ln -s "$project_dir/tests/fake_codex.sh" "$fake_bin/codex"

jq -n '{
  auth_mode: "chatgpt",
  tokens: {
    id_token: "header.current.signature",
    access_token: "current-access",
    refresh_token: "current-refresh",
    account_id: "account-current"
  }
}' >"$current_home/auth.json"

jq -n '{
  auth_mode: "chatgpt",
  tokens: {
    id_token: "header.second.signature",
    access_token: "second-access",
    refresh_token: "second-refresh",
    account_id: "account-second"
  }
}' >"$new_auth"

before_hash="$(sha256sum "$current_home/auth.json" | cut -d' ' -f1)"

env \
  PATH="$fake_bin:$PATH" \
  CODEX_HOME="$current_home" \
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir" \
  bash "$project_dir/ai_accounts.sh" import-current codex >/dev/null

printf 'Second\n\n' | env \
  PATH="$fake_bin:$PATH" \
  CODEX_HOME="$current_home" \
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir" \
  FAKE_CODEX_AUTH="$new_auth" \
  FAKE_CODEX_LOG="$fake_log" \
  bash "$project_dir/AddCodexAccount.sh" >"$test_dir/output.txt"

after_hash="$(sha256sum "$current_home/auth.json" | cut -d' ' -f1)"

[[ $before_hash == "$after_hash" ]]
[[ $(<"$fake_log") == "login" ]]
jq -e '.accounts | length == 2' "$switcher_dir/codex-accounts.json" >/dev/null
jq -e '.accounts[] | select(.name == "Second")' "$switcher_dir/codex-accounts.json" >/dev/null
jq -e '.active_account_id as $active | .accounts[] | select(.id == $active and .name != "Second")' \
  "$switcher_dir/codex-accounts.json" >/dev/null
if rg -q 'Press Enter to continue|Name for the current' "$test_dir/output.txt"; then exit 1; fi
rg -q 'new account is saved' "$test_dir/output.txt"

echo "Codex add-account isolation test passed"
