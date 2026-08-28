#!/bin/bash

set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$plugin_dir/ai_accounts.sh"
provider=${1:-}
account_id=${2:-}

if [[ $provider != codex && $provider != claude ]]; then
  echo "Usage: $0 codex|claude [ACCOUNT_ID]" >&2
  exit 2
fi

result=$(bash "$helper" prepare-launch "$provider" "$account_id")
if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$result"; then
  jq -r '.error // "Could not prepare account"' <<<"$result" >&2
  exit 1
fi

account_home=$(jq -r '.home' <<<"$result")
account_name=$(jq -r '.name' <<<"$result")

if [[ $provider == codex ]]; then
  command -v codex >/dev/null 2>&1 || { echo "Codex is not installed" >&2; exit 1; }
  printf 'Codex · %s\n\n' "$account_name"
  export CODEX_HOME="$account_home"
  exec codex
else
  command -v claude >/dev/null 2>&1 || { echo "Claude is not installed" >&2; exit 1; }
  printf 'Claude · %s\n\n' "$account_name"
  export CLAUDE_CONFIG_DIR="$account_home"
  exec claude
fi
