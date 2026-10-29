#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
mkdir -p /tmp/opencode
tmp_root=$(mktemp -d /tmp/opencode/selection-tests.XXXXXX)
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$tmp_root/config" "$tmp_root/data" "$tmp_root/state/shada" \
  "$tmp_root/cache" "$tmp_root/home" "$tmp_root/project" "$tmp_root/tmp" "$tmp_root/runtime"
chmod 700 "$tmp_root/runtime"

nvim_bin=$(command -v nvim || true)
if [[ -z "$nvim_bin" ]]; then
  echo "nvim not found" >&2
  exit 1
fi

cd "$tmp_root/project"
status=0
env -i \
  HOME="$tmp_root/home" \
  XDG_CONFIG_HOME="$tmp_root/config" \
  XDG_DATA_HOME="$tmp_root/data" \
  XDG_STATE_HOME="$tmp_root/state" \
  XDG_CACHE_HOME="$tmp_root/cache" \
  XDG_RUNTIME_DIR="$tmp_root/runtime" \
  TMPDIR="$tmp_root/tmp" \
  NVIM_APPNAME="opencode-selection-test" \
  OPENCODE_SELECTION_TEST_ROOT="$repo_root" \
  PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
  TERM=dumb \
  LANG=C.UTF-8 \
  "$nvim_bin" --headless --clean --noplugin -u NONE \
  -i "$tmp_root/state/shada/main.shada" -n \
  -l "$repo_root/tests/headless/selection/run.lua" || status=$?

exit "$status"
