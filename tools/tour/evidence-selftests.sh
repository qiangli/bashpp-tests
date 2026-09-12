#!/usr/bin/env bash
# Real launch/deadline/process-tree probes for the evidence capture primitive.
# Go port Sprint 155 / S155.9 / 43af37063b09.
set -euo pipefail
. "$(dirname "$0")/tour-build.sh"
tour_build
exec "${TOUR_BIN}" evidence-selftests "$@"
