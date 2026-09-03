#!/usr/bin/env bash
# Sprint: #98; Story: #198; Story-ID: fa07603b71dc
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec ruby "${ROOT}/tools/go-by-example/gate.rb" "$@"
