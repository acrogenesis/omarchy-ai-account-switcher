#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$test_dir"
}

trap cleanup EXIT

current_home="$test_dir/current-grok"
switcher_dir="$test_dir/switcher"
fake_bin="$test_dir/bin"
new_auth="$test_dir/new-auth.json"
fake_log="$test_dir/grok.log"

mkdir -p "$current_home" "$fake_bin"
ln -s "$project_dir/tests/fake_grok.sh" "$fake_bin/grok"

jq -n '{
  "https://auth.x.ai::client-one": {
    auth_mode: "oauth",
    create_time: "2026-01-01T00:00:00Z",
    email: "current@example.com",
    key: "key-current",
    principal_id: "principal-current"
  }
}' >"$current_home/auth.json"

jq -n '{
  "https://auth.x.ai::client-one": {
    auth_mode: "oauth",
    create_time: "2026-02-01T00:00:00Z",
    email: "second@example.com",
    key: "key-second",
    principal_id: "principal-second"
  }
}' >"$new_auth"

before_hash="$(sha256sum "$current_home/auth.json" | cut -d' ' -f1)"

env \
  PATH="$fake_bin:$PATH" \
  GROK_HOME="$current_home" \
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir" \
  bash "$project_dir/ai_accounts.sh" import-current grok >/dev/null

printf 'Second\n\n' | env \
  PATH="$fake_bin:$PATH" \
  GROK_HOME="$current_home" \
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir" \
  FAKE_GROK_AUTH="$new_auth" \
  FAKE_GROK_LOG="$fake_log" \
  bash "$project_dir/AddGrokAccount.sh" >"$test_dir/output.txt"

after_hash="$(sha256sum "$current_home/auth.json" | cut -d' ' -f1)"

[[ $before_hash == "$after_hash" ]]
[[ $(<"$fake_log") == "login" ]]
jq -e '.accounts | length == 2' "$switcher_dir/grok-accounts.json" >/dev/null
jq -e '.accounts[] | select(.name == "Second")' "$switcher_dir/grok-accounts.json" >/dev/null
jq -e '.active_account_id as $active | .accounts[] | select(.id == $active and .name != "Second")' \
  "$switcher_dir/grok-accounts.json" >/dev/null
if rg -q 'Press Enter to continue|Name for the current' "$test_dir/output.txt"; then exit 1; fi
rg -q 'new account is saved' "$test_dir/output.txt"

echo "Grok add-account isolation test passed"
