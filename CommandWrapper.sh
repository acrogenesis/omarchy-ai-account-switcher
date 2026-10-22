#!/bin/bash
# omarchy-ai-account-switcher command router v1

set -euo pipefail

provider=$(basename -- "$0")
if [[ $provider != codex && $provider != claude ]]; then
  echo "AI Account Switcher: unsupported command name: $provider" >&2
  exit 2
fi

find_real_command() {
  local self directory candidate resolved
  self=$(readlink -f -- "$0")
  while IFS= read -r directory; do
    [[ -n $directory ]] || directory=.
    candidate="$directory/$provider"
    [[ -x $candidate && ! -d $candidate ]] || continue
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || printf '%s' "$candidate")
    [[ $resolved != "$self" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  return 1
}

if ! real_command=$(find_real_command); then
  echo "AI Account Switcher: could not find the real $provider command" >&2
  exit 127
fi

# Installing account routing never opts in to permission bypass. Missing,
# malformed, or symlinked preferences preserve every provider argument.
config_dir="${OMARCHY_AI_SWITCHER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ai-account-switcher}"
permissions_file="$config_dir/command-permissions.json"
bypass=false
if [[ ! -L $config_dir && -f $permissions_file && ! -L $permissions_file ]] &&
  jq -es 'length == 1 and (.[0] | .version == 1 and .bypass == true)' "$permissions_file" >/dev/null 2>&1; then
  bypass=true
fi

# Only the separate, explicitly acknowledged opt-in changes automatic-review
# launches to bypass mode. Other explicit permission modes take precedence.
routed_argv=()
if [[ $bypass != true ]]; then
  routed_argv=("$@")
elif [[ $provider == claude ]]; then
  has_skip=0
  has_mode=0
  while (($#)); do
    case "$1" in
      --)
        routed_argv+=("$@")
        break
        ;;
      --dangerously-skip-permissions)
        has_skip=1
        routed_argv+=("$1")
        shift
        ;;
      --permission-mode)
        has_mode=1
        routed_argv+=("$1")
        if (($# >= 2)) && [[ $2 == auto ]]; then
          routed_argv+=(bypassPermissions)
          shift 2
        elif (($# >= 2)); then
          routed_argv+=("$2")
          shift 2
        else
          shift
        fi
        ;;
      --permission-mode=auto)
        has_mode=1
        routed_argv+=(--permission-mode=bypassPermissions)
        shift
        ;;
      --permission-mode=*)
        has_mode=1
        routed_argv+=("$1")
        shift
        ;;
      *)
        routed_argv+=("$1")
        shift
        ;;
    esac
  done
  if (( has_skip == 0 && has_mode == 0 )); then
    routed_argv=(--dangerously-skip-permissions "${routed_argv[@]}")
  fi
elif [[ $provider == codex ]]; then
  has_bypass=0
  has_mode=0
  while (($#)); do
    case "$1" in
      --)
        routed_argv+=("$@")
        break
        ;;
      --dangerously-bypass-approvals-and-sandbox)
        has_bypass=1
        routed_argv+=("$1")
        shift
        ;;
      --approve-for-me)
        shift
        ;;
      -s|--sandbox|-a|--ask-for-approval)
        has_mode=1
        routed_argv+=("$1")
        shift
        if (($#)); then
          routed_argv+=("$1")
          shift
        fi
        ;;
      --sandbox=*|--ask-for-approval=*|-s?*|-a?*)
        has_mode=1
        routed_argv+=("$1")
        shift
        ;;
      *)
        routed_argv+=("$1")
        shift
        ;;
    esac
  done
  if (( has_bypass == 0 && has_mode == 0 )); then
    routed_argv=(--dangerously-bypass-approvals-and-sandbox "${routed_argv[@]}")
  fi
else
  routed_argv=("$@")
fi

# An explicit provider home always wins. This keeps nested sessions and the
# isolated add-account login flow pinned to the home they started with.
if [[ $provider == codex && -n ${CODEX_HOME:-} ]] ||
  [[ $provider == claude && -n ${CLAUDE_CONFIG_DIR:-} ]]; then
  exec "$real_command" "${routed_argv[@]}"
fi

plugin_dir="${OMARCHY_AI_SWITCHER_PLUGIN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/acrogenesis.ai-account-switcher}"
helper="$plugin_dir/ai_accounts.sh"

if [[ -x $helper ]]; then
  set +e
  result=$(bash "$helper" prepare-launch "$provider" 2>/dev/null)
  result_status=$?
  set -e
  if (( result_status == 0 )) && home=$(jq -er '.home' <<<"$result" 2>/dev/null); then
    if [[ $provider == codex ]]; then export CODEX_HOME="$home"
    else export CLAUDE_CONFIG_DIR="$home"
    fi
  fi
fi

exec "$real_command" "${routed_argv[@]}"
