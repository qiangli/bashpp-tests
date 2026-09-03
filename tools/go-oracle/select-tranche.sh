#!/usr/bin/env bash
# Emit the tranche-1 selection from the reviewed corpus inventory.
#
# The selection rule is mechanical, so the tranche can be REGENERATED and
# compared rather than trusted. Nothing here looks at whether a file passes:
# selecting on the outcome would make a green gate self-fulfilling, which is the
# same defect as inferring a fixture's status from its result.
#
#   1. Read docs/go-corpus/inventory.tsv (pinned, digest-checked).
#   2. Keep rows whose directory is one of the upstream runner's `dirs` — a
#      "<name>.dir" subdirectory holds inputs for a compiledir/rundir test, not
#      test cases, and must never be selected.
#   3. Keep rows whose action is in the tranche-1 action set.
#   4. Within each action, take the first N rows in lexicographic path order.
#   5. Emit path<TAB>action, sorted by path.
#
# Usage: select-tranche.sh [per-action-count]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INV="${GO_CORPUS_INVENTORY:-${ROOT}/docs/go-corpus/inventory.tsv}"
PER_ACTION="${1:-5}"

case "${PER_ACTION}" in ''|*[!0-9]*) echo "FATAL: per-action count must be an integer" >&2; exit 2 ;; esac
[ "${PER_ACTION}" -gt 0 ] || { echo "FATAL: per-action count must be positive" >&2; exit 2; }

# Kept in lockstep with upstreamDirs in tools/go-oracle/recipe.go, which is
# itself a copy of `dirs` in the pinned src/cmd/internal/testdir/testdir_test.go.
UPSTREAM_DIRS='. ken chan interface internal/runtime/sys syntax dwarf fixedbugs codegen abi typeparam typeparam/mdempsky arenas simd'
TRANCHE_ACTIONS='run build errorcheck compile compiledir rundir runoutput'

awk -F '\t' -v dirs="${UPSTREAM_DIRS}" -v actions="${TRANCHE_ACTIONS}" -v n="${PER_ACTION}" '
  BEGIN {
    split(dirs, d, " ");    for (i in d) okdir[d[i]] = 1
    split(actions, a, " "); for (i in a) okact[a[i]] = 1
  }
  $1 ~ /^#/ || NF == 0 { next }
  {
    path = $1; action = $2
    if (!okact[action]) next
    rel = path; sub(/^test\//, "", rel)
    slash = 0
    for (i = length(rel); i > 0; i--) if (substr(rel, i, 1) == "/") { slash = i; break }
    dir = (slash ? substr(rel, 1, slash - 1) : ".")
    if (!okdir[dir]) next
    if (taken[action]++ >= n) next
    print path "\t" action
  }
' "${INV}" | sort
