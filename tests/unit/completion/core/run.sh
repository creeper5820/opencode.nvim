#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
mkdir -p /tmp/opencode
tmp="$(mktemp -d /tmp/opencode/completion-core-unit.XXXXXX)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
export TMPDIR="$tmp/tmp"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_DATA_HOME="$tmp/data"
export XDG_STATE_HOME="$tmp/state"
export XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

NVIM="${NVIM:-nvim}"
"$NVIM" --headless --clean -i NONE --noplugin \
  -u NONE \
  -l "$repo/tests/unit/completion/core/run.lua"
