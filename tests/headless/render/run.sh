#!/usr/bin/env bash
# Run renderer tests in a throwaway headless Neovim instance.
# Uses isolated HOME/XDG directories, shada and cwd; never touches user config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_ROOT="/tmp/opencode"
mkdir -p "$TMP_ROOT"
TMP="$(mktemp -d "$TMP_ROOT/render-tests.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP"/{home,config,data,state,cache,tmp,project}

NVIM_BIN="$(command -v nvim || true)"
if [[ -z "$NVIM_BIN" ]]; then
  echo "nvim not found" >&2
  exit 1
fi

exec env -i \
  HOME="$TMP/home" \
  XDG_CONFIG_HOME="$TMP/config" \
  XDG_DATA_HOME="$TMP/data" \
  XDG_STATE_HOME="$TMP/state" \
  XDG_CACHE_HOME="$TMP/cache" \
  TMPDIR="$TMP/tmp" \
  NVIM_APPNAME="opencode-render-headless" \
  PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
  TERM=dumb \
  LANG=C.UTF-8 \
  "$NVIM_BIN" --headless -n -u NONE --noplugin -i "$TMP/shada" \
  --cmd "set runtimepath^=$ROOT" \
  -c "lua dofile('$ROOT/tests/headless/render/renderer_spec.lua')"
