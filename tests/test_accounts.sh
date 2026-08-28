#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
checks=0

cleanup() {
  rm -rf -- "$test_root"
}

trap cleanup EXIT

check() {
  "$@"
  checks=$((checks + 1))
}

reset_fixture() {
  fixture="$test_root/$1"
  switcher_dir="$fixture/switcher"
  codex_home="$fixture/codex"
  claude_home="$fixture/claude"
  fake_bin="$fixture/bin"
  fake_log="$fixture/claude.log"
  mkdir -p "$codex_home" "$claude_home" "$fake_bin"
  ln -s "$project_dir/tests/fake_ps.sh" "$fake_bin/ps"
  ln -s "$project_dir/tests/fake_claude.sh" "$fake_bin/claude"
  export HOME="$fixture"
  export CODEX_HOME="$codex_home"
  export CLAUDE_CONFIG_DIR="$claude_home"
  export OMARCHY_AI_SWITCHER_DIR="$switcher_dir"
  export FAKE_CLAUDE_LOG="$fake_log"
  export PATH="$fake_bin:$original_path"
  unset FAKE_PS_OUTPUT
}

write_codex_chatgpt() {
  local account=$1 suffix=$2
  jq -n --arg account "$account" --arg suffix "$suffix" '{
    auth_mode: "chatgpt",
    tokens: {
      id_token: ("header." + $suffix + ".signature"),
      access_token: ("access-" + $suffix),
      refresh_token: ("refresh-" + $suffix),
      account_id: $account
    }
  }' >"$codex_home/auth.json"
}

write_claude() {
  local email=$1 account_uuid=$2 suffix=$3 org=${4:-Example}
  jq -n --arg suffix "$suffix" '{
    claudeAiOauth: {
      accessToken: ("access-" + $suffix),
      refreshToken: ("refresh-" + $suffix),
      expiresAt: 2000000000000,
      subscriptionType: "team"
    },
    mcpOAuth: {example: {accessToken: "mcp-token"}}
  }' >"$claude_home/.credentials.json"
  jq -n --arg email "$email" --arg uuid "$account_uuid" --arg org "$org" '{
    theme: "dark",
    oauthAccount: {
      emailAddress: $email,
      accountUuid: $uuid,
      organizationName: $org
    }
  }' >"$claude_home/.claude.json"
}

helper() {
  bash "$project_dir/ai_accounts.sh" "$@"
}

original_path=$PATH

# Codex: private import, sanitization, refresh, inactive add, safe switch.
reset_fixture codex-main
write_codex_chatgpt account-one one
helper import-current codex One >/dev/null
check test "$(stat -c '%a' "$switcher_dir")" = 700
check test "$(stat -c '%a' "$switcher_dir/codex-accounts.json")" = 600
status=$(helper status)
check jq -e '.providers.codex.accounts[0] | .name == "One" and has("auth_data") == false' <<<"$status" >/dev/null

write_codex_chatgpt account-one rotated
helper import-current codex >/dev/null
check jq -e '.accounts | length == 1' "$switcher_dir/codex-accounts.json" >/dev/null
check jq -e '.accounts[0].auth_data.refresh_token == "refresh-rotated" and .accounts[0].name == "One"' \
  "$switcher_dir/codex-accounts.json" >/dev/null

write_codex_chatgpt account-two two
helper import-current codex Two --inactive >/dev/null
first_codex=$(jq -r '.accounts[] | select(.name == "One").id' "$switcher_dir/codex-accounts.json")
second_codex=$(jq -r '.accounts[] | select(.name == "Two").id' "$switcher_dir/codex-accounts.json")
check jq -e --arg id "$first_codex" '.active_account_id == $id and (.accounts | length == 2)' \
  "$switcher_dir/codex-accounts.json" >/dev/null

# Make Two current, rotate it, then switch to One; the rotated token is saved.
helper switch codex "$second_codex" >/dev/null
jq '.tokens.refresh_token = "refresh-two-rotated"' "$codex_home/auth.json" >"$fixture/rotated.json"
mv "$fixture/rotated.json" "$codex_home/auth.json"
helper switch codex "$first_codex" >/dev/null
check jq -e '.tokens.refresh_token == "refresh-rotated"' "$codex_home/auth.json" >/dev/null
check jq -e '.accounts[] | select(.name == "Two") | .auth_data.refresh_token == "refresh-two-rotated"' \
  "$switcher_dir/codex-accounts.json" >/dev/null

