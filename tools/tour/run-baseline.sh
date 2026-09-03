#!/usr/bin/env bash
# Deterministic Go-baseline executor for the pinned go.dev/tour inventory.
#
# Sprint 98 / Story #5 / Story-ID 4895df27bdb9 (supersedes rejected weave 6,
# story 759341a95870, retaining its pinned source/license/helper inventory
# as the reference this runner executes against).
#
# This is RUNNER INFRASTRUCTURE, not Bash++ parity evidence: it executes the
# declared pinned-Go baseline only. The Bash++ differential modes stay
# declared in docs/tour/differential-schema.tsv and are NOT run here; no
# result this script writes is a claim about Bash++ behavior.
#
# Oracle semantics mirror the upstream x/website content_test.go: every
# inventoried .go program's first line is a //go:build comment containing
# OMIT; nobuild rows are excluded fragments; norun rows build but never
# execute; everything else builds AND runs and must exit 0. Explicit-file
# builds bypass the OMIT constraint (verified under the pinned toolchain).
#
# Fail-closed contract:
#   - toolchain: exact identity (full `go version` output) AND SHA-256 of the
#     executing go binary must match docs/tour/toolchain.tsv for this
#     platform; a platform without a pinned row is unsupported, not degraded.
#   - sources: every executable inventory row's file must exist in TOUR_ROOT
#     with exactly the pinned byte count, SHA-256, and mode 0444 after copy.
#   - streams: captured stdout/stderr must be strict UTF-8; invalid bytes are
#     REJECTED (outcome fail:invalid-utf8), never replaced or transliterated.
#   - bounds: build and run are bounded (TOUR_BUILD_TIMEOUT/TOUR_RUN_TIMEOUT,
#     0.1s poll granularity); each child runs in its own process group (set -m)
#     and the whole tree is TERMed then KILLed on expiry; stdin is /dev/null;
#     all child I/O uses regular files, so no pipe can block or leak; the
#     scratch run root is removed on every exit path (TOUR_KEEP_RUN_ROOT=1 to
#     keep it for inspection).
#
# Usage:
#   tools/tour/run-baseline.sh [TOUR_ROOT]
# Env overrides (used by tools/tour/tamper-tests.sh):
#   TOUR_ROOT           pinned x/website source (default: module cache copy)
#   TOUR_INVENTORY      inventory (default tests/tour/inventory.tsv)
#   TOUR_RESULTS        results output (default tests/tour/results.tsv)
#   TOUR_BASELINE_PIN   results pin (default docs/tour/baseline-pin.tsv)
#   TOUR_RUN_ROOT       scratch prefix (default .cache/tour/run)
#   TOUR_BUILD_TIMEOUT  default 120 (seconds)
#   TOUR_RUN_TIMEOUT    default 20  (seconds)
#   TOUR_KILL_GRACE     default 3   (seconds between TERM and KILL)
#   TOUR_KEEP_RUN_ROOT  1 to keep the scratch tree
set -euo pipefail
set -m # every background job gets its own process group so -PGID kills the tree
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/tour/pin.tsv"
TOOLCHAIN="${ROOT}/docs/tour/toolchain.tsv"
HELPERS="${ROOT}/docs/tour/helpers.tsv"
SCHEMA="${ROOT}/docs/tour/differential-schema.tsv"
INV="${TOUR_INVENTORY:-${ROOT}/tests/tour/inventory.tsv}"
RESULTS="${TOUR_RESULTS:-${ROOT}/tests/tour/results.tsv}"
BASELINE_PIN="${TOUR_BASELINE_PIN:-${ROOT}/docs/tour/baseline-pin.tsv}"
BUILD_TIMEOUT="${TOUR_BUILD_TIMEOUT:-120}"
RUN_TIMEOUT="${TOUR_RUN_TIMEOUT:-20}"
KILL_GRACE="${TOUR_KILL_GRACE:-3}"

