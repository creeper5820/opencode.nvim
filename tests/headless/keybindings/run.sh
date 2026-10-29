#!/usr/bin/env bash
# Run semantic keybinding tests in a throwaway headless Neovim instance.
# HOME, XDG_* directories, shada, TMPDIR and the working directory all point
# inside a unique /tmp/opencode directory; user configuration is never read.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
base="/tmp/opencode"
mkdir -p "$base"
tmp="$(mktemp -d "$base/keybindings-headless.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

mkdir -p "$tmp"/{home,config,data,state/shada,cache,tmp,project,runtime}
chmod 700 "$tmp/runtime"

nvim_bin="$(command -v nvim || true)"
if [[ -z "$nvim_bin" ]]; then
  echo "nvim not found" >&2
  exit 1
fi

status=0
cd "$tmp/project"
env -i \
  HOME="$tmp/home" \
  XDG_CONFIG_HOME="$tmp/config" \
  XDG_DATA_HOME="$tmp/data" \
  XDG_STATE_HOME="$tmp/state" \
  XDG_CACHE_HOME="$tmp/cache" \
  XDG_RUNTIME_DIR="$tmp/runtime" \
  TMPDIR="$tmp/tmp" \
  NVIM_APPNAME="opencode-keybindings-headless" \
  PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
  TERM=dumb \
  LANG=C.UTF-8 \
  "$nvim_bin" --headless --clean --noplugin -u NONE -i "$tmp/state/shada/main.shada" -n \
  -l "$repo/tests/headless/keybindings/run.lua" || status=$?

exit "$status"
