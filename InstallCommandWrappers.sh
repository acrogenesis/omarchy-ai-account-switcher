#!/bin/bash

set -Eeu -o pipefail

plugin_dir="${OMARCHY_AI_SWITCHER_PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
wrapper_source="$plugin_dir/CommandWrapper.sh"
config_dir="${OMARCHY_AI_SWITCHER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ai-account-switcher}"
bin_dir="${OMARCHY_AI_SWITCHER_BIN_DIR:-$HOME/.local/bin}"
backup_dir="$config_dir/wrapper-backups"
marker='omarchy-ai-account-switcher command router v1'
mise_marker='omarchy-ai-account-switcher mise aliases v1'
mise_conf_dir="${OMARCHY_AI_SWITCHER_MISE_CONF_DIR:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/conf.d}"
mise_fragment="$mise_conf_dir/omarchy-ai-account-switcher.toml"
mise_backup="$backup_dir/mise-conf-fragment.toml"

fail() {
  jq -cn --arg error "$1" '{ok: false, error: $error}'
  exit 1
}

is_our_wrapper() {
  [[ -f $1 && ! -L $1 ]] && grep -Fq "$marker" "$1" 2>/dev/null
}

is_our_mise_fragment() {
  [[ -f $1 && ! -L $1 ]] && grep -Fq "$mise_marker" "$1" 2>/dev/null
}

ensure_directory() {
  local path=$1 mode=$2
  if [[ -L $path || ( -e $path && ! -d $path ) ]]; then fail "Refusing unsafe directory: $path"; fi
  mkdir -p -- "$path"
  chmod "$mode" -- "$path"
}

install_wrapper() {
  local provider=$1 target backup temporary
  target="$bin_dir/$provider"
  backup="$backup_dir/$provider"
  if [[ ( -e $target || -L $target ) ]] && ! is_our_wrapper "$target" && [[ ! -e $backup && ! -L $backup ]]; then
    cp -a -- "$target" "$backup"
  fi
  temporary=$(mktemp "$bin_dir/.${provider}.ai-switcher.XXXXXX")
  cp -- "$wrapper_source" "$temporary"
  chmod 755 -- "$temporary"
  mv -fT -- "$temporary" "$target"
}

preflight_install() {
  local provider=$1 target backup
  target="$bin_dir/$provider"
  backup="$backup_dir/$provider"
  [[ ! -d $target ]] || fail "Refusing to replace directory: $target"
  if [[ ( -e $target || -L $target ) ]] && ! is_our_wrapper "$target" &&
    [[ -e $backup || -L $backup ]]; then
    fail "Refusing to overwrite a changed command while its previous backup exists: $target"
  fi
}

preflight_mise_fragment() {
  [[ ! -d $mise_fragment ]] || fail "Refusing to replace directory: $mise_fragment"
  if [[ ( -e $mise_fragment || -L $mise_fragment ) ]] && ! is_our_mise_fragment "$mise_fragment" &&
    [[ -e $mise_backup || -L $mise_backup ]]; then
    fail "Refusing to overwrite a changed mise configuration while its previous backup exists: $mise_fragment"
  fi
}

install_mise_fragment() {
  local temporary codex_command claude_command
  if [[ ( -e $mise_fragment || -L $mise_fragment ) ]] && ! is_our_mise_fragment "$mise_fragment" &&
    [[ ! -e $mise_backup && ! -L $mise_backup ]]; then
    cp -a -- "$mise_fragment" "$mise_backup"
  fi
  printf -v codex_command '%q' "$bin_dir/codex"
  printf -v claude_command '%q' "$bin_dir/claude"
  temporary=$(mktemp "$mise_conf_dir/.omarchy-ai-account-switcher.XXXXXX")
  {
    printf '# %s\n' "$mise_marker"
    printf '[shell_alias]\n'
    printf 'codex = %s\n' "$(jq -cn --arg value "$codex_command" '$value')"
    printf 'claude = %s\n' "$(jq -cn --arg value "$claude_command" '$value')"
  } >"$temporary"
  chmod 600 -- "$temporary"
  mv -fT -- "$temporary" "$mise_fragment"
}

remove_mise_fragment() {
  if [[ -e $mise_backup || -L $mise_backup ]]; then
    if [[ -e $mise_fragment || -L $mise_fragment ]]; then
      is_our_mise_fragment "$mise_fragment" || fail "Refusing to replace changed mise configuration: $mise_fragment"
      rm -f -- "$mise_fragment"
    fi
    mv -T -- "$mise_backup" "$mise_fragment"
  elif is_our_mise_fragment "$mise_fragment"; then
    rm -f -- "$mise_fragment"
  fi
}

remove_wrapper() {
  local provider=$1 target backup
  target="$bin_dir/$provider"
  backup="$backup_dir/$provider"
  if [[ -e $backup || -L $backup ]]; then
    if [[ -e $target || -L $target ]]; then
      is_our_wrapper "$target" || fail "Refusing to replace a changed command: $target"
      rm -f -- "$target"
    fi
    mv -T -- "$backup" "$target"
  elif is_our_wrapper "$target"; then
    rm -f -- "$target"
  fi
}

[[ -f $wrapper_source && ! -L $wrapper_source ]] || fail "Command wrapper source is unavailable"
ensure_directory "$config_dir" 700
ensure_directory "$backup_dir" 700
ensure_directory "$bin_dir" 755
ensure_directory "$mise_conf_dir" 700

case ${1:-install} in
  install)
    preflight_install codex
    preflight_install claude
    preflight_mise_fragment
    install_wrapper codex
    install_wrapper claude
    install_mise_fragment
    jq -cn '{ok: true, message: "Terminal commands now follow the selected accounts"}'
    ;;
  remove)
    remove_mise_fragment
    remove_wrapper codex
    remove_wrapper claude
    jq -cn '{ok: true, message: "Restored the previous terminal commands"}'
    ;;
  *) fail "Usage: InstallCommandWrappers.sh [install|remove]" ;;
esac
