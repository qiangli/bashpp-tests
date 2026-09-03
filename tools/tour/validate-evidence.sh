#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec ruby "${ROOT}/tools/tour/evidence-validator.rb" "$@"
