#!/usr/bin/env bash
# Fail-closed gate for the go.dev/tour inventory (golang.org/x/website pin).
#
# Validated without touching the live website: the pin records the module
# version, commit and go.mod sum; the inventory's own data hash pins every
# row; TOUR_ROOT re-derivation proves the denominator from a local source
# (git clone or module cache directory).
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
IFS=$'\t' read -r repo version commit go_mod_sum license provenance expected_rows inventory_data_sha256 <<<"${pin_row}"

[ "${repo:-}" = "golang.org/x/website" ] || die "pin repo must be golang.org/x/website (module owning go.dev/tour)"
case "${version:-}" in
  v0.0.0-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) die "pin version must be a golang.org/x/website pseudo-version (v0.0.0-<ts>-<12hex>)" ;;
esac
[ "${version##*-}" = "${commit:0:12}" ] || die "pin pseudo-version suffix must match the pinned commit prefix"
case "${commit:-}" in *[!0-9a-f]*|'') die "pin commit must be lowercase hex" ;; esac
[ "${#commit}" -eq 40 ] || die "pin commit must be 40 hex characters"
case "${go_mod_sum:-}" in h1:*=) ;; *) die "pin go_mod_sum must be an h1: module hash" ;; esac
[ "${#go_mod_sum}" -eq 47 ] || die "pin go_mod_sum must be h1:<44 base64 chars> (got ${#go_mod_sum})"
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

expect_header release "golang.org/x/website@${version}"
expect_header commit "${commit}"
expect_header go_mod_sum "${go_mod_sum}"
expect_header source "https://go.googlesource.com/website"
expect_header license "${license}"
expect_header generated_by "tools/tour/refresh.sh"

actual_inventory_data_sha256="$(awk '$0 !~ /^#/ && NF' "${INV}" | shasum -a 256 | awk '{print $1}')"
[ "${actual_inventory_data_sha256}" = "${inventory_data_sha256}" ] || \
  die "inventory data sha256 mismatch: expected ${inventory_data_sha256}, got ${actual_inventory_data_sha256}"

rows="$(awk -F '\t' '$1 !~ /^#/ && NF { count++ } END { print count + 0 }' "${INV}")"
[ "${rows}" -eq "${expected_rows}" ] || die "inventory denominator mismatch: expected ${expected_rows}, got ${rows}"

allowed_exceptions="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1 }' "${EXC}" | tr '\n' ' ')"

# The differential schema table is the single source of truth: vocabularies
# and applicability coupling are loaded from it, not hardcoded here.
schema_out="$(awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  NF == 3 && ($1 == "baseline" || $1 == "bpp_interpreted" || $1 == "bpp_compiled") { vocab[$1] = $2; next }
  NF == 2 && $1 !~ /^(baseline|bpp_interpreted|bpp_compiled)$/ { couple[$1] = $2; next }
  { printf "FATAL: malformed differential schema row %d in %s\n", NR, FILENAME > "/dev/stderr"; bad = 1 }
  END {
    split("baseline bpp_interpreted bpp_compiled", modes, " ")
    for (j = 1; j <= 3; j++) if (!vocab[modes[j]]) { printf "FATAL: differential schema vocabularies incomplete\n" > "/dev/stderr"; bad = 1 }
    n = 0
    for (a in couple) n++
    if (n < 1) { printf "FATAL: differential schema applicability coupling empty\n" > "/dev/stderr"; bad = 1 }
    re = "^baseline:(" vocab["baseline"] ");bpp_interpreted:(" vocab["bpp_interpreted"] ");bpp_compiled:(" vocab["bpp_compiled"] ")$"
    gsub(/,/, "|", re)
    for (a in couple) if (couple[a] !~ re) { printf "FATAL: differential schema coupling for %s is outside the vocabularies\n", a > "/dev/stderr"; bad = 1 }
    if (bad) exit 1
    print re
    join = ""
    for (a in couple) join = join a "=" couple[a] ","
    sub(/,$/, "", join)
    print join
  }
' "${SCHEMA}")" || die "differential schema table is malformed or incomplete: ${SCHEMA}"

schema_regex="$(sed -n '1p' <<<"${schema_out}")"
schema_couples="$(sed -n '2p' <<<"${schema_out}")"
[ -n "${schema_couples}" ] || die "differential schema table declares no applicability coupling"

