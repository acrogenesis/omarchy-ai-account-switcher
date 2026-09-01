#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_DISTROBOX_LOG"

if [[ ${1:-} != enter || ${3:-} != -- ]]; then
  echo "Unexpected fake distrobox command: $*" >&2
  exit 2
fi

shift 3
exec "$@"
