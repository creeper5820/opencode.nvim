#!/usr/bin/env bash
# Run the Neovim Lua test suite in a disposable, isolated environment.
#
# Usage:
#   bash tests/run.sh                         # all tests/unit/**/*_spec.lua
#   bash tests/run.sh tests/unit/config       # one directory
#   bash tests/run.sh tests/unit/config/config_spec.lua
#
# Only explicitly exported OPENCODE_TEST_* variables are forwarded. All other
# user configuration (HOME, XDG_*, shada, temporary files) is replaced.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="/tmp/opencode"
root="$base/nvim-run-$$-$(date +%s%N)"
mkdir -p "$root"/{home,config,data,state/shada,cache,runtime,tmp,project,harness}
chmod 700 "$root/runtime"

child=""
descendants() {
  local parent="$1" pid
  for pid in $(ps -o pid= --ppid "$parent" 2>/dev/null || true); do
    descendants "$pid"
    printf '%s\n' "$pid"
  done
}

cleanup() {
  if [[ -n "$child" ]]; then
    # Neovim starts jobs in their own sessions, so a process-group kill alone
    # is not enough. Snapshot descendants while the test Neovim is still alive,
    # then terminate only that tree.
    local children=()
    local pid
    while IFS= read -r pid; do
      children+=("$pid")
    done < <(descendants "$child")

    kill -TERM -- "-$child" 2>/dev/null || true
    for pid in ${children[@]+"${children[@]}"}; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in {1..20}; do
      local alive=0
      if kill -0 -- "-$child" 2>/dev/null; then
        alive=1
      fi
      for pid in ${children[@]+"${children[@]}"}; do
        if kill -0 "$pid" 2>/dev/null; then
          alive=1
        fi
      done
      if [[ "$alive" -eq 0 ]]; then
        break
      fi
      sleep 0.05
    done
    kill -KILL -- "-$child" 2>/dev/null || true
    for pid in ${children[@]+"${children[@]}"}; do
      kill -KILL "$pid" 2>/dev/null || true
    done
    wait "$child" 2>/dev/null || true
  fi
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

nvim_bin="$(command -v nvim || true)"
if [[ -z "$nvim_bin" ]]; then
  echo "nvim not found" >&2
  exit 1
fi

extra_env=()
while IFS= read -r name; do
  if [[ "$name" == OPENCODE_TEST_* ]]; then
    extra_env+=("$name=${!name}")
  fi
done < <(compgen -e)

set -m
env -i \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  XDG_DATA_HOME="$root/data" \
  XDG_STATE_HOME="$root/state" \
  XDG_CACHE_HOME="$root/cache" \
  XDG_RUNTIME_DIR="$root/runtime" \
  TMPDIR="$root/tmp" \
  NVIM_APPNAME="opencode-test-runner" \
  OPENCODE_NVIM_TEST_BASE="$root/harness" \
  PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
  TERM=dumb \
  LANG=C.UTF-8 \
  ${extra_env[@]+"${extra_env[@]}"} \
  "$nvim_bin" --headless -n --noplugin -u "$repo/tests/minimal_init.lua" \
  -i "$root/state/shada/main.shada" -l "$repo/tests/run.lua" "$@" &
child=$!
set +m

status=0
wait "$child" || status=$?
child=""
exit "$status"
