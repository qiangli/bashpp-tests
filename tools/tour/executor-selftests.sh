#!/usr/bin/env bash
# Selftests for the tour executor and its gate.
# Sprint 118 / Story #4 / Story-ID 759341a95870.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec ruby "${ROOT}/tools/tour/executor-selftests.rb" "$@"
