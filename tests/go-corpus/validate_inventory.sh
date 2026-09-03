#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

"${ROOT}/tools/go-corpus/validate.sh" >/dev/null

awk 'BEGIN { done=0 } /^#/ { print; next } !done { done=1; next } { print }' \
  "${ROOT}/docs/go-corpus/inventory.tsv" > "${tmp}/missing-one.tsv"
if GO_CORPUS_INVENTORY="${tmp}/missing-one.tsv" "${ROOT}/tools/go-corpus/validate.sh" >/dev/null 2>&1; then
  echo "expected validator to reject a missing inventory row" >&2
  exit 1
fi

awk 'BEGIN { done=0 } /^#/ { print; next } !done { print $0; print $0; done=1; next } { print }' \
  "${ROOT}/docs/go-corpus/inventory.tsv" > "${tmp}/duplicate.tsv"
if GO_CORPUS_INVENTORY="${tmp}/duplicate.tsv" "${ROOT}/tools/go-corpus/validate.sh" >/dev/null 2>&1; then
  echo "expected validator to reject a duplicate inventory row" >&2
  exit 1
fi

echo "go-corpus validator self-tests OK"
