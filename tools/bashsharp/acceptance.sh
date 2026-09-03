#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MATRIX="${ROOT}/tests/bashsharp/matrix.tsv"
FIXTURE_ROOT="${ROOT}/tests/bashsharp"
VALIDATE="${SCRIPT_DIR}/validate.sh"
BASH_ENGINE_BIN="${BASH_ENGINE_BIN:-${BASH_BIN:-${ROOT}/../bashy/bin/bash}}"
BASHY_BIN="${BASHY_BIN:-${ROOT}/../bashy/bashy}"
fail() { echo "Bash# Sprint 114: $*" >&2; exit 1; }

"${VALIDATE}" || fail "matrix validation failed"
[ -x "${BASH_ENGINE_BIN}" ] || fail "shell engine is not executable: ${BASH_ENGINE_BIN}"
[ -x "${BASHY_BIN}" ] || fail "bashy front door is not executable: ${BASHY_BIN}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashsharp-114.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
: > "${tmp}/empty"
executions=0
cases=0

capture() {
  local out="$1" err="$2" cwd="$3"; shift 3
  executions=$((executions + 1))
  (cd "${cwd}" && "$@") >"${out}" 2>"${err}"
}
same_result() {
  cmp -s "$1" "$2" && cmp -s "$3" "$4" && [ "$5" -eq "$6" ]
}
expected_file() {
  local family_dir="$1" token="$2"
  if [ "${token}" = empty ]; then printf '%s\n' "${tmp}/empty"; else printf '%s\n' "${family_dir}/${token}"; fi
}

probe_out="${tmp}/probe.out"; probe_err="${tmp}/probe.err"; probe_rc=0
capture "${probe_out}" "${probe_err}" "${ROOT}" "${BASH_ENGINE_BIN}" --bashpp -c ':' || probe_rc=$?
[ "${probe_rc}" -eq 0 ] || fail "shell engine rejected the --bashpp selector"

while IFS=$'\t' read -r id feature class case_ledger lowering; do
  [ -z "${id}" ] && continue
  [[ "${id}" == \#* ]] && continue
  family_dir="${FIXTURE_ROOT}/$(dirname "${case_ledger}")"
  while IFS=$'\t' read -r case_id driver expectation fixture expected_rc stdout stderr; do
    [ -z "${case_id}" ] && continue
    [[ "${case_id}" == \#* ]] && continue
    cases=$((cases + 1))
    stem="${tmp}/${id}.${case_id}"

    plain_rc=0
    capture "${stem}.plain.out" "${stem}.plain.err" "${family_dir}" "${BASH_ENGINE_BIN}" "${fixture}" || plain_rc=$?
    posix_rc=0
    capture "${stem}.posix.out" "${stem}.posix.err" "${family_dir}" "${BASH_ENGINE_BIN}" --posix --bashpp "${fixture}" || posix_rc=$?
    same_result "${stem}.plain.out" "${stem}.posix.out" "${stem}.plain.err" "${stem}.posix.err" "${plain_rc}" "${posix_rc}" ||
      fail "${id}/${case_id}: --posix --bashpp is not inert against the plain/POSIX-off oracle"

    enabled_rc=0
    case "${driver}" in
      engine)
        capture "${stem}.enabled.out" "${stem}.enabled.err" "${family_dir}" "${BASH_ENGINE_BIN}" --bashpp "${fixture}" || enabled_rc=$?
        if [ "${expectation}" = plain-parity ]; then
          same_result "${stem}.plain.out" "${stem}.enabled.out" "${stem}.plain.err" "${stem}.enabled.err" "${plain_rc}" "${enabled_rc}" ||
            fail "${id}/${case_id}: near-miss or forced shell escape changed under Bash++"
        else
          [ "${enabled_rc}" -eq "${expected_rc}" ] || fail "${id}/${case_id}: exit ${enabled_rc}, expected ${expected_rc}"
          expected_out="$(expected_file "${family_dir}" "${stdout}")"
          expected_err="$(expected_file "${family_dir}" "${stderr}")"
          cmp -s "${stem}.enabled.out" "${expected_out}" || fail "${id}/${case_id}: stdout mismatch"
          cmp -s "${stem}.enabled.err" "${expected_err}" || fail "${id}/${case_id}: diagnostic mismatch"
          if [ "${expected_rc}" -eq 0 ] && same_result "${stem}.plain.out" "${stem}.enabled.out" "${stem}.plain.err" "${stem}.enabled.err" "${plain_rc}" "${enabled_rc}"; then
            fail "${id}/${case_id}: positive case does not prove selector activation"
          fi
        fi
        ;;
      checker)
        capture "${stem}.enabled.out" "${stem}.enabled.err" "${family_dir}" "${BASHY_BIN}" check --bashpp "${fixture}" || enabled_rc=$?
        [ "${enabled_rc}" -eq "${expected_rc}" ] || fail "${id}/${case_id}: checker exit ${enabled_rc}, expected ${expected_rc}"
        expected_out="$(expected_file "${family_dir}" "${stdout}")"
        expected_err="$(expected_file "${family_dir}" "${stderr}")"
        cmp -s "${stem}.enabled.out" "${expected_out}" || fail "${id}/${case_id}: checker stdout mismatch"
        cmp -s "${stem}.enabled.err" "${expected_err}" || fail "${id}/${case_id}: checker diagnostic mismatch"
        off_check_rc=0
        capture "${stem}.check-off.out" "${stem}.check-off.err" "${family_dir}" "${BASHY_BIN}" check "${fixture}" || off_check_rc=$?
        if grep -Fq 'BASHPP-ENULL-' "${stem}.check-off.err"; then
          fail "${id}/${case_id}: null-safety checker leaked with the Bash++ selector off"
        fi
        ;;
    esac
    echo "Bash# Sprint 114 ${id}/${case_id}: interpreted contract passed"
  done < "${FIXTURE_ROOT}/${case_ledger}"
done < "${MATRIX}"

[ "${cases}" -eq 39 ] || fail "executed ${cases} cases, expected 39"
[ "${executions}" -ge $((cases * 3)) ] || fail "execution count ${executions} cannot prove the ${cases}-case contract"
echo "Bash# Sprint 114 interpreted gate complete — ${cases} cases, ${executions} executions"
