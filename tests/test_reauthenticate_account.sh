#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
ln -s "$project_dir/tests/fake_codex.sh" "$test_dir/bin/codex"
ln -s "$project_dir/tests/fake_claude.sh" "$test_dir/bin/claude"
export PATH="$test_dir/bin:$PATH"
export HOME="$test_dir"
export FAKE_CODEX_LOG="$test_dir/codex.log"
export FAKE_CLAUDE_LOG="$test_dir/claude.log"
checks=0
check() { "$@"; checks=$((checks + 1)); }
helper() { bash "$project_dir/ai_accounts.sh" "$@"; }

write_login() {
  local provider=$1 home=$2 identity=$3 suffix=$4 email=${5:-$3@example.com} claims
  mkdir -p "$home"
  if [[ $provider == codex ]]; then
    claims=$(jq -cn --arg email "$email" '{email:$email}' | base64 -w0)
    jq -n --arg identity "$identity" --arg suffix "$suffix" --arg token "header.$claims.signature" \
      '{auth_mode:"chatgpt",tokens:{account_id:$identity,id_token:$token,
        access_token:("access-"+$suffix),refresh_token:("refresh-"+$suffix)}}' >"$home/auth.json"
  else
    jq -n --arg suffix "$suffix" '{claudeAiOauth:{accessToken:("access-"+$suffix),
      refreshToken:("refresh-"+$suffix)},mcpOAuth:{keep:{accessToken:"mcp-keep"}}}' >"$home/.credentials.json"
    jq -n --arg identity "$identity" --arg email "$email" \
      '{theme:"dark",oauthAccount:{accountUuid:$identity,emailAddress:$email}}' >"$home/.claude.json"
  fi
}

