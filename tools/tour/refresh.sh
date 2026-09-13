#!/usr/bin/env bash
# Derive the tour inventory from the pinned golang.org/x/website source.
#
# Acquisition path (authoritative, offline-verifiable):
#   go install golang.org/x/website/tour@<version>
# The tour binary embeds lesson assets from _content/tour
# (content.go: //go:embed _content/tour). This script derives the
# denominator from those same assets, mirroring the upstream oracle
# content_test.go: first line must be a //go:build comment containing OMIT;
# nobuild => not built; norun => built but not executed.
#
# Fail-closed: unresolved references, unknown directives, missing go.mod /
# LICENSE, or any .go file that is neither .play-referenced nor a solution
# aborts the derivation. PLANNED is never emitted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/tour/pin.tsv"
SCHEMA="${ROOT}/docs/tour/differential-schema.tsv"
OUT="${ROOT}/tests/tour/inventory.tsv"
CACHE="${ROOT}/.cache/website/src"

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r _repo version commit go_mod_sum _license _provenance _rows _sha <<<"${pin_row}"

inventory_only=0
src="${CACHE}"
if [ "${1:-}" = "--inventory-only" ]; then
  inventory_only=1
  src="${2:?usage: tools/tour/refresh.sh --inventory-only WEBSITE_SRC_ROOT}"
fi

if [ "${inventory_only}" -eq 0 ]; then
  if [ ! -d "${src}/.git" ]; then
    mkdir -p "$(dirname "${src}")"
    git clone https://go.googlesource.com/website "${src}"
  fi
  git -C "${src}" fetch --depth 1 origin "${commit}"
  git -C "${src}" checkout --detach "${commit}"
fi

# The extractor is the Go harness (tools/tour/refresh.go, `tour refresh-inventory`);
# Sprint 155 / S155.9 / 43af37063b09 retired the inline Ruby it replaces.
. "${ROOT}/tools/tour/tour-build.sh"
tour_build
"${TOUR_BIN}" refresh-inventory "$src" "$version" "$commit" "$go_mod_sum" "$SCHEMA" > "${OUT}.tmp"

if [ "${inventory_only}" -eq 1 ]; then
  cat "${OUT}.tmp"
  rm -f "${OUT}.tmp"
else
  mv "${OUT}.tmp" "${OUT}"
  echo "refreshed ${OUT}; now update docs/tour/pin.tsv (rows + inventory_data_sha256) and run tools/tour/validate.sh" >&2
fi
