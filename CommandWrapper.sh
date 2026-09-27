#!/bin/bash
# omarchy-ai-account-switcher command router v1 + yolo flags

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

# Default routed sessions to full permission bypass, including launches using
# Omarchy's automatic-review flags. Explicit permission modes take precedence.
yolo_argv=()
if [[ $provider == claude ]]; then
  has_skip=0
  has_mode=0
  while (($#)); do
    case "$1" in
      --)
        yolo_argv+=("$@")
        break
        ;;
      --dangerously-skip-permissions)
        has_skip=1
        yolo_argv+=("$1")
        shift
        ;;
      --permission-mode)
        has_mode=1
        yolo_argv+=("$1")
        if (($# >= 2)) && [[ $2 == auto ]]; then
          yolo_argv+=(bypassPermissions)
          shift 2
        elif (($# >= 2)); then
          yolo_argv+=("$2")
          shift 2
        else
          shift
        fi
        ;;
      --permission-mode=auto)
        has_mode=1
        yolo_argv+=(--permission-mode=bypassPermissions)
        shift
        ;;
      --permission-mode=*)
        has_mode=1
        yolo_argv+=("$1")
        shift
        ;;
      *)
        yolo_argv+=("$1")
        shift
        ;;
    esac
  done
  if (( has_skip == 0 && has_mode == 0 )); then
    yolo_argv=(--dangerously-skip-permissions "${yolo_argv[@]}")
  fi
elif [[ $provider == codex ]]; then
  has_bypass=0
  has_mode=0
  while (($#)); do
    case "$1" in
      --)
        yolo_argv+=("$@")
        break
        ;;
      --dangerously-bypass-approvals-and-sandbox)
        has_bypass=1
        yolo_argv+=("$1")
        shift
        ;;
      --approve-for-me)
        shift
        ;;
      -s|--sandbox|-a|--ask-for-approval)
        has_mode=1
        yolo_argv+=("$1")
        shift
        if (($#)); then
          yolo_argv+=("$1")
          shift
        fi
        ;;
      --sandbox=*|--ask-for-approval=*|-s?*|-a?*)
        has_mode=1
        yolo_argv+=("$1")
        shift
        ;;
      *)
        yolo_argv+=("$1")
        shift
        ;;
    esac
  done
  if (( has_bypass == 0 && has_mode == 0 )); then
    yolo_argv=(--dangerously-bypass-approvals-and-sandbox "${yolo_argv[@]}")
  fi
else
  yolo_argv=("$@")
fi

# An explicit provider home always wins. This keeps nested sessions and the
# isolated add-account login flow pinned to the home they started with.
if [[ $provider == codex && -n ${CODEX_HOME:-} ]] ||
  [[ $provider == claude && -n ${CLAUDE_CONFIG_DIR:-} ]]; then
  exec "$real_command" "${yolo_argv[@]}"
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

exec "$real_command" "${yolo_argv[@]}"
