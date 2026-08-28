#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"

cleanup() { rm -rf -- "$test_dir"; }
trap cleanup EXIT

fake_bin="$test_dir/bin"
switcher_dir="$test_dir/switcher"
live_codex="$test_dir/live-codex"
live_claude="$test_dir/live-claude"
mkdir -p "$fake_bin" "$live_codex" "$live_claude"
ln -s "$project_dir/tests/fake_codex.sh" "$fake_bin/codex"
ln -s "$project_dir/tests/fake_claude.sh" "$fake_bin/claude"

jq -n '{auth_mode:"chatgpt",tokens:{
  id_token:"header.one.signature",access_token:"access-one",
  refresh_token:"refresh-one",account_id:"codex-one"
}}' >"$live_codex/auth.json"
jq -n '{claudeAiOauth:{accessToken:"access-one",refreshToken:"refresh-one"},
  mcpOAuth:{keep:{accessToken:"mcp-one"}}}' >"$live_claude/.credentials.json"
jq -n '{oauthAccount:{emailAddress:"one@example.com",accountUuid:"claude-one"}}' \
  >"$live_claude/.claude.json"

common_env=(
  PATH="$fake_bin:$PATH"
  HOME="$test_dir"
  CODEX_HOME="$live_codex"
  CLAUDE_CONFIG_DIR="$live_claude"
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir"
  FAKE_CODEX_LOG="$test_dir/codex.log"
  FAKE_CLAUDE_LOG="$test_dir/claude.log"
)

env "${common_env[@]}" bash "$project_dir/ai_accounts.sh" import-current codex CodexOne >/dev/null
codex_id=$(jq -r '.accounts[0].id' "$switcher_dir/codex-accounts.json")
codex_live_hash=$(sha256sum "$live_codex/auth.json" | cut -d' ' -f1)
codex_output=$(env "${common_env[@]}" bash "$project_dir/LaunchAccount.sh" codex "$codex_id")
codex_home="$switcher_dir/homes/codex/$codex_id"
jq -e --arg home "$codex_home" '
  select(.launched == true and .home == $home and .account_id == "codex-one")
' <<<"$(tail -n 1 <<<"$codex_output")" >/dev/null
[[ $(sha256sum "$live_codex/auth.json" | cut -d' ' -f1) == "$codex_live_hash" ]]

env "${common_env[@]}" bash "$project_dir/ai_accounts.sh" import-current claude ClaudeOne >/dev/null
claude_id=$(jq -r '.accounts[0].id' "$switcher_dir/claude-accounts.json")
claude_live_hash=$(sha256sum "$live_claude/.credentials.json" | cut -d' ' -f1)
claude_output=$(env "${common_env[@]}" bash "$project_dir/LaunchAccount.sh" claude "$claude_id")
claude_home="$switcher_dir/homes/claude/$claude_id"
jq -e --arg home "$claude_home" '
  select(.launched == true and .home == $home and .email == "one@example.com")
' <<<"$(tail -n 1 <<<"$claude_output")" >/dev/null
[[ $(sha256sum "$live_claude/.credentials.json" | cut -d' ' -f1) == "$claude_live_hash" ]]

# Installed command routers make plain CLI invocations follow the selection,
# while explicit provider homes bypass routing and removal restores old commands.
wrapper_bin="$test_dir/wrapper-bin"
mkdir -p "$wrapper_bin"
printf '#!/bin/bash\necho original-claude\n' >"$wrapper_bin/claude"
chmod 755 "$wrapper_bin/claude"

router_env=(
  PATH="$wrapper_bin:$fake_bin:/usr/bin"
  HOME="$test_dir"
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir"
  OMARCHY_AI_SWITCHER_BIN_DIR="$wrapper_bin"
  OMARCHY_AI_SWITCHER_PLUGIN_DIR="$project_dir"
  FAKE_CODEX_LOG="$test_dir/codex.log"
  FAKE_CLAUDE_LOG="$test_dir/claude.log"
)

env "${router_env[@]}" bash "$project_dir/InstallCommandWrappers.sh" install >/dev/null
env "${router_env[@]}" bash "$project_dir/ai_accounts.sh" status |
  jq -e '.command_wrappers_enabled == true' >/dev/null

plain_codex=$(env "${router_env[@]}" "$wrapper_bin/codex")
jq -e --arg home "$codex_home" '
  select(.launched == true and .home == $home and .account_id == "codex-one")
' <<<"$plain_codex" >/dev/null

plain_claude=$(env "${router_env[@]}" "$wrapper_bin/claude")
jq -e --arg home "$claude_home" '
  select(.launched == true and .home == $home and .email == "one@example.com")
' <<<"$plain_claude" >/dev/null

explicit_claude=$(env "${router_env[@]}" CLAUDE_CONFIG_DIR="$live_claude" "$wrapper_bin/claude")
jq -e --arg home "$live_claude" 'select(.launched == true and .home == $home)' \
  <<<"$explicit_claude" >/dev/null

env "${router_env[@]}" bash "$project_dir/InstallCommandWrappers.sh" remove >/dev/null
[[ ! -e $wrapper_bin/codex ]]
rg -q 'original-claude' "$wrapper_bin/claude"

# A stale backup must never cause a subsequently changed command to be lost.
mkdir -p "$switcher_dir/wrapper-backups"
printf '#!/bin/bash\necho previous-claude\n' >"$switcher_dir/wrapper-backups/claude"
if env "${router_env[@]}" bash "$project_dir/InstallCommandWrappers.sh" install >/dev/null 2>&1; then
  echo "Expected router installation to reject a changed command with a stale backup" >&2
  exit 1
fi
rg -q 'original-claude' "$wrapper_bin/claude"

echo "Per-account launcher and command-router isolation tests passed"
