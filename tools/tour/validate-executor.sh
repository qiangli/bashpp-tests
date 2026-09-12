#!/usr/bin/env bash
# Offline gate over tests/tour/executor-results.jsonl.
# Sprint 118 / Story #4 / Story-ID 759341a95870; Go port Sprint 155 / S155.9 / 43af37063b09.
#
# TOUR_GATE_ROOT is deliberately NOT set here: the real gate always re-derives
# its reference pins from this repository. Only the selftests point it at a
# synthetic fixture tree.
set -euo pipefail
unset TOUR_GATE_ROOT
. "$(dirname "$0")/tour-build.sh"
tour_build
exec "${TOUR_BIN}" validate-executor "$@"
