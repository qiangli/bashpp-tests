#!/usr/bin/env bash
# Structural + replay validation of tests/tour/evidence.jsonl (harness-wired).
# Go port Sprint 155 / S155.9 / 43af37063b09.
set -euo pipefail
. "$(dirname "$0")/tour-build.sh"
tour_build
exec "${TOUR_BIN}" validate-evidence "$@"
