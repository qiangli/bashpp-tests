#!/usr/bin/env bash
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
# P0 structural gate. Compiled parity is intentionally run separately.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"${ROOT}/tools/lowering/identity_manifest.rb"
"${ROOT}/tests/lowering/identity_manifest_test.rb"
"${ROOT}/tests/lowering/differential_contract_test.rb"
echo 'Sprint 117 lowering P0 structural gate PASS: manifest and fail-closed contracts validated'
