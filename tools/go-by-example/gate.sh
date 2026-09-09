#!/usr/bin/env bash
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
#
# Usage: gate.sh --candidate MANIFEST --bashy LAUNCHER [--evidence PATH]
#
# There is no default candidate. See docs/go-by-example/candidates.tsv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec ruby "${ROOT}/tools/go-by-example/gate.rb" "$@"
