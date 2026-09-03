#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASHY_BIN="${BASHY_BIN:-${ROOT}/../bashy/bin/bash}"
MATRIX="${ROOT}/tests/bashsharp/matrix.tsv"
VALIDATE="${SCRIPT_DIR}/validate.sh"
fail() { echo "Bash# acceptance: $*" >&2; exit 1; }

"${VALIDATE}" || fail "matrix validation failed"
[ -x "${BASHY_BIN}" ] || fail "target is not executable: ${BASHY_BIN}"
probe_err="$(mktemp)"
if "${BASHY_BIN}" --bashpp -c ':' >/dev/null 2>"${probe_err}"; then
  rm -f "${probe_err}"
else
  sed -n '1,3p' "${probe_err}" >&2
  rm -f "${probe_err}"
  fail "Bash++ selector probe failed"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashsharp-run.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
capture() {
  local out="$1" err="$2" cwd="$3"; shift 3
  (cd "${cwd}" && "$@") >"${out}" 2>"${err}"
}
compare() {
  cmp -s "$1" "$2" && cmp -s "$3" "$4" && [ "$5" -eq "$6" ]
}

while IFS=$'\t' read -r -a f; do
  [ "${#f[@]}" -eq 0 ] && continue
  [[ "${f[0]}" == \#* ]] && continue
  id="${f[0]}"; positive="${f[2]}"; near="${f[3]}"; forced="${f[4]}"
  off="${f[5]}"; unsupported="${f[6]}"; checker="${f[7]}"
  expected_rc="${f[9]}"; expected="${ROOT}/tests/bashsharp/${f[10]}"
  pos_dir="${ROOT}/tests/bashsharp/$(dirname "${positive}")"; pos_file="$(basename "${positive}")"

  pos_out="${tmp}/${id}.positive.out"; pos_err="${tmp}/${id}.positive.err"; pos_rc=0
  capture "${pos_out}" "${pos_err}" "${pos_dir}" "${BASHY_BIN}" --bashpp "${pos_file}" || pos_rc=$?
  [ "${pos_rc}" -eq "${expected_rc}" ] || fail "${id}: positive exit ${pos_rc}, expected ${expected_rc}"
  cmp -s "${pos_out}" "${expected}" || fail "${id}: positive output mismatch"
  if [ "${checker}" != none ]; then
    check_out="${tmp}/${id}.check.out"; check_err="${tmp}/${id}.check.err"; check_rc=0
    capture "${check_out}" "${check_err}" "${pos_dir}" "${BASHY_BIN}" check --bashpp "${pos_file}" || check_rc=$?
    [ "${check_rc}" -eq "${expected_rc}" ] || fail "${id}: check exit ${check_rc}, expected ${expected_rc}"
  fi

  near_dir="${ROOT}/tests/bashsharp/$(dirname "${near}")"; near_file="$(basename "${near}")"
  near_plain_out="${tmp}/${id}.near.plain.out"; near_plain_err="${tmp}/${id}.near.plain.err"; near_plain_rc=0
  capture "${near_plain_out}" "${near_plain_err}" "${near_dir}" "${BASHY_BIN}" "${near_file}" || near_plain_rc=$?
  near_pp_out="${tmp}/${id}.near.pp.out"; near_pp_err="${tmp}/${id}.near.pp.err"; near_pp_rc=0
  capture "${near_pp_out}" "${near_pp_err}" "${near_dir}" "${BASHY_BIN}" --bashpp "${near_file}" || near_pp_rc=$?
  compare "${near_plain_out}" "${near_pp_out}" "${near_plain_err}" "${near_pp_err}" "${near_plain_rc}" "${near_pp_rc}" ||
    fail "${id}: near-miss is not inert under Bash++"
  near_posix_out="${tmp}/${id}.near.posix.out"; near_posix_err="${tmp}/${id}.near.posix.err"; near_posix_rc=0
  capture "${near_posix_out}" "${near_posix_err}" "${near_dir}" "${BASHY_BIN}" --posix --bashpp "${near_file}" || near_posix_rc=$?
  compare "${near_plain_out}" "${near_posix_out}" "${near_plain_err}" "${near_posix_err}" "${near_plain_rc}" "${near_posix_rc}" ||
    fail "${id}: POSIX near-miss result changed"

  forced_dir="${ROOT}/tests/bashsharp/$(dirname "${forced}")"; forced_file="$(basename "${forced}")"
  forced_plain_out="${tmp}/${id}.forced.plain.out"; forced_plain_err="${tmp}/${id}.forced.plain.err"; forced_plain_rc=0
  capture "${forced_plain_out}" "${forced_plain_err}" "${forced_dir}" "${BASHY_BIN}" "${forced_file}" || forced_plain_rc=$?
  forced_pp_out="${tmp}/${id}.forced.pp.out"; forced_pp_err="${tmp}/${id}.forced.pp.err"; forced_pp_rc=0
  capture "${forced_pp_out}" "${forced_pp_err}" "${forced_dir}" "${BASHY_BIN}" --bashpp "${forced_file}" || forced_pp_rc=$?
  compare "${forced_plain_out}" "${forced_pp_out}" "${forced_plain_err}" "${forced_pp_err}" "${forced_plain_rc}" "${forced_pp_rc}" ||
    fail "${id}: forced-shell escape is not inert under Bash++"
  forced_posix_out="${tmp}/${id}.forced.posix.out"; forced_posix_err="${tmp}/${id}.forced.posix.err"; forced_posix_rc=0
  capture "${forced_posix_out}" "${forced_posix_err}" "${forced_dir}" "${BASHY_BIN}" --posix --bashpp "${forced_file}" || forced_posix_rc=$?
  compare "${forced_plain_out}" "${forced_posix_out}" "${forced_plain_err}" "${forced_posix_err}" "${forced_plain_rc}" "${forced_posix_rc}" ||
    fail "${id}: POSIX forced-shell result changed"

  off_dir="${ROOT}/tests/bashsharp/$(dirname "${off}")"; off_file="$(basename "${off}")"
  off_out="${tmp}/${id}.off.out"; off_err="${tmp}/${id}.off.err"; off_rc=0
  capture "${off_out}" "${off_err}" "${off_dir}" "${BASHY_BIN}" "${off_file}" || off_rc=$?
  [ "${off_rc}" -ne 0 ] || fail "${id}: selector-off case unexpectedly passed"
  off_posix_out="${tmp}/${id}.off.posix.out"; off_posix_err="${tmp}/${id}.off.posix.err"; off_posix_rc=0
  capture "${off_posix_out}" "${off_posix_err}" "${off_dir}" "${BASHY_BIN}" --posix --bashpp "${off_file}" || off_posix_rc=$?
  compare "${off_out}" "${off_posix_out}" "${off_err}" "${off_posix_err}" "${off_rc}" "${off_posix_rc}" ||
    fail "${id}: POSIX selector-off result changed"

  bad_dir="${ROOT}/tests/bashsharp/$(dirname "${unsupported}")"; bad_file="$(basename "${unsupported}")"
  bad_out="${tmp}/${id}.bad.out"; bad_err="${tmp}/${id}.bad.err"; bad_rc=0
  capture "${bad_out}" "${bad_err}" "${bad_dir}" "${BASHY_BIN}" --bashpp "${bad_file}" || bad_rc=$?
  [ "${bad_rc}" -ne 0 ] || fail "${id}: unsupported case unexpectedly passed"
  grep -Eiq 'keyword|argument|named|default|parameter|readonly|immutable|frozen|enum|member|exhaust|null|nil|unsafe|safety' "${bad_err}" ||
    fail "${id}: unsupported case lacks diagnostic"
  bad_posix_out="${tmp}/${id}.bad.posix.out"; bad_posix_err="${tmp}/${id}.bad.posix.err"; bad_posix_rc=0
  capture "${bad_posix_out}" "${bad_posix_err}" "${bad_dir}" "${BASHY_BIN}" --posix --bashpp "${bad_file}" || bad_posix_rc=$?
  compare "${bad_out}" "${bad_posix_out}" "${bad_err}" "${bad_posix_err}" "${bad_rc}" "${bad_posix_rc}" ||
    fail "${id}: POSIX unsupported result changed"

  posix_out="${tmp}/${id}.posix.out"; posix_err="${tmp}/${id}.posix.err"; posix_rc=0
  capture "${posix_out}" "${posix_err}" "${pos_dir}" "${BASHY_BIN}" --posix --bashpp "${pos_file}" || posix_rc=$?
  compare "${pos_out}" "${posix_out}" "${pos_err}" "${posix_err}" "${pos_rc}" "${posix_rc}" ||
    fail "${id}: POSIX mode changed Bash++ result"

  go_out="${tmp}/${id}.go"; go_err="${tmp}/${id}.transpile.err"; transpile_rc=0
  capture /dev/null "${go_err}" "${pos_dir}" "${BASHY_BIN}" transpile "${pos_file}" -o "${go_out}" || transpile_rc=$?
  [ "${transpile_rc}" -eq 0 ] && [ -s "${go_out}" ] || fail "${id}: transpile did not produce Go"
  [ -x "$(command -v go 2>/dev/null || true)" ] || fail "go tool is unavailable for lowering parity"
  go_bin="${tmp}/${id}.bin"; (cd "${pos_dir}" && go build -o "${go_bin}" "${go_out}") ||
    fail "${id}: lowered Go failed to build"
  lower_out="${tmp}/${id}.lower.out"; lower_err="${tmp}/${id}.lower.err"; lower_rc=0
  "${go_bin}" >"${lower_out}" 2>"${lower_err}" || lower_rc=$?
  compare "${pos_out}" "${lower_out}" "${pos_err}" "${lower_err}" "${pos_rc}" "${lower_rc}" ||
    fail "${id}: interpreted/compiled parity mismatch"
  echo "Bash# ${id}: positive, inertness, diagnostics, and lowering parity passed"
done < "${MATRIX}"
echo "Bash# acceptance execution complete"
