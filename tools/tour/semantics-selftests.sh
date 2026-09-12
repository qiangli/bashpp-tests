#!/usr/bin/env bash
# Negative-first selftests for the reviewed semantic comparators.
# Sprint 118 / Story #4 / Story-ID 759341a95870; Go port Sprint 155 / S155.9 / 43af37063b09.
set -euo pipefail
. "$(dirname "$0")/tour-build.sh"
tour_build
exec "${TOUR_BIN}" semantics-selftests "$@"
