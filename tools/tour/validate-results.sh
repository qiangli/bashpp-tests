#!/usr/bin/env bash
# Fail-closed offline gate for the tour Go-baseline results.
#
# Sprint 98 / Story #5 / Story-ID 4895df27bdb9.
#
# Validates tests/tour/results.tsv against the pinned inventory, the exact
# toolchain identity+checksum, the official helper module and the baseline
# run pin — WITHOUT executing anything. Wired into harness/run.sh so every
# harness invocation proves the checked-in baseline records still bind to
# the current pins. This validates RUNNER INFRASTRUCTURE records; it is not
# Bash++ parity evidence and makes no claim about Bash++ modes.
#
# Fail-closed on: missing results/pin, header mismatch against any pin,
# records_sha256 drift, row count drift, unknown/duplicate/unsorted paths,
# records for excluded rows (unexpected), missing records for executable
# rows, source byte/sha/mode disagreement with the inventory, wrong baseline
# token for the applicability class, non-zero build/run exits, '-' (N/A)
# fields on applicable rows, non-strict-UTF-8 markers, non-pass outcomes,
# and the literal token PLANNED anywhere in the file. The results file
# itself must be strict UTF-8 (rejected, never silently replaced).
#
# Usage: tools/tour/validate-results.sh
# Env (tamper tests): TOUR_RESULTS, TOUR_INVENTORY, TOUR_BASELINE_PIN.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/tour/pin.tsv"
TOOLCHAIN="${ROOT}/docs/tour/toolchain.tsv"
HELPERS="${ROOT}/docs/tour/helpers.tsv"
SCHEMA="${ROOT}/docs/tour/differential-schema.tsv"
INV="${TOUR_INVENTORY:-${ROOT}/tests/tour/inventory.tsv}"
RESULTS="${TOUR_RESULTS:-${ROOT}/tests/tour/results.tsv}"
BASELINE_PIN="${TOUR_BASELINE_PIN:-${ROOT}/docs/tour/baseline-pin.tsv}"

die() { echo "FATAL: $*" >&2; exit 2; }

[ -f "${INV}" ] || die "missing tour inventory: ${INV}"
[ -f "${RESULTS}" ] || die "missing tour baseline results: ${RESULTS} (run tools/tour/run-baseline.sh)"
[ -f "${BASELINE_PIN}" ] || die "missing baseline run pin: ${BASELINE_PIN}"

res_header() { # <key> -> value (dies on missing key)
  awk -F '\t' -v key="# $1" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "${RESULTS}"
}

# ---------------------------------------------------------------- pins ----
pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r repo version commit go_mod_sum license _prov pin_rows inventory_data_sha256 <<<"${pin_row}"
[ "${repo:-}" = "golang.org/x/website" ] || die "pin repo must be golang.org/x/website"

helper_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${HELPERS}")"
IFS=$'\t' read -r helper_mod helper_ver helper_license helper_mod_sum helper_zip_sum _pkgs _hprov <<<"${helper_row}"

bp_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${BASELINE_PIN}")"
IFS=$'\t' read -r bp_release bp_commit bp_tc_identity bp_tc_sha bp_helper bp_records bp_records_sha bp_inv_sha <<<"${bp_row}"

# Differential schema coupling: the baseline token per applicability class,
# exactly as the runner and tools/tour/validate.sh read it.
coupling="$(awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  NF == 2 && ($1 == "applicable_go_program" || $1 == "build_only_go_program" || $1 == "excluded_fragment") {
    s = $2; sub(/^baseline:/, "", s); sub(/;bpp_interpreted:.*/, "", s); print $1 "=" s
  }' "${SCHEMA}")"
[ -n "${coupling}" ] || die "differential schema declares no applicability coupling"
couple_token() { # <applicability>
  local a="$1" pair
  for pair in ${coupling}; do
    [ "${pair%%=*}" = "${a}" ] && { printf '%s' "${pair#*=}"; return 0; }
  done
  die "no differential schema coupling for applicability ${a}"
}
TOK_RUN="$(couple_token applicable_go_program)"
TOK_BUILD="$(couple_token build_only_go_program)"

# ------------------------------------------------------ results headers ----
[ "$(res_header generated_by)" = "tools/tour/run-baseline.sh" ] || die "results generated_by header mismatch"
[ "$(res_header release)" = "golang.org/x/website@${version}" ] || die "results release header mismatch vs pin"
[ "$(res_header commit)" = "${commit}" ] || die "results commit header mismatch vs pin"
[ "$(res_header license)" = "${license}" ] || die "results license header mismatch vs pin"

