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
account_distrobox=$(jq -r '.distrobox // empty' <<<"$result")

if [[ $provider == codex ]]; then
  home_variable=CODEX_HOME
  cli=codex
  label=Codex
else
  home_variable=CLAUDE_CONFIG_DIR
  cli=claude
  label=Claude
fi

# An account marked with a distrobox opens inside that container, where the
# CLI, its policies, and its tooling live. The account home is passed as an
# absolute path, which distrobox's shared home keeps valid inside the box.
if [[ -n $account_distrobox ]]; then
  command -v distrobox >/dev/null 2>&1 || { echo "distrobox is not installed" >&2; exit 1; }
  printf '%s · %s (distrobox %s)\n\n' "$label" "$account_name" "$account_distrobox"
  exec distrobox enter "$account_distrobox" -- env "$home_variable=$account_home" "$cli"
fi

command -v "$cli" >/dev/null 2>&1 || { echo "$label is not installed" >&2; exit 1; }
printf '%s · %s\n\n' "$label" "$account_name"
export "$home_variable=$account_home"
exec "$cli"
