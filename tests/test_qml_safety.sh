#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
panel="$project_dir/Panel.qml"
service="$project_dir/Service.qml"

text_blocks=$(rg --count '^[[:space:]]*Text \{' "$panel")
plain_text_declarations=$(rg --count '^[[:space:]]*textFormat: Text\.PlainText$' "$panel")

if [[ $text_blocks != "$plain_text_declarations" ]]; then
  printf 'Expected every Panel.qml Text block to declare Text.PlainText (%s blocks, %s declarations)\n' \
    "$text_blocks" "$plain_text_declarations" >&2
  exit 1
fi

rg --quiet 'maximumLength: 120' "$panel"
rg --quiet 'function boundedText\(' "$service"
rg --quiet 'root\.lastError = root\.boundedText' "$service"
rg --quiet 'root\.lastAction = root\.boundedText' "$service"
rg --quiet 'name: root\.boundedText\(value\.name, "Account", 120\)' "$service"

printf 'QML display safety checks passed\n'
