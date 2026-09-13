#!/usr/bin/env bash
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Usage: gbe.sh <subcommand> [args...]
#
# Entry point for the Go program in tools/go-by-example/gbe: builds it with the
# pinned toolchain (build.sh) and execs the subcommand with GBE_ROOT bound to
# this checkout. gate.sh, validate.sh, refresh.sh and tamper-tests.sh keep
# their names and CLIs and route through here; the validators that had no
# wrapper (validate-candidate, validate-evidence, validate-bounded-evidence,
# summarize, tamper-retained-evidence, bounded-evidence-selftests) are reached
# as subcommands.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$("${ROOT}/tools/go-by-example/build.sh")" || exit 2
GBE_ROOT="${ROOT}" exec "${BIN}" "$@"
