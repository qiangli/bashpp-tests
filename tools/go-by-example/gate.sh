#!/usr/bin/env bash
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Usage: gate.sh --candidate MANIFEST --bashy LAUNCHER [--evidence PATH]
#
# There is no default candidate. See docs/go-by-example/candidates.tsv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${ROOT}/tools/go-by-example/gbe.sh" gate "$@"
