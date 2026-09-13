#!/usr/bin/env bash
# Tamper self-tests for the tour-executor ledger and its offline gate.
# Sprint 118 / Story #4 / Story-ID 759341a95870; Go port Sprint 155 / S155.9 / 43af37063b09.
#
# Takes the committed tests/tour/executor-results.jsonl (or the ledger given as
# $1), mutates exactly one recorded fact per probe, reseals the ledger and
# requires the REAL gate to emit the expected finding. Each probe is
# DIFFERENTIAL: the finding must be absent on the pristine ledger and present
# after the mutation.
#
# Usage: tools/tour/executor-tamper-tests.sh [ledger]
set -uo pipefail
export LC_ALL=C
. "$(dirname "$0")/tour-build.sh"
tour_build || exit 2
exec "${TOUR_BIN}" executor-tamper-tests "$@"