die() { echo "FATAL: $*" >&2; exit 2; }

file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes() { wc -c < "$1" | tr -d ' '; }
file_mode() { # portable octal permission bits, e.g. 444
  local m
  m="$(stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null)" \
    || die "cannot stat mode of $1"
  printf '%s\n' "${m#0}"
}

# ---------------------------------------------------------------- pins ----
pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r repo version commit go_mod_sum license _prov _rows inventory_data_sha256 <<<"${pin_row}"
[ "${repo:-}" = "golang.org/x/website" ] || die "pin repo must be golang.org/x/website, got ${repo:-}"
case "${go_mod_sum:-}" in h1:*=) ;; *) die "pin go_mod_sum must be an h1: module hash" ;; esac
[ "${license:-}" = "BSD-3-Clause" ] || die "pin license must preserve upstream BSD-3-Clause provenance"
case "${inventory_data_sha256:-}" in *[!0-9a-f]*|'') die "pin inventory_data_sha256 must be lowercase hex" ;; esac
[ "${#inventory_data_sha256}" -eq 64 ] || die "pin inventory_data_sha256 must be 64 hex characters"

helper_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${HELPERS}")"
IFS=$'\t' read -r helper_mod helper_ver helper_license helper_mod_sum helper_zip_sum helper_pkgs _hprov <<<"${helper_row}"
[ "${helper_mod:-}" = "golang.org/x/tour" ] || die "helpers pin must be golang.org/x/tour, got ${helper_mod:-}"
[ "${helper_license:-}" = "BSD-3-Clause" ] || die "helper license must be BSD-3-Clause"
case "${helper_mod_sum:-}" in h1:*=) ;; *) die "helper go_mod_sum must be an h1: module hash" ;; esac
case "${helper_zip_sum:-}" in h1:*=) ;; *) die "helper zip_sum must be an h1: module hash" ;; esac
[ "${#helper_mod_sum}" -eq 47 ] && [ "${#helper_zip_sum}" -eq 47 ] \
  || die "helper sums must be h1:<44 base64 chars>"
case "${helper_pkgs:-}" in pic,reader,tree,wc) ;; *) die "helper packages pin must be pic,reader,tree,wc" ;; esac

toolchain_row="$(awk -F '\t' -v goos="$(uname -s | tr '[:upper:]' '[:lower:]')" -v goarch="$(uname -m)" '
  $1 !~ /^#/ && NF && $1 == goos && $2 == goarch { print; exit }' "${TOOLCHAIN}")"
[ -n "${toolchain_row}" ] || die "no pinned Go toolchain row for $(uname -s)/$(uname -m) in docs/tour/toolchain.tsv — the pinned baseline is unsupported here, not degraded"
IFS=$'\t' read -r _gos _gar tc_version tc_identity tc_sha _acq _tprov <<<"${toolchain_row}"
case "${tc_sha:-}" in *[!0-9a-f]*|'') die "pinned toolchain checksum must be lowercase hex" ;; esac
[ "${#tc_sha}" -eq 64 ] || die "pinned toolchain checksum must be 64 hex characters"
case "${tc_identity:-}" in "go version ${tc_version} "*) ;; *) die "pinned identity must start with 'go version ${tc_version} '" ;; esac

# Differential schema: single source of truth for the baseline token per
# applicability class (parsed exactly like tools/tour/validate.sh).
baseline_for() { # <applicability> -> baseline token
  awk -F '\t' -v a="$1" '
    $1 ~ /^#/ || NF == 0 { next }
    NF == 2 && $1 == a {
      s = $2; sub(/^baseline:/, "", s); sub(/;bpp_interpreted:.*/, "", s); print s; found = 1; exit
    }
    END { if (!found) exit 1 }' "${SCHEMA}" || die "no differential schema coupling for applicability $1"
}
for a in applicable_go_program build_only_go_program excluded_fragment; do
  baseline_for "$a" >/dev/null
