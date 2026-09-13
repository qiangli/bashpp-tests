#!/usr/bin/env bash
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Re-derive docs/go-by-example/inventory.tsv from the authored classification
# table plus the measured bytes of the copied corpus.
#
#   refresh.sh [--inventory-only] [GBE_ROOT]
#
# The inventory is a pure function of (classification.tsv, copied file bytes).
# With GBE_ROOT — a clone of mmcgrana/gobyexample checked out at the pinned
# commit — the tool additionally proves the copy against upstream: it derives
# the upstream `examples/**/*.go` set, checks it against the classification
# table's program rows, and byte-compares every copied file with its source.
#
# --inventory-only writes the derived inventory to stdout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${ROOT}/tools/go-by-example/gbe.sh" refresh "$@"
