#!/usr/bin/env bash
# Run the isolated e2e suite with the repository test runner.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$repo/tests/run.sh" "$repo/tests/integration/e2e"
