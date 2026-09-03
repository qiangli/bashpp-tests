#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

"${ROOT}/tools/go-corpus/validate.sh" >/dev/null

awk 'BEGIN { changed=0 } /^# source_sha256\t/ && !changed { print "# source_sha256\t0000000000000000000000000000000000000000000000000000000000000000"; changed=1; next } { print }' \
  "${ROOT}/docs/go-corpus/inventory.tsv" > "${tmp}/bad-header.tsv"
if GO_CORPUS_INVENTORY="${tmp}/bad-header.tsv" "${ROOT}/tools/go-corpus/validate.sh" >/dev/null 2>&1; then
  echo "expected validator to reject inventory header provenance drift" >&2
  exit 1
fi

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

awk 'BEGIN { first=""; second="" } /^#/ { print; next } first == "" { first=$0; next } second == "" { second=$0; print second; print first; next } { print }' \
  "${ROOT}/docs/go-corpus/inventory.tsv" > "${tmp}/unsorted.tsv"
if GO_CORPUS_INVENTORY="${tmp}/unsorted.tsv" "${ROOT}/tools/go-corpus/validate.sh" >/dev/null 2>&1; then
  echo "expected validator to reject inventory order drift" >&2
  exit 1
fi

awk 'BEGIN { done=0 } /^#/ { print; next } !done { sub("^test/", "src/"); done=1 } { print }' \
  "${ROOT}/docs/go-corpus/inventory.tsv" > "${tmp}/outside-test.tsv"
if GO_CORPUS_INVENTORY="${tmp}/outside-test.tsv" "${ROOT}/tools/go-corpus/validate.sh" >/dev/null 2>&1; then
  echo "expected validator to reject paths outside go/test" >&2
  exit 1
fi

awk -F '\t' 'BEGIN { OFS="\t"; done=0 } /^#/ { print; next } !done { $2 = ($2 == "none" ? "run" : "none"); done=1 } { print }' \
  "${ROOT}/docs/go-corpus/inventory.tsv" > "${tmp}/substituted-row.tsv"
if GO_CORPUS_INVENTORY="${tmp}/substituted-row.tsv" "${ROOT}/tools/go-corpus/validate.sh" >/dev/null 2>&1; then
  echo "expected validator to reject same-count inventory row substitution" >&2
  exit 1
fi

marker="${tmp}/target-invoked"
printf '#!/bin/sh\n: > %s\n' "${marker}" > "${tmp}/target"
chmod +x "${tmp}/target"
if GO_CORPUS_INVENTORY="${tmp}/missing-one.tsv" BASHY_BIN="${tmp}/target" \
  "${ROOT}/harness/run.sh" >/dev/null 2>&1; then
  echo "expected harness to fail when corpus validation fails" >&2
  exit 1
fi
if [ -e "${marker}" ]; then
  echo "harness invoked target after corpus validation failed" >&2
  exit 1
fi

echo "go-corpus validator self-tests OK"
