#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/tour/pin.tsv"
INV="${TOUR_INVENTORY:-${ROOT}/tests/tour/inventory.tsv}"
EXC="${ROOT}/docs/tour/standing-exceptions.tsv"
SCHEMA="${ROOT}/docs/tour/differential-schema.tsv"

die() {
  echo "FATAL: $*" >&2
  exit 2
}

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r repo ref commit license provenance expected_rows inventory_data_sha256 <<<"${pin_row}"

[ "${repo:-}" = "golang.org/x/website/tour" ] || die "pin repo must be official golang/tour"
[ "${ref:-}" = "master" ] || die "pin ref must record reviewed upstream branch"
case "${commit:-}" in *[!0-9a-f]*|'') die "pin commit must be lowercase hex" ;; esac
[ "${#commit}" -eq 40 ] || die "pin commit must be 40 hex characters"
[ "${license:-}" = "BSD-3-Clause" ] || die "pin license must preserve upstream BSD-3-Clause provenance"
[ -n "${provenance:-}" ] || die "pin provenance is required"
case "${expected_rows:-}" in ''|*[!0-9]*) die "pin inventory_rows must be an integer" ;; esac
[ "${expected_rows}" -gt 0 ] || die "pin inventory_rows must be positive"
case "${inventory_data_sha256:-}" in *[!0-9a-f]*|'') die "pin inventory_data_sha256 must be lowercase hex" ;; esac
[ "${#inventory_data_sha256}" -eq 64 ] || die "pin inventory_data_sha256 must be 64 hex characters"

[ -f "${INV}" ] || die "missing tour inventory: ${INV}"
[ -f "${EXC}" ] || die "missing Sprint 98 standing exception table: ${EXC}"
[ -f "${SCHEMA}" ] || die "missing differential schema table: ${SCHEMA}"

expect_header() {
  local key="$1" want="$2" got
  got="$(awk -F '\t' -v key="# ${key}" '$1 == key { print $2; found=1; exit } END { if (!found) exit 1 }' "${INV}")" \
    || die "inventory missing # ${key} header"
  [ "${got}" = "${want}" ] || die "inventory # ${key} header mismatch: expected ${want}, got ${got}"
}

expect_header release "golang/tour@${commit}"
expect_header source "https://go.googlesource.com/tour"
expect_header license "${license}"
expect_header generated_by "tools/tour/refresh.sh"

actual_inventory_data_sha256="$(awk '$0 !~ /^#/ && NF' "${INV}" | shasum -a 256 | awk '{print $1}')"
[ "${actual_inventory_data_sha256}" = "${inventory_data_sha256}" ] || \
  die "inventory data sha256 mismatch: expected ${inventory_data_sha256}, got ${actual_inventory_data_sha256}"

rows="$(awk -F '\t' '$1 !~ /^#/ && NF { count++ } END { print count + 0 }' "${INV}")"
[ "${rows}" -eq "${expected_rows}" ] || die "inventory denominator mismatch: expected ${expected_rows}, got ${rows}"

allowed_exceptions="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1 }' "${EXC}" | tr '\n' ' ')"

awk -F '\t' -v allowed_exceptions="${allowed_exceptions}" '
  BEGIN {
    split(allowed_exceptions, excs, " ")
    for (i in excs) allowed_exc[excs[i]]=1
  }
  $1 ~ /^#/ || NF == 0 { next }
  NF != 8 { printf "FATAL: malformed tour inventory row %d\n", NR > "/dev/stderr"; bad=1; next }
  $1 ~ /^(docs|tests|tools)\/go-corpus\// { printf "FATAL: row uses run #2 Go corpus ownership at %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  seen[$1]++ { printf "FATAL: duplicate tour inventory path at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  prev != "" && $1 <= prev { printf "FATAL: inventory path order regression at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  $2 !~ /^(go_package_source|go_test_source|markdown_code_program)$/ { printf "FATAL: invalid kind at row %d: %s\n", NR, $2 > "/dev/stderr"; bad=1 }
  $3 !~ /^(n\/a|[0-9]+)$/ { printf "FATAL: invalid start_line at row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1 }
  $4 !~ /^(applicable_go_program|not_applicable_support_package|excluded_fragment|excluded_external_dependency)$/ { printf "FATAL: invalid applicability at row %d: %s\n", NR, $4 > "/dev/stderr"; bad=1 }
  $5 !~ /^exception:[a-z_]+$/ { printf "FATAL: invalid exception syntax at row %d: %s\n", NR, $5 > "/dev/stderr"; bad=1 }
  {
    ex=$5
    sub(/^exception:/, "", ex)
    if (!allowed_exc[ex]) { printf "FATAL: row %d cites non-standing Sprint 98 exception: %s\n", NR, ex > "/dev/stderr"; bad=1 }
    if ($4 ~ /^excluded_/ && ex == "none") { printf "FATAL: row %d excludes without a standing exception\n", NR > "/dev/stderr"; bad=1 }
    if ($4 !~ /^excluded_/ && ex != "none") { printf "FATAL: row %d cites exception for non-excluded row\n", NR > "/dev/stderr"; bad=1 }
  }
  $6 !~ /^baseline:(go-test-or-build|go-run|syntax-context-only);bpp_interpreted:(parse-or-run|parse-run|not-run);bpp_compiled:(transpile-build-run|not-run)$/ {
    printf "FATAL: invalid differential schema at row %d: %s\n", NR, $6 > "/dev/stderr"; bad=1
  }
  $0 ~ /PLANNED/ { printf "FATAL: PLANNED is not a valid tour inventory state at row %d\n", NR > "/dev/stderr"; bad=1 }
  $7 !~ /^[0-9]+$/ || $7 == 0 { printf "FATAL: invalid byte count at row %d: %s\n", NR, $7 > "/dev/stderr"; bad=1 }
  $8 !~ /^[0-9a-f]{64}$/ { printf "FATAL: invalid sha256 at row %d: %s\n", NR, $8 > "/dev/stderr"; bad=1 }
  { prev=$1 }
  END { exit bad ? 1 : 0 }
' "${INV}"

if [ -n "${TOUR_ROOT:-}" ]; then
  [ -d "${TOUR_ROOT}" ] || die "TOUR_ROOT is not a directory: ${TOUR_ROOT}"
  [ -f "${TOUR_ROOT}/LICENSE" ] || die "TOUR_ROOT is missing upstream LICENSE"
  if command -v git >/dev/null 2>&1 && [ -d "${TOUR_ROOT}/.git" ]; then
    actual_commit="$(git -C "${TOUR_ROOT}" rev-parse HEAD)"
    [ "${actual_commit}" = "${commit}" ] || die "TOUR_ROOT commit mismatch: expected ${commit}, got ${actual_commit}"
  fi
  "${ROOT}/tools/tour/refresh.sh" --inventory-only "${TOUR_ROOT}" | diff -u "${INV}" - || \
    die "TOUR_ROOT-derived inventory differs from checked-in inventory"
fi

echo "Go tour inventory OK: ${commit} ${rows}/${expected_rows}"
