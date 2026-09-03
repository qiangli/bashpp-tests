#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MATRIX="${ROOT}/tests/bashsharp/matrix.tsv"
FIXTURE_ROOT="${ROOT}/tests/bashsharp"
VALIDATE="${SCRIPT_DIR}/validate.sh"
BASH_ENGINE_BIN="${BASH_ENGINE_BIN:-${BASH_BIN:-${ROOT}/../bashy/bin/bash}}"
BASHY_BIN="${BASHY_BIN:-${ROOT}/../bashy/bashy}"
GO_BIN="${GO_BIN:-go}"
fail() { echo "Bash# Sprint 117: $*" >&2; exit 1; }

"${VALIDATE}" || fail "matrix validation failed"
[ -x "${BASH_ENGINE_BIN}" ] || fail "shell engine is not executable: ${BASH_ENGINE_BIN}"
[ -x "${BASHY_BIN}" ] || fail "bashy front door is not executable: ${BASHY_BIN}"
command -v "${GO_BIN}" >/dev/null 2>&1 || fail "Go tool is unavailable for lowering"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashsharp-117.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
: > "${tmp}/empty"
cases=0

same_result() {
  cmp -s "$1" "$2" && cmp -s "$3" "$4" && [ "$5" -eq "$6" ]
}
expected_file() {
  local family_dir="$1" token="$2"
  if [ "${token}" = empty ]; then printf '%s\n' "${tmp}/empty"; else printf '%s\n' "${family_dir}/${token}"; fi
}

while IFS=$'\t' read -r id feature class case_ledger lowering_ledger; do
  [ -z "${id}" ] && continue
  [[ "${id}" == \#* ]] && continue
  family_dir="${FIXTURE_ROOT}/$(dirname "${lowering_ledger}")"
  while IFS=$'\t' read -r case_id fixture expectation expected_rc stdout stderr; do
    [ -z "${case_id}" ] && continue
    [[ "${case_id}" == \#* ]] && continue
    cases=$((cases + 1))
    stem="${tmp}/${id}.${case_id}"
    expected_out="$(expected_file "${family_dir}" "${stdout}")"
    expected_err="$(expected_file "${family_dir}" "${stderr}")"
    transpile_rc=0
    (cd "${family_dir}" && "${BASHY_BIN}" transpile --bashpp "${fixture}" -o "${stem}.one.go") >"${stem}.transpile.out" 2>"${stem}.transpile.err" || transpile_rc=$?
    transpile2_rc=0
    (cd "${family_dir}" && "${BASHY_BIN}" transpile --bashpp "${fixture}" -o "${stem}.two.go") >"${stem}.transpile2.out" 2>"${stem}.transpile2.err" || transpile2_rc=$?

    if [ "${expectation}" = reject ]; then
      [ "${transpile_rc}" -eq "${expected_rc}" ] || fail "${id}/${case_id}: transpile exit ${transpile_rc}, expected ${expected_rc}"
      [ "${transpile2_rc}" -eq "${transpile_rc}" ] || fail "${id}/${case_id}: repeated diagnostic exit changed"
      cmp -s "${stem}.transpile.out" "${expected_out}" || fail "${id}/${case_id}: transpile stdout mismatch"
      cmp -s "${stem}.transpile.err" "${expected_err}" || fail "${id}/${case_id}: transpile diagnostic mismatch"
      cmp -s "${stem}.transpile.out" "${stem}.transpile2.out" && cmp -s "${stem}.transpile.err" "${stem}.transpile2.err" ||
        fail "${id}/${case_id}: transpile diagnostic is nondeterministic"
      [ ! -e "${stem}.one.go" ] || [ ! -s "${stem}.one.go" ] || fail "${id}/${case_id}: rejected lowering emitted Go"
      echo "Bash# Sprint 117 ${id}/${case_id}: deterministic lowering diagnostic passed"
      continue
    fi

    [ "${transpile_rc}" -eq 0 ] && [ -s "${stem}.one.go" ] || fail "${id}/${case_id}: transpile did not produce Go"
    [ "${transpile2_rc}" -eq 0 ] && [ -s "${stem}.two.go" ] || fail "${id}/${case_id}: repeated transpile did not produce Go"
    cmp -s "${stem}.one.go" "${stem}.two.go" || fail "${id}/${case_id}: lowering is nondeterministic"
    "${GO_BIN}" build -o "${stem}.bin" "${stem}.one.go" || fail "${id}/${case_id}: lowered Go did not build"

    interp_rc=0
    (cd "${family_dir}" && "${BASH_ENGINE_BIN}" --bashpp "${fixture}") >"${stem}.interp.out" 2>"${stem}.interp.err" || interp_rc=$?
    lower_rc=0
    "${stem}.bin" >"${stem}.lower.out" 2>"${stem}.lower.err" || lower_rc=$?
    same_result "${stem}.interp.out" "${stem}.lower.out" "${stem}.interp.err" "${stem}.lower.err" "${interp_rc}" "${lower_rc}" ||
      fail "${id}/${case_id}: interpreted/lowered parity mismatch"
    [ "${lower_rc}" -eq "${expected_rc}" ] || fail "${id}/${case_id}: lowered exit ${lower_rc}, expected ${expected_rc}"
    cmp -s "${stem}.lower.out" "${expected_out}" || fail "${id}/${case_id}: lowered stdout mismatch"
    cmp -s "${stem}.lower.err" "${expected_err}" || fail "${id}/${case_id}: lowered stderr mismatch"
    echo "Bash# Sprint 117 ${id}/${case_id}: deterministic lowering parity passed"
  done < "${FIXTURE_ROOT}/${lowering_ledger}"
done < "${MATRIX}"

[ "${cases}" -eq 33 ] || fail "executed ${cases} lowering cases, expected 33"
echo "Bash# Sprint 117 lowering gate complete — ${cases} cases"
