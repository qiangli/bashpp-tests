#!/usr/bin/env bash
# Deterministic process used only by production-path mutation tests. The tests
# repin a private repository copy to this file; the production repository pin
# remains authoritative and unchanged.
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "go-by-example mutation fixture"
  exit 0
fi
if [[ "${1:-}" == "--bashpp" && "${2:-}" == "--compile" ]]; then
  cp "$0" "$4"
  chmod +x "$4"
  exit 0
fi
# It also stands in for the already-authenticated Go executable after a test
# mutates the private gate copy. Blank, successful output makes all three modes
# agree unless that mutation deliberately changes one production command.
exit 0