for provider in codex claude; do
  fixture="$test_dir/$provider"
  export OMARCHY_AI_SWITCHER_DIR="$fixture/switcher"
  export CODEX_HOME="$fixture/live"
  export CLAUDE_CONFIG_DIR="$fixture/live"
  export FAKE_CODEX_AUTH="$fixture/new/auth.json"
  export FAKE_CLAUDE_CREDENTIALS="$fixture/new/.credentials.json"
  export FAKE_CLAUDE_STATE="$fixture/new/.claude.json"
  write_login "$provider" "$fixture/live" one old
  helper import-current "$provider" 'My account' >/dev/null
  store="$OMARCHY_AI_SWITCHER_DIR/$provider-accounts.json"
  account_id=$(jq -r '.accounts[0].id' "$store")
  account_home="$OMARCHY_AI_SWITCHER_DIR/homes/$provider/$account_id"
  if [[ $provider == codex ]]; then credential=auth.json; else credential=.credentials.json; fi
  printf 'saved history\n' >"$fixture/history.jsonl"
  ln -s "$fixture/history.jsonl" "$account_home/history.jsonl"
  history_hash=$(sha256sum "$account_home/history.jsonl")

  # Keep a different account selected; reauthentication must not select its target.
  write_login "$provider" "$fixture/live" two other
  helper import-current "$provider" Other >/dev/null
  live_hash=$(sha256sum "$fixture/live/$credential")
  original_store=$(sha256sum "$store")
  old_credentials=$(sha256sum "$account_home/$credential")

  # Failed official login never alters either login, store, or history.
  if FAKE_LOGIN_FAIL=1 bash "$project_dir/ReauthenticateAccount.sh" "$provider" "$account_id" \
    </dev/null >"$fixture/output" 2>&1; then exit 1; fi
  check test "$(sha256sum "$store")" = "$original_store"
  check test "$(sha256sum "$account_home/$credential")" = "$old_credentials"

  # Wrong identity, including a different user in the same Codex workspace.
  for identity in wrong one; do
    write_login "$provider" "$fixture/new" "$identity" new wrong@example.com
    if bash "$project_dir/ReauthenticateAccount.sh" "$provider" "$account_id" \
      </dev/null >"$fixture/output" 2>&1; then exit 1; fi
    check rg -q 'different account' "$fixture/output"
    check test "$(sha256sum "$store")" = "$original_store"
    check test "$(sha256sum "$account_home/$credential")" = "$old_credentials"
  done

  write_login "$provider" "$fixture/new" one new
  cp "$store" "$fixture/before.json"
  bash "$project_dir/ReauthenticateAccount.sh" "$provider" "$account_id" \
    </dev/null >"$fixture/output" 2>&1
  check rg -q 'Signed in again' "$fixture/output"
  check jq -e --arg id "$account_id" --slurpfile before "$fixture/before.json" '
    .active_account_id == $before[0].active_account_id and
    (.accounts|length) == 2 and
    ([.accounts[]|select(.id != $id)] == [$before[0].accounts[]|select(.id != $id)]) and
    ([.accounts[]|select(.id == $id)|{id,name,created_at,last_used_at}] ==
      [$before[0].accounts[]|select(.id == $id)|{id,name,created_at,last_used_at}])' "$store" >/dev/null
  check test "$(sha256sum "$account_home/history.jsonl")" = "$history_hash"
  check test "$(readlink "$account_home/history.jsonl")" = "$fixture/history.jsonl"
  check test "$(sha256sum "$fixture/live/$credential")" = "$live_hash"
  check test "$(stat -c %a "$account_home/$credential")" = 600
  check test "$(stat -c %a "$account_home")" = 700
  check test "$(stat -c %a "$store")" = 600
  check test "$(stat -c %a "$OMARCHY_AI_SWITCHER_DIR/reauth")" = 700
  check test -z "$(ls -A "$OMARCHY_AI_SWITCHER_DIR/reauth")"
  if rg -q 'access-|refresh-|mcp-keep' "$fixture/output"; then exit 1; fi
  if [[ $provider == codex ]]; then
    check jq -e '.tokens.refresh_token == "refresh-new"' "$account_home/auth.json" >/dev/null
    check jq -e --arg id "$account_id" '.accounts[]|select(.id == $id)|
      .auth_data.refresh_token == "refresh-new"' "$store" >/dev/null
    check rg -q '^login -c cli_auth_credentials_store="file"$' "$FAKE_CODEX_LOG"
  else
    check jq -e '.claudeAiOauth.refreshToken == "refresh-new" and
      .mcpOAuth.keep.accessToken == "mcp-keep"' "$account_home/.credentials.json" >/dev/null
    check jq -e --arg id "$account_id" '.accounts[]|select(.id == $id)|
      .credentials.refreshToken == "refresh-new"' "$store" >/dev/null
    check jq -e '.theme == "dark" and .oauthAccount.accountUuid == "one"' "$account_home/.claude.json" >/dev/null
    check rg -q '^auth login --email one@example.com$' "$FAKE_CLAUDE_LOG"
  fi

  # Refuse destination symlinks before writing any credential file.
  blocked_file=$credential
  if [[ $provider == claude ]]; then blocked_file=.claude.json; fi
  mv "$account_home/$blocked_file" "$fixture/preserved.json"
  ln -s "$fixture/preserved.json" "$account_home/$blocked_file"
  preserved_hash=$(sha256sum "$fixture/preserved.json")
  original_store=$(sha256sum "$store")
  old_credentials=$(sha256sum "$account_home/$credential")
  write_login "$provider" "$fixture/new" one should-not-save
  if bash "$project_dir/ReauthenticateAccount.sh" "$provider" "$account_id" \
    </dev/null >"$fixture/output" 2>&1; then exit 1; fi
  check rg -q 'Refusing to replace symlink' "$fixture/output"
  check test "$(sha256sum "$store")" = "$original_store"
  check test "$(sha256sum "$account_home/$credential")" = "$old_credentials"
  check test "$(sha256sum "$fixture/preserved.json")" = "$preserved_hash"
  rm "$account_home/$blocked_file"
  mv "$fixture/preserved.json" "$account_home/$blocked_file"

  # Deleting the saved account while the browser is open must not recreate it.
  prepared=$(helper prepare-reauth "$provider" "$account_id")
  stage=$(jq -r .home <<<"$prepared")
  write_login "$provider" "$stage" one newer
  helper remove "$provider" "$account_id" >/dev/null
  if helper complete-reauth "$provider" "$account_id" "$stage" >"$fixture/output"; then exit 1; fi
  check rg -q 'Account not found' "$fixture/output"
  check test ! -e "$account_home"
  check jq -e '.accounts|length == 1' "$store" >/dev/null
  rm -rf "$stage"
done

# API key rotation uses stdin and does not reveal the replacement key.
export OMARCHY_AI_SWITCHER_DIR="$test_dir/api-switcher"
export CODEX_HOME="$test_dir/api-live"
mkdir -p "$CODEX_HOME"
jq -n '{auth_mode:"api_key",OPENAI_API_KEY:"sk-fixture-old"}' >"$CODEX_HOME/auth.json"
helper import-current codex 'API key' >/dev/null
account_id=$(jq -r '.accounts[0].id' "$OMARCHY_AI_SWITCHER_DIR/codex-accounts.json")
printf 'sk-fixture-new\n' | bash "$project_dir/ReauthenticateAccount.sh" codex "$account_id" \
  >"$test_dir/api-output" 2>&1
check jq -e '.OPENAI_API_KEY == "sk-fixture-new"' \
  "$OMARCHY_AI_SWITCHER_DIR/homes/codex/$account_id/auth.json" >/dev/null
check jq -e '.OPENAI_API_KEY == "sk-fixture-old"' "$CODEX_HOME/auth.json" >/dev/null
check test -z "$(ls -A "$OMARCHY_AI_SWITCHER_DIR/reauth")"
if rg -q 'sk-fixture-new|logout' "$test_dir/api-output" "$FAKE_CODEX_LOG" "$FAKE_CLAUDE_LOG"; then exit 1; fi

printf 'Reauthentication isolation tests passed (%s checks)\n' "$checks"
