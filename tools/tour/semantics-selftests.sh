#!/usr/bin/env bash
# Negative-first selftests for the reviewed semantic comparators.
# Sprint 118 / Story #4 / Story-ID 759341a95870.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec ruby "${ROOT}/tools/tour/semantics-selftests.rb" "$@"
