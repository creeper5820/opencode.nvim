#!/usr/bin/env bash
# Run native diff view tests in a throwaway headless Neovim instance.
# Uses isolated XDG directories, shada and cwd; never touches user config.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP_ROOT="/tmp/opencode"
mkdir -p "$TMP_ROOT"
TMP="$(mktemp -d "$TMP_ROOT/diff-tests.XXXXXX")"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP/config" "$TMP/data" "$TMP/state/shada" "$TMP/cache" "$TMP/home" "$TMP/project" "$TMP/tmp" "$TMP/runtime"
chmod 700 "$TMP/runtime"

NVIM_BIN="$(command -v nvim || true)"
if [[ -z "$NVIM_BIN" ]]; then
  echo "nvim not found" >&2
  exit 1
fi

cd "$TMP/project"
status=0
env -i \
  HOME="$TMP/home" \
  XDG_CONFIG_HOME="$TMP/config" \
  XDG_DATA_HOME="$TMP/data" \
  XDG_STATE_HOME="$TMP/state" \
  XDG_CACHE_HOME="$TMP/cache" \
  XDG_RUNTIME_DIR="$TMP/runtime" \
  TMPDIR="$TMP/tmp" \
  NVIM_APPNAME="opencode-diff-test" \
  OPENCODE_DIFF_TEST_ROOT="$ROOT" \
  OPENCODE_DIFF_TEST_PROJECT="$TMP/project" \
  PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
  TERM=dumb \
  LANG=C.UTF-8 \
  "$NVIM_BIN" --headless --clean --noplugin -u NONE \
  -i "$TMP/state/shada/main.shada" -n \
  -l "$ROOT/tests/headless/tools/diff/run.lua" || status=$?

exit "$status"
