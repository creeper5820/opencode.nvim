#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"

exec bash "$repo/tests/run.sh" tests/unit/completion/sources/sources_spec.lua