done
BASE_TOKEN_RUN="$(baseline_for applicable_go_program)"
BASE_TOKEN_BUILD="$(baseline_for build_only_go_program)"

# ----------------------------------------------------------- toolchain ----
command -v go >/dev/null 2>&1 || die "no go on PATH to resolve the pinned toolchain"
tc_root="$(GOTOOLCHAIN="go${tc_version#go}" go env GOROOT 2>/dev/null)" \
  || die "cannot resolve GOROOT for ${tc_version} (GOTOOLCHAIN=go${tc_version#go} go env GOROOT)"
GO_BIN="${tc_root}/bin/go"
[ -x "${GO_BIN}" ] || die "resolved toolchain binary is not executable: ${GO_BIN}"
actual_identity="$("${GO_BIN}" version 2>/dev/null)" || die "cannot run ${GO_BIN} version"
[ "${actual_identity}" = "${tc_identity}" ] \
  || die "toolchain identity mismatch: pinned '${tc_identity}', got '${actual_identity}'"
actual_tc_sha="$(file_sha "${GO_BIN}")"
[ "${actual_tc_sha}" = "${tc_sha}" ] \
  || die "toolchain checksum mismatch: pinned ${tc_sha}, got ${actual_tc_sha}"
echo "toolchain OK: ${actual_identity} (sha256 ${actual_tc_sha:0:16}…) ${GO_BIN}"

# -------------------------------------------------------------- source ----
GOMODCACHE_DIR="$(go env GOMODCACHE)"
TOUR_ROOT="${1:-${TOUR_ROOT:-${GOMODCACHE_DIR}/golang.org/x/website@${version}}}"
[ -d "${TOUR_ROOT}" ] || die "TOUR_ROOT is not a directory: ${TOUR_ROOT}"
[ -f "${TOUR_ROOT}/LICENSE" ] || die "TOUR_ROOT is missing upstream LICENSE (BSD provenance)"
[ -d "${TOUR_ROOT}/_content/tour" ] || die "TOUR_ROOT is missing _content/tour"
grep -qx "module golang.org/x/website" "${TOUR_ROOT}/go.mod" || die "TOUR_ROOT go.mod is not module golang.org/x/website"

[ -f "${INV}" ] || die "missing tour inventory: ${INV}"
require_header() { # <key> <want>
  local got
  got="$(awk -F '\t' -v key="# $1" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "${INV}")" \
    || die "inventory missing # $1 header"
  [ "${got}" = "$2" ] || die "inventory # $1 header mismatch: expected $2, got ${got}"
}
require_header release "golang.org/x/website@${version}"
require_header commit "${commit}"
require_header license "${license}"

# ------------------------------------------------------- scratch module ----
RUN_BASE="${TOUR_RUN_ROOT:-${ROOT}/.cache/tour/run}"
mkdir -p "$(dirname "${RUN_BASE}")"
RUN_ROOT="$(mktemp -d "${RUN_BASE}.XXXXXX")"
SRC_DIR="${RUN_ROOT}/src"
mkdir -p "${SRC_DIR}/_content/tour"

declare -a LIVE_PGIDS=()
forget_pgid() { # stop tracking a reaped pgid (its group is empty; avoids pid-reuse hazards)
  local drop="$1" p
  local -a out=()
  for p in ${LIVE_PGIDS[@]+"${LIVE_PGIDS[@]}"}; do [ "${p}" = "${drop}" ] || out+=("${p}"); done
  LIVE_PGIDS=(${out[@]+"${out[@]}"})
}
cleanup() {
  local pgid
  for pgid in ${LIVE_PGIDS[@]+"${LIVE_PGIDS[@]}"}; do
    kill -KILL -- "-${pgid}" 2>/dev/null || kill -KILL "${pgid}" 2>/dev/null || true
  done
  [ "${TOUR_KEEP_RUN_ROOT:-0}" = "1" ] || rm -rf "${RUN_ROOT}"
}
trap cleanup EXIT HUP INT TERM

printf 'module tour.baseline.local\n\ngo %s\n\nrequire %s %s\n' "${tc_version#go}" "${helper_mod}" "${helper_ver}" \
  > "${SRC_DIR}/go.mod"
printf '%s %s %s\n%s %s/go.mod %s\n' \
  "${helper_mod}" "${helper_ver}" "${helper_zip_sum}" \
  "${helper_mod}" "${helper_ver}" "${helper_mod_sum}" > "${SRC_DIR}/go.sum"
# BSD provenance travels with the copied programs: the upstream LICENSE sits
# at the root of the scratch module, exactly as in the pinned source.
cp "${TOUR_ROOT}/LICENSE" "${SRC_DIR}/LICENSE"

# Bounded child runner: own process group (set -m), TERM-then-KILL the whole
# tree on expiry, /dev/null stdin. Callers redirect stdout/stderr to regular
# files — no pipes exist anywhere in this runner, so nothing can block on a
# dead reader or leak an open pipe.
bounded_run() { # bounded_run <timeout_s> <grace_s> <cmd...>
  local limit_t=$(( $1 * 10 )) grace_t=$(( $2 * 10 )); shift 2
  "$@" </dev/null &
  local pid=$! t=0 rc=0 g
  LIVE_PGIDS+=("${pid}")
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${t}" -ge "${limit_t}" ]; then
      kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
      g=0
      while kill -0 "${pid}" 2>/dev/null && [ "${g}" -lt "${grace_t}" ]; do sleep 0.1; g=$((g + 1)); done
      kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || rc=$?
      kill -KILL -- "-${pid}" 2>/dev/null || true
      forget_pgid "${pid}"
      return 137
    fi
    sleep 0.1
    t=$((t + 1))
  done
  wait "${pid}" || rc=$?
  # Sweep the whole group even after a clean leader exit: a program that
  # exits 0 while spawning stragglers must not leak them past the bound.
  kill -KILL -- "-${pid}" 2>/dev/null || true
  forget_pgid "${pid}"
  return "${rc}"
}
bounded_run_probe() { bounded_run "$@"; } # alias kept for symmetry with the probe below

utf8_strict() { # <file> -> 0 iff bytes are strict UTF-8 (reject, never replace)
  ruby -e 's = STDIN.read.b; s.force_encoding("UTF-8"); exit(s.valid_encoding? ? 0 : 1)' < "$1"
}

# Provision the official helper module dependency from the pinned sums
# (module cache first, official proxy fallback), bounded like every child.
helper_out="${RUN_ROOT}/helper-download.log"
if ! ( cd "${SRC_DIR}" && bounded_run "${BUILD_TIMEOUT}" "${KILL_GRACE}" \
       env GOTOOLCHAIN=local "${GO_BIN}" mod download "${helper_mod}" \
       > "${helper_out}" 2>&1 ); then
  cat "${helper_out}" >&2 || true
  die "cannot provision helper module ${helper_mod}@${helper_ver} from the pinned sums"
fi

records="${RUN_ROOT}/records.tsv"
: > "${records}"
pass_count=0 fail_count=0

emit_record() { # 14 fields: path applic src_bytes src_sha src_mode baseline build_exit run_exit out_b out_sha err_b err_sha utf8 outcome
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "${records}"
}

# Iterate every executable inventory row (applicable + build-only). The feed
# is a MATERIALIZED FILE, not a process substitution: this suite also runs
# under bash reimplementations (bashy) whose process-substitution FIFOs may
# never see EOF once the writer exits, hanging the loop after the last row.
# A regular file has unambiguous EOF; the read runs in the main shell, so
# counters and LIVE_PGIDS survive.
feed="${RUN_ROOT}/executable.tsv"
awk -F '\t' '$1 !~ /^#/ && NF && ($4 == "applicable_go_program" || $4 == "build_only_go_program") \
     { print $1 "\t" $4 "\t" $7 "\t" $8 }' "${INV}" > "${feed}"
while IFS=$'\t' read -r path applicability inv_bytes inv_sha; do
  case "${applicability}" in
    applicable_go_program) base_tok="${BASE_TOKEN_RUN}" ;;
    build_only_go_program) base_tok="${BASE_TOKEN_BUILD}" ;;
    *) die "executable feed delivered non-executable applicability: ${path} ${applicability}" ;;
  esac
  work="${RUN_ROOT}/work/${path}"
  mkdir -p "${work}"

  src="${TOUR_ROOT}/${path}"
  dst="${SRC_DIR}/${path}"
  [ -f "${src}" ] || die "missing pinned source for ${path}: ${src}"
  [ "$(file_bytes "${src}")" = "${inv_bytes}" ] \
    || die "source byte-count tamper for ${path}: inventory ${inv_bytes}, file $(file_bytes "${src}")"
  [ "$(file_sha "${src}")" = "${inv_sha}" ] \
    || die "source sha256 tamper for ${path}: inventory ${inv_sha}, file $(file_sha "${src}")"
  # Pinned sources are the read-only module-cache materialization (mode
  # 0444); a writable source could be modified between verify and copy.
  src_mode="$(file_mode "${src}")"
  [ "${src_mode}" = "444" ] \
    || die "source mode tampered for ${path}: pinned sources are read-only 444, got ${src_mode} (TOUR_ROOT must be the module-cache materialization, not a writable tree)"
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
  chmod 0444 "${dst}"
  [ "$(file_bytes "${dst}")" = "${inv_bytes}" ] || die "copy byte drift for ${path}"
  [ "$(file_sha "${dst}")" = "${inv_sha}" ] || die "copy sha drift for ${path}"
  dst_mode="$(file_mode "${dst}")"
  [ "${dst_mode}" = "444" ] \
    || die "source mode tamper for ${path}: expected read-only 444 after copy, got ${dst_mode}"

  build_exit=0
  if ( cd "${SRC_DIR}" && bounded_run "${BUILD_TIMEOUT}" "${KILL_GRACE}" \
         env GOTOOLCHAIN=local "${GO_BIN}" build -o "${work}/bin" "${path}" \
         > "${work}/build.stdout" 2> "${work}/build.stderr" ); then
    build_exit=0
  else
    build_exit=$?
  fi
  if [ "${build_exit}" -ne 0 ]; then
    echo "  build FAILED (${build_exit}): ${path}" >&2
    sed -n '1,5p' "${work}/build.stderr" 2>/dev/null | sed 's/^/    /' >&2 || true
    emit_record "${path}" "${applicability}" "${inv_bytes}" "${inv_sha}" "${dst_mode}" "${base_tok}" \
      "${build_exit}" - - - - - - "fail:build:${build_exit}"
    fail_count=$((fail_count + 1))
    continue
  fi

  if [ "${applicability}" = "build_only_go_program" ]; then
    # Oracle semantics: norun rows build but are NEVER executed.
    emit_record "${path}" "${applicability}" "${inv_bytes}" "${inv_sha}" "${dst_mode}" "${base_tok}" \
      0 - - - - - - pass
    pass_count=$((pass_count + 1))
    continue
  fi

  run_exit=0
  if bounded_run "${RUN_TIMEOUT}" "${KILL_GRACE}" "${work}/bin" \
       > "${work}/run.stdout" 2> "${work}/run.stderr"; then
    run_exit=0
  else
    run_exit=$?
  fi
  out_bytes="$(file_bytes "${work}/run.stdout")"; out_sha="$(file_sha "${work}/run.stdout")"
  err_bytes="$(file_bytes "${work}/run.stderr")"; err_sha="$(file_sha "${work}/run.stderr")"
  utf8="strict"
  utf8_strict "${work}/run.stdout" || utf8="stdout-invalid"
  utf8_strict "${work}/run.stderr" || utf8="stderr-invalid"
  if [ "${utf8}" != "strict" ]; then
    echo "  REJECTED non-UTF-8 (${utf8}): ${path}" >&2
    emit_record "${path}" "${applicability}" "${inv_bytes}" "${inv_sha}" "${dst_mode}" "${base_tok}" \
      0 "${run_exit}" "${out_bytes}" "${out_sha}" "${err_bytes}" "${err_sha}" "${utf8}" "fail:invalid-utf8"
    fail_count=$((fail_count + 1))
    continue
  fi
  if [ "${run_exit}" -ne 0 ]; then
    echo "  run FAILED (exit ${run_exit}): ${path}" >&2
    sed -n '1,5p' "${work}/run.stderr" 2>/dev/null | sed 's/^/    /' >&2 || true
    emit_record "${path}" "${applicability}" "${inv_bytes}" "${inv_sha}" "${dst_mode}" "${base_tok}" \
      0 "${run_exit}" "${out_bytes}" "${out_sha}" "${err_bytes}" "${err_sha}" "${utf8}" "fail:run-exit:${run_exit}"
    fail_count=$((fail_count + 1))
    continue
  fi
  emit_record "${path}" "${applicability}" "${inv_bytes}" "${inv_sha}" "${dst_mode}" "${base_tok}" \
    0 0 "${out_bytes}" "${out_sha}" "${err_bytes}" "${err_sha}" "${utf8}" pass
  pass_count=$((pass_count + 1))