awk -F '\t' \
  -v allowed_exceptions="${allowed_exceptions}" \
  -v schema_regex="${schema_regex}" \
  -v schema_couples="${schema_couples}" '
  BEGIN {
    split(allowed_exceptions, excs, " ")
    for (i in excs) allowed_exc[excs[i]] = 1
    n = split(schema_couples, pairs, ",")
    for (k = 1; k <= n; k++) {
      eq = index(pairs[k], "=")
      couple[substr(pairs[k], 1, eq - 1)] = substr(pairs[k], eq + 1)
    }
  }
  $1 ~ /^#/ || NF == 0 { next }
  NF != 8 { printf "FATAL: malformed tour inventory row %d\n", NR > "/dev/stderr"; bad=1; next }
  $1 !~ /^_content\/tour\// { printf "FATAL: row path outside pinned _content/tour tree at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  $1 ~ /^(docs|tests|tools)\/go-corpus\// { printf "FATAL: row uses run #2 Go corpus ownership at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  seen[$1]++ { printf "FATAL: duplicate tour inventory path at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  prev != "" && $1 <= prev { printf "FATAL: inventory path order regression at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  $2 !~ /^(lesson_play_program|exercise_solution_program|ui_sandbox_program|article_inline_block)$/ { printf "FATAL: invalid kind at row %d: %s\n", NR, $2 > "/dev/stderr"; bad=1 }
  $3 !~ /^(n\/a|[0-9]+)$/ { printf "FATAL: invalid start_line at row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1 }
  {
    if ($2 == "article_inline_block") {
      if ($3 !~ /^[0-9]+$/) { printf "FATAL: inline block needs numeric start_line at row %d\n", NR > "/dev/stderr"; bad=1 }
      if ($1 !~ /^[^#]+\.article#inline-[0-9]+-L[0-9]+$/) { printf "FATAL: inline block path shape at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
      if ($4 != "excluded_fragment") { printf "FATAL: inline block must be excluded_fragment at row %d\n", NR > "/dev/stderr"; bad=1 }
    } else {
      if ($3 != "n/a") { printf "FATAL: program row must use n/a start_line at row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1 }
      if ($1 !~ /^_content\/tour\/[^#]+\.go$/) { printf "FATAL: program row path must be a .go file at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
    }
  }
  !($4 in couple) { printf "FATAL: applicability not defined by differential schema coupling at row %d: %s\n", NR, $4 > "/dev/stderr"; bad=1 }
  $5 !~ /^exception:[a-z_]+$/ { printf "FATAL: invalid exception syntax at row %d: %s\n", NR, $5 > "/dev/stderr"; bad=1 }
  {
    ex = $5
    sub(/^exception:/, "", ex)
    if (!allowed_exc[ex]) { printf "FATAL: row %d cites non-standing Sprint 98 exception: %s\n", NR, ex > "/dev/stderr"; bad=1 }
    want_ex = ($4 ~ /^excluded_/) ? substr($4, 10) : "none"
    if (ex != want_ex) { printf "FATAL: row %d exception %s does not follow applicability %s\n", NR, ex, $4 > "/dev/stderr"; bad=1 }
  }
  $6 !~ schema_regex { printf "FATAL: differential schema vocabulary violation at row %d: %s\n", NR, $6 > "/dev/stderr"; bad=1 }
  ($4 in couple) && $6 != couple[$4] { printf "FATAL: differential schema does not match applicability %s at row %d\n", $4, NR > "/dev/stderr"; bad=1 }
  $0 ~ /PLANNED/ { printf "FATAL: PLANNED is not a valid tour inventory state at row %d\n", NR > "/dev/stderr"; bad=1 }
  $7 !~ /^[0-9]+$/ || $7 == 0 { printf "FATAL: invalid byte count at row %d: %s\n", NR, $7 > "/dev/stderr"; bad=1 }
  $8 !~ /^[0-9a-f]{64}$/ { printf "FATAL: invalid sha256 at row %d: %s\n", NR, $8 > "/dev/stderr"; bad=1 }
  { prev = $1 }
  END { exit bad ? 1 : 0 }
' "${INV}"

if [ -n "${TOUR_ROOT:-}" ]; then
  [ -d "${TOUR_ROOT}" ] || die "TOUR_ROOT is not a directory: ${TOUR_ROOT}"
  [ -f "${TOUR_ROOT}/LICENSE" ] || die "TOUR_ROOT is missing upstream LICENSE"
  [ -f "${TOUR_ROOT}/_content/tour" ] || [ -d "${TOUR_ROOT}/_content/tour" ] || die "TOUR_ROOT is missing _content/tour assets"
  grep -qx "module golang.org/x/website" "${TOUR_ROOT}/go.mod" || die "TOUR_ROOT go.mod is not module golang.org/x/website"
  if command -v git >/dev/null 2>&1 && [ -d "${TOUR_ROOT}/.git" ]; then
    actual_commit="$(git -C "${TOUR_ROOT}" rev-parse HEAD)"
    [ "${actual_commit}" = "${commit}" ] || die "TOUR_ROOT commit mismatch: expected ${commit}, got ${actual_commit}"
  fi
  "${ROOT}/tools/tour/refresh.sh" --inventory-only "${TOUR_ROOT}" | diff -u "${INV}" - || \
    die "TOUR_ROOT-derived inventory differs from checked-in inventory"
fi

echo "Go tour inventory OK: golang.org/x/website@${version} (${commit}) ${rows}/${expected_rows} rows"