# API-key accounts remain private and switch correctly.
jq -n '{auth_mode:"api_key",OPENAI_API_KEY:"sk-test-one"}' >"$codex_home/auth.json"
helper import-current codex KeyOne >/dev/null
jq -n '{auth_mode:"api_key",OPENAI_API_KEY:"sk-test-two"}' >"$codex_home/auth.json"
helper import-current codex KeyTwo >/dev/null
key_one=$(jq -r '.accounts[] | select(.name == "KeyOne").id' "$switcher_dir/codex-accounts.json")
helper switch codex "$key_one" >/dev/null
check jq -e '.OPENAI_API_KEY == "sk-test-one"' "$codex_home/auth.json" >/dev/null
check jq -e '.providers.codex.accounts[] | select(.name == "KeyOne") | has("auth_data") == false' \
  <<<"$(helper status)" >/dev/null

# A real account change is blocked while an interactive provider session exists.
write_codex_chatgpt account-two two
helper import-current codex Two >/dev/null
export FAKE_PS_OUTPUT='101 pts/1 codex codex --model test'
set +e
blocked=$(helper switch codex "$first_codex")
blocked_rc=$?
set -e
check test "$blocked_rc" = 1
check jq -e '.error | contains("Close 1 active Codex session")' <<<"$blocked" >/dev/null
unset FAKE_PS_OUTPUT

helper rename codex "$first_codex" Work >/dev/null
check jq -e --arg id "$first_codex" '.accounts[] | select(.id == $id) | .name == "Work"' \
  "$switcher_dir/codex-accounts.json" >/dev/null
helper remove codex "$first_codex" >/dev/null
check jq -e --arg id "$first_codex" '[.accounts[] | select(.id == $id)] | length == 0' \
  "$switcher_dir/codex-accounts.json" >/dev/null

# Store writes refuse destination symlinks.
reset_fixture codex-symlink
write_codex_chatgpt account-one one
mkdir -p "$switcher_dir"
printf '{"untouched":true}\n' >"$fixture/victim.json"
ln -s "$fixture/victim.json" "$switcher_dir/codex-accounts.json"
set +e
symlink_result=$(helper import-current codex One)
symlink_rc=$?
set -e
check test "$symlink_rc" = 1
check jq -e '.untouched == true' "$fixture/victim.json" >/dev/null
check jq -e '.error | contains("symlink")' <<<"$symlink_result" >/dev/null

# Claude: private import, inactive add, token/MCP preservation, blocking, CRUD.
reset_fixture claude-main
write_claude one@example.com uuid-one one 'One Org'
helper import-current claude One >/dev/null
check test "$(stat -c '%a' "$switcher_dir/claude-accounts.json")" = 600
check jq -e '.providers.claude.accounts[0] |
  .name == "One" and .email == "one@example.com" and has("credentials") == false and has("oauth_account") == false' \
  <<<"$(helper status)" >/dev/null
first_claude=$(jq -r '.accounts[0].id' "$switcher_dir/claude-accounts.json")

write_claude two@example.com uuid-two two 'Two Org'
helper import-current claude Two --inactive >/dev/null
second_claude=$(jq -r '.accounts[] | select(.name == "Two").id' "$switcher_dir/claude-accounts.json")
check jq -e --arg id "$first_claude" '.active_account_id == $id and (.accounts | length == 2)' \
  "$switcher_dir/claude-accounts.json" >/dev/null

helper switch claude "$second_claude" >/dev/null
jq '.claudeAiOauth.refreshToken = "refresh-two-rotated" |
  .mcpOAuth.other = {accessToken:"keep-me"}' "$claude_home/.credentials.json" >"$fixture/rotated.json"
mv "$fixture/rotated.json" "$claude_home/.credentials.json"
helper switch claude "$first_claude" >/dev/null
check jq -e '.claudeAiOauth.refreshToken == "refresh-one" and .mcpOAuth.other.accessToken == "keep-me"' \
  "$claude_home/.credentials.json" >/dev/null
check jq -e '.accounts[] | select(.name == "Two") | .credentials.refreshToken == "refresh-two-rotated"' \
  "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '.theme == "dark" and .oauthAccount.accountUuid == "uuid-one"' \
  "$claude_home/.claude.json" >/dev/null

write_claude two@example.com uuid-two two 'Two Org'
helper import-current claude Two >/dev/null
export FAKE_PS_OUTPUT='202 pts/2 claude claude --resume test'
set +e
blocked=$(helper switch claude "$first_claude")
blocked_rc=$?
set -e
check test "$blocked_rc" = 1
check jq -e '.error | contains("Close 1 active Claude session")' <<<"$blocked" >/dev/null
unset FAKE_PS_OUTPUT

helper rename claude "$first_claude" Personal >/dev/null
check jq -e --arg id "$first_claude" '.accounts[] | select(.id == $id) | .name == "Personal"' \
  "$switcher_dir/claude-accounts.json" >/dev/null
helper remove claude "$first_claude" >/dev/null
check jq -e --arg id "$first_claude" '[.accounts[] | select(.id == $id)] | length == 0' \
  "$switcher_dir/claude-accounts.json" >/dev/null

printf 'Account helper tests passed (%d checks)\n' "$checks"