done < "${feed}"

total_rows="$(wc -l < "${records}" | tr -d ' ')"
[ "${total_rows}" -gt 0 ] || die "0 executable rows ran — a run that measured nothing is not a run"

# ------------------------------------------------------------- results ----
sort -t$'\t' -k 1,1 "${records}" > "${records}.sorted"
records_sha="$(file_sha "${records}.sorted")"

mkdir -p "$(dirname "${RESULTS}")"
{
  echo "# generated_by	tools/tour/run-baseline.sh"
  echo "# release	golang.org/x/website@${version}"
  echo "# commit	${commit}"
  echo "# license	${license}"
  echo "# toolchain	${tc_identity}"
  echo "# toolchain_sha256	${tc_sha}"
  echo "# helper_module	${helper_mod}@${helper_ver}"
  echo "# helper_go_mod_sum	${helper_mod_sum}"
  echo "# helper_zip_sum	${helper_zip_sum}"
  echo "# records	${total_rows}"
  echo "# records_sha256	${records_sha}"
  echo "# path	applicability	source_bytes	source_sha256	source_mode	baseline	build_exit	run_exit	stdout_bytes	stdout_sha256	stderr_bytes	stderr_sha256	streams_utf8	outcome"
  cat "${records}.sorted"
} > "${RESULTS}"

mkdir -p "$(dirname "${BASELINE_PIN}")"
{
  echo "# Go baseline run pin — binds the checked-in results to the pinned"
  echo "# inventory revision, the exact toolchain identity+checksum and the"
  echo "# official helper module. Written by tools/tour/run-baseline.sh;"
  echo "# validated offline by tools/tour/validate-results.sh."
  echo "#"
  echo "# release	commit	toolchain_identity	toolchain_sha256	helper_module	records	records_sha256	inventory_data_sha256"
  printf 'golang.org/x/website@%s\t%s\t%s\t%s\t%s@%s\t%s\t%s\t%s\n' \
    "${version}" "${commit}" "${tc_identity}" "${tc_sha}" "${helper_mod}" "${helper_ver}" \
    "${total_rows}" "${records_sha}" "${inventory_data_sha256}"
} > "${BASELINE_PIN}"

echo "tour Go baseline: ${pass_count} pass, ${fail_count} fail (${total_rows} rows) -> ${RESULTS}"
[ "${fail_count}" -eq 0 ] || exit 1
