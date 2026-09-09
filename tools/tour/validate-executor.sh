#!/usr/bin/env bash
# Offline gate over tests/tour/executor-results.jsonl.
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# TOUR_GATE_ROOT is deliberately NOT set here: the real gate always re-derives
# its reference pins from this repository. Only the selftests point it at a
# synthetic fixture tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
unset TOUR_GATE_ROOT
exec ruby "${ROOT}/tools/tour/executor-gate.rb" "$@"
