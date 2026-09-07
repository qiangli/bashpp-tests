#!/usr/bin/env bash
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
# Compatibility wrapper for the configured Ruby entrypoint.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ruby "${ROOT}/tools/lowering/validate.rb" "$@"
