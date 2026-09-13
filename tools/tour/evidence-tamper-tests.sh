#!/usr/bin/env bash
# Synthetic-equality, baseline-cloning and provenance forgery probes for
# tools/tour/validate-evidence.sh. Go port Sprint 155 / S155.9 / 43af37063b09.
#
# Usage: tools/tour/evidence-tamper-tests.sh [ledger]
set -euo pipefail
. "$(dirname "$0")/tour-build.sh"
tour_build
exec "${TOUR_BIN}" evidence-tamper-tests "$@"
