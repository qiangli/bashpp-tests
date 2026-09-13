#!/usr/bin/env bash
# Produce tests/tour/evidence.jsonl (tour-evidence/v2, Sprint 98; superseded).
# Go port Sprint 155 / S155.9 / 43af37063b09.
set -euo pipefail
. "$(dirname "$0")/tour-build.sh"
tour_build
exec "${TOUR_BIN}" evidence "$@"