res_tc_identity="$(res_header toolchain)"
res_tc_sha="$(res_header toolchain_sha256)"
tc_match="$(awk -F '\t' -v id="${res_tc_identity}" -v sha="${res_tc_sha}" '
  $1 !~ /^#/ && NF && $4 == id && $5 == sha { found = 1; exit }
  END { print found ? "match" : ""; exit 0 }' "${TOOLCHAIN}")"
[ -n "${tc_match}" ] \
  || die "results toolchain '${res_tc_identity}' (sha ${res_tc_sha}) is not a pinned row in docs/tour/toolchain.tsv — the baseline must come from the exact pinned Go"

[ "$(res_header helper_module)" = "${helper_mod}@${helper_ver}" ] || die "results helper_module header mismatch vs helpers pin"
[ "$(res_header helper_go_mod_sum)" = "${helper_mod_sum}" ] || die "results helper_go_mod_sum header mismatch vs helpers pin"
[ "$(res_header helper_zip_sum)" = "${helper_zip_sum}" ] || die "results helper_zip_sum header mismatch vs helpers pin"

# ------------------------------------------------ baseline run pin cross-check
[ "${bp_release}" = "golang.org/x/website@${version}" ] || die "baseline pin release mismatch vs source pin"
[ "${bp_commit}" = "${commit}" ] || die "baseline pin commit mismatch vs source pin"
[ "${bp_tc_identity}" = "${res_tc_identity}" ] || die "baseline pin toolchain identity mismatch vs results header"
[ "${bp_tc_sha}" = "${res_tc_sha}" ] || die "baseline pin toolchain checksum mismatch vs results header"
[ "${bp_helper}" = "${helper_mod}@${helper_ver}" ] || die "baseline pin helper module mismatch vs helpers pin"
[ "${bp_inv_sha}" = "${inventory_data_sha256}" ] \
  || die "baseline pin inventory_data_sha256 ${bp_inv_sha} does not match the pinned inventory ${inventory_data_sha256} — results were recorded against a different inventory revision"
case "${bp_records_sha}" in *[!0-9a-f]*|'') die "baseline pin records_sha256 must be lowercase hex" ;; esac
[ "${#bp_records_sha}" -eq 64 ] || die "baseline pin records_sha256 must be 64 hex characters"

# ------------------------------------------------- data row integrity ----
actual_rows="$(awk '$0 !~ /^#/ && NF' "${RESULTS}" | wc -l | tr -d ' ')"
actual_sha="$(awk '$0 !~ /^#/ && NF' "${RESULTS}" | shasum -a 256 | awk '{print $1}')"
header_rows="$(res_header records)"
case "${header_rows}" in ''|*[!0-9]*) die "results records header must be an integer" ;; esac
[ "${header_rows}" -gt 0 ] || die "results records header must be positive — 0 measured rows is not a baseline"
[ "${actual_rows}" -eq "${header_rows}" ] || die "results row count drift: header ${header_rows}, data rows ${actual_rows}"
[ "${actual_rows}" -eq "${bp_records}" ] || die "baseline pin records ${bp_records} != results rows ${actual_rows}"
[ "${actual_sha}" = "${bp_records_sha}" ] \
  || die "results records_sha256 mismatch: pin ${bp_records_sha}, recomputed ${actual_sha}"

grep -n 'PLANNED' "${RESULTS}" >/dev/null 2>&1 && die "PLANNED is not a valid tour baseline state"

# Strict UTF-8 for the whole results file — reject, never replace.
ruby -e 's = STDIN.read.b; s.force_encoding("UTF-8"); abort("FATAL: results file is not strict UTF-8") unless s.valid_encoding?' < "${RESULTS}"

# Coverage + per-record semantics, joined against the inventory. Every
# executable inventory row and every record path pass through one awk pass,
# so nothing can be silently missing or unexpected.
VT="$(mktemp -d)"
trap 'rm -rf "${VT}"' EXIT
awk -F '\t' '$1 !~ /^#/ && NF && ($4 == "applicable_go_program" || $4 == "build_only_go_program") \
     { print $1 "\t" $4 "\t" $7 "\t" $8 }' "${INV}" | sort -t$'\t' -k1,1 > "${VT}/inv-exec.tsv"
awk '$0 !~ /^#/ && NF' "${RESULTS}" | sort -t$'\t' -k1,1 > "${VT}/res-rows.tsv"

