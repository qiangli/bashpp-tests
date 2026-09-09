#!/usr/bin/env bash
# Produce tests/tour/executor-results.jsonl (tour-executor/v2).
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# Required:
#   BASHPP_BIN                candidate bashy launcher (the Makefile-built pair
#                             <bin> + <bin>.real)
#   TOUR_CANDIDATE_MANIFEST   the manager-supplied build manifest JSON; the
#                             candidate is authenticated against it verbatim by
#                             Corpus.authenticate_candidate and the run aborts
#                             if any digest or repository revision disagrees
#
# Optional: TOUR_ORACLE_REPEATS (default 7), TOUR_STEP_TIMEOUT (default 60),
# TOUR_EXECUTOR_EVIDENCE (durable raw-log/artifact root), TOUR_ONLY (marks the
# ledger partial, which the gate rejects).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${BASHPP_BIN:?BASHPP_BIN must name the candidate bashy launcher}"
: "${TOUR_CANDIDATE_MANIFEST:?TOUR_CANDIDATE_MANIFEST must name the manager-supplied candidate manifest}"
exec ruby "${ROOT}/tools/tour/executor-runner.rb" "$@"
