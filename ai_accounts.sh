#!/bin/bash

set -Eeu -o pipefail

STORE_VERSION=1
CONFIG_DIR="${OMARCHY_AI_SWITCHER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ai-account-switcher}"

fail() {
  jq -cn --arg error "$1" '{ok: false, error: $error}'
  exit 1
}

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%S.%NZ'
}

new_id() {
  tr -d '\n' </proc/sys/kernel/random/uuid
}

provider_store() {
  case $1 in
    codex) printf '%s/codex-accounts.json\n' "$CONFIG_DIR" ;;
    claude) printf '%s/claude-accounts.json\n' "$CONFIG_DIR" ;;
    *) fail "Unknown provider: $1" ;;
  esac
}

load_store() {
  local path=$1
  if [[ ! -e $path ]]; then
    STORE_JSON='{"version":1,"accounts":[],"active_account_id":null}'
    return
  fi
  if [[ -L $path ]]; then fail "Refusing to read symlink: $path"; fi
  if ! STORE_JSON=$(jq -c '
    if type != "object" or (.accounts | type) != "array" then
      error("invalid account store")
    else
      .version //= 1 | .active_account_id //= null
    end
  ' "$path" 2>/dev/null); then
    fail "Could not read $(basename "$path")"
  fi
}

lock_store() {
  mkdir -p -- "$CONFIG_DIR"
  chmod 700 -- "$CONFIG_DIR"
  exec 9>"$CONFIG_DIR/.lock"
  chmod 600 -- "$CONFIG_DIR/.lock"
  flock -x 9
}

atomic_private_write() {
  local path=$1 value=$2 directory temporary
  directory=$(dirname -- "$path")
  mkdir -p -- "$directory"
  chmod 700 -- "$directory"
  if [[ -L $path ]]; then fail "Refusing to replace symlink: $path"; fi
  temporary=$(mktemp "$directory/.$(basename "$path").XXXXXX")
  chmod 600 -- "$temporary"
  if ! printf '%s\n' "$value" | jq . >"$temporary"; then
    rm -f -- "$temporary"
    fail "Could not write $(basename "$path")"
  fi
  mv -fT -- "$temporary" "$path"
  chmod 600 -- "$path"
}

atomic_preserving_write() {
  local path=$1 value=$2 directory temporary mode=600
  directory=$(dirname -- "$path")
  mkdir -p -- "$directory"
  if [[ -L $path ]]; then fail "Refusing to replace symlink: $path"; fi
  if [[ -e $path ]]; then mode=$(stat -c '%a' -- "$path"); fi
  temporary=$(mktemp "$directory/.$(basename "$path").XXXXXX")
  chmod "$mode" -- "$temporary"
  if ! printf '%s\n' "$value" | jq . >"$temporary"; then
    rm -f -- "$temporary"
    fail "Could not write $(basename "$path")"
  fi
  mv -fT -- "$temporary" "$path"
  chmod "$mode" -- "$path"
}

sha256_text() {
  sha256sum | cut -d' ' -f1
}

jwt_claims() {
  local token=$1 payload padding
  if [[ $token != *.*.* ]]; then printf '{}\n'; return; fi
  payload=${token#*.}
  payload=${payload%%.*}
  payload=${payload//-/+}
  payload=${payload//_/\/}
  padding=$(( (4 - ${#payload} % 4) % 4 ))
  while (( padding-- > 0 )); do payload+='='; done
  if ! printf '%s' "$payload" | base64 -d 2>/dev/null | jq -c \
    'if type == "object" then . else {} end' 2>/dev/null; then
    printf '{}\n'
  fi
}

codex_auth_path() {
  printf '%s/auth.json\n' "${CODEX_HOME:-$HOME/.codex}"
}

claude_credentials_path() {
  printf '%s/.credentials.json\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

claude_state_path() {
  if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
    printf '%s/.claude.json\n' "$CLAUDE_CONFIG_DIR"
  else
    printf '%s/.claude.json\n' "$HOME"
  fi
}

codex_current_account() {
  local path auth mode id created token claims email plan account_id suffix name auth_data
  path=$(codex_auth_path)
  if [[ ! -f $path || -L $path ]]; then printf 'null\n'; return; fi
  if ! auth=$(jq -c 'if type == "object" then . else error("invalid") end' "$path" 2>/dev/null); then
    printf 'null\n'; return
  fi
  id=$(new_id)
  created=$(utc_now)
  mode=$(printf '%s' "$auth" | jq -r '
    if (.OPENAI_API_KEY | type) == "string" and .OPENAI_API_KEY != "" then "api_key"
    elif (.tokens | type) == "object" and
      ([.tokens.id_token, .tokens.access_token, .tokens.refresh_token] | all(type == "string" and . != ""))
    then "chatgpt" else "" end')

  if [[ $mode == api_key ]]; then
    printf '%s' "$auth" | jq -c --arg id "$id" --arg created "$created" '{
      id: $id,
      name: "API key account",
      email: null,
      plan_type: null,
      subscription_expires_at: null,
      auth_mode: "api_key",
      auth_data: {type: "api_key", key: .OPENAI_API_KEY},
      created_at: $created,
      last_used_at: null
    }'
    return
  fi
  if [[ $mode != chatgpt ]]; then printf 'null\n'; return; fi

  token=$(printf '%s' "$auth" | jq -r '.tokens.id_token')
  claims=$(jwt_claims "$token")
  email=$(printf '%s' "$claims" | jq -r '.email // empty')
  plan=$(printf '%s' "$claims" | jq -r '.["https://api.openai.com/auth"].chatgpt_plan_type // empty')
  account_id=$(printf '%s' "$claims" | jq -r '.["https://api.openai.com/auth"].chatgpt_account_id // empty')
  if [[ -z $account_id ]]; then account_id=$(printf '%s' "$auth" | jq -r '.tokens.account_id // empty'); fi
  suffix=${account_id: -8}
  name=${email:-${suffix:+ChatGPT account ($suffix)}}
  name=${name:-ChatGPT account}
  auth_data=$(printf '%s' "$auth" | jq -c '{
    type: "chatgpt",
    id_token: .tokens.id_token,
    access_token: .tokens.access_token,
    refresh_token: .tokens.refresh_token,
    account_id: (.tokens.account_id // null)
  }')
  printf '%s' "$auth_data" | jq -c \
    --arg id "$id" --arg name "$name" --arg email "$email" --arg plan "$plan" \
    --arg account_id "$account_id" --arg created "$created" '{
      id: $id,
      name: $name,
      email: (if $email == "" then null else $email end),
      plan_type: (if $plan == "" then null else $plan end),
      subscription_expires_at: null,
      auth_mode: "chatgpt",
      auth_data: (. + {account_id: (if $account_id == "" then .account_id else $account_id end)}),
      created_at: $created,
      last_used_at: null
    }'
}

claude_auth_status() {
  if ! command -v claude >/dev/null 2>&1; then printf '{}\n'; return; fi
  local value
  if value=$(timeout 15 claude auth status --json 2>/dev/null) &&
    printf '%s' "$value" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$value" | jq -c .
  else
    printf '{}\n'
  fi
}

claude_current_account() {
  local query_status=${1:-false} credentials_path state_path credentials state status
  local id created email org subscription account_uuid suffix name
  credentials_path=$(claude_credentials_path)
  state_path=$(claude_state_path)
  if [[ ! -f $credentials_path || -L $credentials_path ]]; then printf 'null\n'; return; fi
  if ! credentials=$(jq -c '
    if type == "object" and (.claudeAiOauth | type) == "object" and
      (.claudeAiOauth.accessToken | type) == "string" and .claudeAiOauth.accessToken != ""
    then . else error("invalid") end
  ' "$credentials_path" 2>/dev/null); then
    printf 'null\n'; return
  fi
  if [[ -f $state_path && ! -L $state_path ]]; then
    state=$(jq -c 'if type == "object" then . else {} end' "$state_path" 2>/dev/null || printf '{}')
  else
    state='{}'
  fi
  email=$(printf '%s' "$state" | jq -r '.oauthAccount.emailAddress // empty')
  if [[ $query_status == true || -z $email ]]; then status=$(claude_auth_status); else status='{}'; fi
  email=${email:-$(printf '%s' "$status" | jq -r '.email // empty')}
  org=$(printf '%s' "$state" | jq -r '.oauthAccount.organizationName // empty')
  org=${org:-$(printf '%s' "$status" | jq -r '.orgName // empty')}
  subscription=$(printf '%s' "$status" | jq -r '.subscriptionType // empty')
  if [[ -z $subscription ]]; then
    subscription=$(printf '%s' "$credentials" | jq -r '.claudeAiOauth.subscriptionType // empty')
  fi
  if [[ -z $subscription ]]; then subscription=$(printf '%s' "$state" | jq -r '.oauthAccount.seatTier // empty'); fi
  account_uuid=$(printf '%s' "$state" | jq -r '.oauthAccount.accountUuid // empty')
  suffix=${account_uuid: -8}
  name=${email:-${suffix:+Claude account ($suffix)}}
  name=${name:-Claude account}
  id=$(new_id)
  created=$(utc_now)
  printf '%s' "$credentials" | jq -c --slurpfile state <(printf '%s\n' "$state") \
    --arg id "$id" --arg name "$name" --arg email "$email" --arg org "$org" \
    --arg subscription "$subscription" --arg created "$created" '{
      id: $id,
      name: $name,
      email: (if $email == "" then null else $email end),
      org_name: (if $org == "" then null else $org end),
      subscription_type: (if $subscription == "" then null else $subscription end),
      credentials: .claudeAiOauth,
      oauth_account: (if ($state[0].oauthAccount | type) == "object" then $state[0].oauthAccount else null end),
      created_at: $created,
      last_used_at: null
    }'
}

codex_match_index() {
  local candidate=$1
  printf '%s' "$STORE_JSON" | jq -r --slurpfile candidate <(printf '%s\n' "$candidate") '
    ($candidate[0]) as $c |
    [.accounts | to_entries[] | select(
      if $c.auth_mode == "api_key" then
        .value.auth_mode == "api_key" and .value.auth_data.key == $c.auth_data.key
      elif ($c.auth_data.account_id // "") != "" then
        .value.auth_data.account_id == $c.auth_data.account_id
      elif ($c.email // "") != "" then
        ((.value.email // "") | ascii_downcase) == (($c.email // "") | ascii_downcase)
      else
        .value.auth_data.refresh_token == $c.auth_data.refresh_token
      end
    )] | first | (.key // -1)
  '
}

claude_match_index() {
  local candidate=$1
  printf '%s' "$STORE_JSON" | jq -r --slurpfile candidate <(printf '%s\n' "$candidate") '
    ($candidate[0]) as $c |
    [.accounts | to_entries[] | select(
      if ($c.oauth_account.accountUuid // "") != "" then
        .value.oauth_account.accountUuid == $c.oauth_account.accountUuid
      elif ($c.email // "") != "" then
        ((.value.email // "") | ascii_downcase) == (($c.email // "") | ascii_downcase)
      else
        .value.credentials.refreshToken == $c.credentials.refreshToken
      end
    )] | first | (.key // -1)
  '
}

provider_current_account() {
  case $1 in
    codex) codex_current_account ;;
    claude) claude_current_account "${2:-false}" ;;
  esac
}

provider_match_index() {
  case $1 in
    codex) codex_match_index "$2" ;;
    claude) claude_match_index "$2" ;;
  esac
}

running_processes() {
  local provider=$1
  ps -axo pid=,tty=,comm=,args= | awk -v provider="$provider" '
    {
      pid=$1; tty=$2; comm=$3
      $1=$2=$3=""; sub(/^[[:space:]]+/, "", $0); args=$0
      split(args, words, /[[:space:]]+/)
      first=words[1]; sub(/^.*\//, "", first)
      command=comm; sub(/^.*\//, "", command)
      if (tty == "?" || tty == "??" || tty == "-") next
      if (provider == "codex") {
        lowered=tolower(args)
        if ((command == "codex" || first == "codex") &&
            lowered !~ /codex app-server/ && lowered !~ /codex-code-mode-host/) print pid
      } else if (provider == "claude" && (command == "claude" || first == "claude")) {
        print pid
      }
    }
  '
}

running_count() {
  running_processes "$1" | awk 'NF { count++ } END { print count + 0 }'
}

provider_status() {
  local provider=$1 store_path current index current_id active_id count has_current suggested
  store_path=$(provider_store "$provider")
  load_store "$store_path"
  current=$(provider_current_account "$provider" false)
  current_id=''
  if [[ $current != null ]]; then
    index=$(provider_match_index "$provider" "$current")
    if (( index >= 0 )); then current_id=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].id'); fi
  fi
  active_id=${current_id:-$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty')}
  count=$(running_count "$provider")
  if [[ $current == null ]]; then has_current=false; suggested=''; else has_current=true; suggested=$(printf '%s' "$current" | jq -r '.name // empty'); fi

  if [[ $provider == codex ]]; then
    printf '%s' "$STORE_JSON" | jq -c \
      --arg active "$active_id" --arg current "$current_id" --arg suggested "$suggested" \
      --argjson has_current "$has_current" --argjson count "$count" '{
        ok: true, provider: "codex",
        accounts: [.accounts[] | {
          id: (.id | tostring), name: (.name // "Account"), email, plan_type, auth_mode,
          is_active: (.id == $active), is_current: (.id == $current), last_used_at
        }],
        active_account_id: (if $active == "" then null else $active end),
        current_saved: ($current != ""), has_current_login: $has_current,
        suggested_name: $suggested, can_switch: ($count == 0), running_count: $count
      }'
  else
    printf '%s' "$STORE_JSON" | jq -c \
      --arg active "$active_id" --arg current "$current_id" --arg suggested "$suggested" \
      --argjson has_current "$has_current" --argjson count "$count" '{
        ok: true, provider: "claude",
        accounts: [.accounts[] | {
          id: (.id | tostring), name: (.name // "Account"), email, org_name, subscription_type,
          is_active: (.id == $active), is_current: (.id == $current), last_used_at
        }],
        active_account_id: (if $active == "" then null else $active end),
        current_saved: ($current != ""), has_current_login: $has_current,
        suggested_name: $suggested, can_switch: ($count == 0), running_count: $count
      }'
  fi
}

combined_status() {
  local codex claude
  codex=$(provider_status codex)
  claude=$(provider_status claude)
  jq -cn --slurpfile codex <(printf '%s\n' "$codex") --slurpfile claude <(printf '%s\n' "$claude") \
    '{ok: true, providers: {codex: $codex[0], claude: $claude[0]}}'
}

import_current() {
  local provider=$1 name=$2 activate=$3 store_path candidate index saved_id saved_name
  local previous_active existing_id existing_name existing_created existing_last
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  previous_active=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty')
  candidate=$(provider_current_account "$provider" true)
  if [[ $candidate == null ]]; then fail "No ${provider^} login is available to save"; fi
  index=$(provider_match_index "$provider" "$candidate")

  if (( index >= 0 )); then
    existing_id=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].id')
    existing_name=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].name // empty')
    existing_created=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].created_at // empty')
    existing_last=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" '.accounts[$index].last_used_at // null')
    saved_name=${name:-$existing_name}
    saved_name=${saved_name:-$(printf '%s' "$candidate" | jq -r '.name')}
    candidate=$(printf '%s' "$candidate" | jq -c \
      --arg id "$existing_id" --arg name "$saved_name" --arg created "$existing_created" \
      --argjson last "$existing_last" '.id=$id | .name=$name | .created_at=$created | .last_used_at=$last')
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" \
      --slurpfile candidate <(printf '%s\n' "$candidate") '.accounts[$index]=$candidate[0]')
  else
    if [[ -n $name ]]; then candidate=$(printf '%s' "$candidate" | jq -c --arg name "$name" '.name=$name'); fi
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --slurpfile candidate <(printf '%s\n' "$candidate") \
      '.accounts += [$candidate[0]]')
  fi
  saved_id=$(printf '%s' "$candidate" | jq -r '.id')
  saved_name=$(printf '%s' "$candidate" | jq -r '.name')
  if [[ $activate == true ]]; then
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$saved_id" '.active_account_id=$id')
  else
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$previous_active" \
      '.active_account_id=(if $id == "" then null else $id end)')
  fi
  atomic_private_write "$store_path" "$STORE_JSON"
  jq -cn --arg message "Saved $saved_name" '{ok: true, message: $message}'
}

account_identity() {
  local provider=$1 account token
  account=$(cat)
  if [[ $provider == codex ]]; then
    if [[ $(printf '%s' "$account" | jq -r '.auth_mode') == api_key ]]; then
      printf 'key:%s\n' "$(printf '%s' "$account" | jq -r '.auth_data.key' | sha256_text)"
    elif [[ -n $(printf '%s' "$account" | jq -r '.auth_data.account_id // empty') ]]; then
      printf 'account:%s\n' "$(printf '%s' "$account" | jq -r '.auth_data.account_id')"
    elif [[ -n $(printf '%s' "$account" | jq -r '.email // empty') ]]; then
      printf 'email:%s\n' "$(printf '%s' "$account" | jq -r '.email | ascii_downcase')"
    else
      printf 'token:%s\n' "$(printf '%s' "$account" | jq -r '.auth_data.refresh_token' | sha256_text)"
    fi
  else
    if [[ -n $(printf '%s' "$account" | jq -r '.oauth_account.accountUuid // empty') ]]; then
      printf 'uuid:%s\n' "$(printf '%s' "$account" | jq -r '.oauth_account.accountUuid')"
    elif [[ -n $(printf '%s' "$account" | jq -r '.email // empty') ]]; then
      printf 'email:%s\n' "$(printf '%s' "$account" | jq -r '.email | ascii_downcase')"
    else
      token=$(printf '%s' "$account" | jq -r '.credentials.refreshToken')
      printf 'token:%s\n' "$(printf '%s' "$token" | sha256_text)"
    fi
  fi
}

sync_current_into_store() {
  local provider=$1 current index existing_id existing_name existing_created existing_last
  current=$(provider_current_account "$provider" false)
  [[ $current != null ]] || return
  index=$(provider_match_index "$provider" "$current")
  (( index >= 0 )) || return
  existing_id=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].id')
  existing_name=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].name')
  existing_created=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].created_at')
  existing_last=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" '.accounts[$index].last_used_at // null')
  current=$(printf '%s' "$current" | jq -c \
    --arg id "$existing_id" --arg name "$existing_name" --arg created "$existing_created" \
    --argjson last "$existing_last" '.id=$id | .name=$name | .created_at=$created | .last_used_at=$last')
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" \
    --slurpfile current <(printf '%s\n' "$current") \
    --arg id "$existing_id" '.accounts[$index]=$current[0] | .active_account_id=$id')
}

write_codex_account() {
  local account auth path
  account=$(cat)
  path=$(codex_auth_path)
  if [[ $(printf '%s' "$account" | jq -r '.auth_mode') == api_key ]]; then
    auth=$(printf '%s' "$account" | jq -c '{auth_mode:"api_key",OPENAI_API_KEY:.auth_data.key}')
  else
    auth=$(printf '%s' "$account" | jq -c --arg now "$(utc_now)" '{
      auth_mode: "chatgpt", OPENAI_API_KEY: null,
      tokens: ({
        id_token: .auth_data.id_token,
        access_token: .auth_data.access_token,
        refresh_token: .auth_data.refresh_token
      } + (if (.auth_data.account_id // "") == "" then {} else {account_id:.auth_data.account_id} end)),
      last_refresh: $now
    }')
  fi
  atomic_private_write "$path" "$auth"
}

write_claude_account() {
  local account credentials_path state_path credentials_document state oauth_type
  account=$(cat)
  credentials_path=$(claude_credentials_path)
  state_path=$(claude_state_path)
  if [[ -f $credentials_path && ! -L $credentials_path ]]; then
    credentials_document=$(jq -c 'if type == "object" then . else {} end' "$credentials_path" 2>/dev/null || printf '{}')
  else
    credentials_document='{}'
  fi
  credentials_document=$(printf '%s' "$credentials_document" | jq -c \
    --slurpfile account <(printf '%s\n' "$account") '.claudeAiOauth=$account[0].credentials')
  atomic_preserving_write "$credentials_path" "$credentials_document"

  oauth_type=$(printf '%s' "$account" | jq -r '.oauth_account | type')
  [[ $oauth_type == object ]] || return
  if [[ -f $state_path && ! -L $state_path ]]; then
    state=$(jq -c 'if type == "object" then . else {} end' "$state_path" 2>/dev/null || printf '{}')
  else
    state='{}'
  fi
  state=$(printf '%s' "$state" | jq -c --slurpfile account <(printf '%s\n' "$account") \
    '.oauthAccount=$account[0].oauth_account')
  atomic_preserving_write "$state_path" "$state"
}

switch_account() {
  local provider=$1 account_id=$2 store_path target current target_identity current_identity count now name
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  target=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $target ]] || fail "Account not found"
  sync_current_into_store "$provider"
  target=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '.accounts[] | select(.id == $id)' | head -n 1)
  current=$(provider_current_account "$provider" false)
  target_identity=$(printf '%s' "$target" | account_identity "$provider")
  if [[ $current == null ]]; then current_identity=''; else current_identity=$(printf '%s' "$current" | account_identity "$provider"); fi
  if [[ $target_identity != "$current_identity" ]]; then
    count=$(running_count "$provider")
    if (( count > 0 )); then
      atomic_private_write "$store_path" "$STORE_JSON"
      fail "Close $count active ${provider^} session$([[ $count == 1 ]] || printf s) before switching"
    fi
    if [[ $provider == codex ]]; then printf '%s' "$target" | write_codex_account; else printf '%s' "$target" | write_claude_account; fi
  fi
  now=$(utc_now)
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg now "$now" '
    .active_account_id=$id | .accounts |= map(if .id == $id then .last_used_at=$now else . end)')
  atomic_private_write "$store_path" "$STORE_JSON"
  name=$(printf '%s' "$target" | jq -r '.name')
  jq -cn --arg message "Switched to $name" '{ok: true, message: $message}'
}

rename_account() {
  local provider=$1 account_id=$2 name=$3 store_path count
  [[ -n ${name//[[:space:]]/} ]] || fail "Account name cannot be empty"
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  count=$(printf '%s' "$STORE_JSON" | jq -r --arg id "$account_id" '[.accounts[] | select(.id == $id)] | length')
  (( count > 0 )) || fail "Account not found"
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg name "$name" \
    '.accounts |= map(if .id == $id then .name=$name else . end)')
  atomic_private_write "$store_path" "$STORE_JSON"
  jq -cn --arg message "Renamed account to $name" '{ok: true, message: $message}'
}

remove_account() {
  local provider=$1 account_id=$2 store_path before after
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  before=$(printf '%s' "$STORE_JSON" | jq '.accounts | length')
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '
    .accounts |= map(select(.id != $id)) |
    if .active_account_id == $id then .active_account_id=null else . end')
  after=$(printf '%s' "$STORE_JSON" | jq '.accounts | length')
  (( after < before )) || fail "Account not found"
  atomic_private_write "$store_path" "$STORE_JSON"
  jq -cn '{ok: true, message: "Removed saved account"}'
}

usage() {
  printf 'Usage: %s status | import-current PROVIDER [NAME] [--inactive] | switch PROVIDER ID | rename PROVIDER ID NAME | remove PROVIDER ID\n' "$0" >&2
  exit 2
}

main() {
  local command=${1:-}
  case $command in
    status)
      [[ $# == 1 ]] || usage
      combined_status
      ;;
    import-current)
      [[ $# -ge 2 ]] || usage
      local provider=$2 name='' activate=true argument
      shift 2
      for argument in "$@"; do
        if [[ $argument == --inactive ]]; then activate=false
        elif [[ -z $name ]]; then name=$argument
        else usage
        fi
      done
      [[ $provider == codex || $provider == claude ]] || fail "Unknown provider: $provider"
      import_current "$provider" "$name" "$activate"
      ;;
    switch)
      [[ $# == 3 ]] || usage
      switch_account "$2" "$3"
      ;;
    rename)
      [[ $# == 4 ]] || usage
      rename_account "$2" "$3" "$4"
      ;;
    remove)
      [[ $# == 3 ]] || usage
      remove_account "$2" "$3"
      ;;
    *) usage ;;
  esac
}

main "$@"