awk -F '\t' \
  -v tok_run="${TOK_RUN}" -v tok_build="${TOK_BUILD}" \
  -v inv_exec="${VT}/inv-exec.tsv" '
  BEGIN {
    while ((getline line < inv_exec) > 0) {
      split(line, f, "\t")
      inv_class[f[1]] = f[2]; inv_bytes[f[1]] = f[3]; inv_sha[f[1]] = f[4]
    }
    close(inv_exec)
  }
  {
    path = $1
    if (NF != 14) { printf "FATAL: record %s has %d columns (need 14)\n", path, NF > "/dev/stderr"; bad = 1; next }
    cls = $2; sbytes = $3; ssha = $4; smode = $5; base = $6
    bexit = $7; rexit = $8; ob = $9; osha = $10; eb = $11; esha = $12; utf = $13; outcome = $14

    if (!(path in inv_class)) { printf "FATAL: record for non-executable or unknown path: %s\n", path > "/dev/stderr"; bad = 1; next }
    if (seen[path]++) { printf "FATAL: duplicate record path: %s\n", path > "/dev/stderr"; bad = 1; next }
    if (prev != "" && path <= prev) { printf "FATAL: record order regression at %s\n", path > "/dev/stderr"; bad = 1 }
    prev = path

    if (cls != inv_class[path]) { printf "FATAL: %s applicability %s != inventory %s\n", path, cls, inv_class[path] > "/dev/stderr"; bad = 1 }
    if (sbytes != inv_bytes[path]) { printf "FATAL: %s source_bytes %s != inventory %s\n", path, sbytes, inv_bytes[path] > "/dev/stderr"; bad = 1 }
    if (ssha != inv_sha[path]) { printf "FATAL: %s source_sha256 does not match inventory\n", path > "/dev/stderr"; bad = 1 }
    if (smode != "444") { printf "FATAL: %s source_mode %s must be read-only 444\n", path, smode > "/dev/stderr"; bad = 1 }

    want_base = (cls == "applicable_go_program") ? tok_run : tok_build
    if (base != want_base) { printf "FATAL: %s baseline token %s must follow the schema coupling %s\n", path, base, want_base > "/dev/stderr"; bad = 1 }

    if (bexit != "0") { printf "FATAL: %s build_exit %s — executable rows must build under the pinned toolchain\n", path, bexit > "/dev/stderr"; bad = 1 }

    if (cls == "applicable_go_program") {
      if (rexit != "0") { printf "FATAL: %s run_exit %s — applicable rows must have a successful Go baseline\n", path, rexit > "/dev/stderr"; bad = 1 }
      if (ob !~ /^[0-9]+$/ || eb !~ /^[0-9]+$/) { printf "FATAL: %s stream byte counts must be numeric (unexpected N/A)\n", path > "/dev/stderr"; bad = 1 }
      if (osha !~ /^[0-9a-f]{64}$/ || esha !~ /^[0-9a-f]{64}$/) { printf "FATAL: %s stream sha256 fields malformed\n", path > "/dev/stderr"; bad = 1 }
      if (utf != "strict") { printf "FATAL: %s streams_utf8 %s — captured streams must be strict UTF-8\n", path, utf > "/dev/stderr"; bad = 1 }
    } else {
      # build_only: never executed — run/stream fields must be the explicit
      # N/A marker, anything else is an unexpected run or a missing marker.
      if (rexit != "-" || ob != "-" || osha != "-" || eb != "-" || esha != "-" || utf != "-") {
        printf "FATAL: %s build-only row carries run data — norun rows are never executed\n", path > "/dev/stderr"; bad = 1
      }
    }
    if (outcome != "pass") { printf "FATAL: %s outcome %s — the pinned Go baseline must pass every executable row\n", path, outcome > "/dev/stderr"; bad = 1 }
  }
  END {
    n_run = 0; n_build = 0
    for (p in inv_class) {
      if (inv_class[p] == "applicable_go_program") n_run++
      else n_build++
      if (!(p in seen)) { printf "FATAL: missing record for executable inventory row: %s\n", p > "/dev/stderr"; bad = 1 }
    }
    n_seen = 0; for (p in seen) n_seen++
    printf "baseline coverage: %d applicable, %d build-only, %d records\n", n_run, n_build, n_seen > "/dev/stderr"
    exit bad ? 1 : 0
  }
' "${VT}/res-rows.tsv" || exit 2

echo "Go tour baseline results OK: ${actual_rows} records, toolchain ${res_tc_identity} (pinned checksum verified), sha ${actual_sha:0:16}…"
