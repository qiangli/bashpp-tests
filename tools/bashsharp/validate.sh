#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS_ROOT="${BASHPP_SHARP_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
MATRIX="${BASHPP_SHARP_MATRIX:-${CORPUS_ROOT}/tests/bashsharp/matrix.tsv}"
FIXTURE_ROOT="${CORPUS_ROOT}/tests/bashsharp"
TOOLS_ROOT="${BASHPP_SHARP_TOOLS_ROOT:-${CORPUS_ROOT}/tools/bashsharp}"

fail() { echo "Bash# matrix: $*" >&2; exit 1; }
safe_rel() { [[ "$1" != /* && "$1" != *..* && "$1" != *//* ]]; }

[ -f "${MATRIX}" ] || fail "matrix is missing: ${MATRIX}"
[ -d "${FIXTURE_ROOT}" ] || fail "fixture directory is missing: ${FIXTURE_ROOT}"
[ -x "${TOOLS_ROOT}/acceptance.sh" ] || fail "Sprint 114 interpreted gate is missing or not executable"
[ -x "${TOOLS_ROOT}/lowering.sh" ] || fail "Sprint 117 lowering gate is missing or not executable"
find "${FIXTURE_ROOT}" -type l -print -quit | grep -q . && fail "symlink found in corpus"
grep -Fq '\t' "${MATRIX}" && fail "matrix contains literal \\t escapes; use TSV tabs"
grep -Eiq '(^|[[:space:]])(planned|skip|skipped|n/a)([[:space:]]|$)' "${MATRIX}" &&
  fail "planned/skip status is not permitted"
grep -Fq 'same_result "${stem}.plain.out" "${stem}.posix.out"' "${TOOLS_ROOT}/acceptance.sh" ||
  fail "Sprint 114 gate does not compare POSIX+Bash++ with the plain/POSIX-off oracle"
grep -Eq 'same_result .*enabled[^ ]*\.out.*posix[^ ]*\.out|same_result .*posix[^ ]*\.out.*enabled[^ ]*\.out' "${TOOLS_ROOT}/acceptance.sh" &&
  fail "Sprint 114 gate compares POSIX+Bash++ with enabled Bash++"
grep -Fq 'transpile --bashpp' "${TOOLS_ROOT}/acceptance.sh" &&
  fail "Sprint 114 interpreted gate must not demand transpilation"
grep -Fq 'transpile --bashpp' "${TOOLS_ROOT}/lowering.sh" ||
  fail "Sprint 117 lowering gate no longer invokes transpilation"
grep -Fq 'interpreted/lowered parity mismatch' "${TOOLS_ROOT}/lowering.sh" ||
  fail "Sprint 117 lowering gate no longer enforces parity"

declare -a expected=(kwargs defaults readonly enums null-safety)
declare -A seen=() refs=() case_ids=()
declare -A required_cases=(
  [kwargs]='bind-reordered,ordinary-positional-interaction,unknown-name,duplicate-name,duplicate-binding,missing-required,near-miss'
  [defaults]='omitted-default,explicit-override,keyword-override-interaction,missing-required,too-many,nontrailing-default,near-miss'
  [readonly]='deep-read,mutate-root,mutate-map,mutate-slice,mutate-struct,mutate-alias,mutate-subshell,mutate-imported,near-miss'
  [enums]='exhaustive,default-arm,nested-switch,invalid-member,duplicate-member,non-exhaustive,invalid-value,near-miss,forced-command,forced-quote'
  [null-safety]='flow-narrow,false-positive-guards,reassign-after-narrow,unsafe-deref,unsafe-index,unsafe-call'
)
declare -A required_lowering=(
  [kwargs]='bind-reordered,ordinary-positional-interaction,unknown-name,duplicate-name,duplicate-binding,missing-required'
  [defaults]='omitted-default,explicit-override,keyword-override-interaction,missing-required,too-many,nontrailing-default'
  [readonly]='deep-read,mutate-root,mutate-map,mutate-slice,mutate-struct,mutate-alias,mutate-subshell,mutate-imported'
  [enums]='exhaustive,default-arm,nested-switch,invalid-member,duplicate-member,non-exhaustive,invalid-value'
  [null-safety]='flow-narrow,false-positive-guards,reassign-after-narrow,unsafe-deref,unsafe-index,unsafe-call'
)

validate_expectation_file() {
  local family="$1" token="$2" stream="$3" full
  case "${token}" in
    empty|plain) return ;;
  esac
  safe_rel "${token}" || fail "unsafe ${stream} expectation in ${family}: ${token}"
  full="${FIXTURE_ROOT}/${family}/${token}"
  [ -f "${full}" ] || fail "missing ${stream} expectation: ${family}/${token}"
  [ ! -L "${full}" ] || fail "expectation is a symlink: ${family}/${token}"
  refs["${family}/${token}"]=1
}

validate_cases() {
  local id="$1" ledger="$2" family_dir ids='' count=0 case_key
  local -A local_seen=()
  family_dir="$(dirname "${ledger}")"
  while IFS=$'\t' read -r case_id driver expectation fixture expected_rc stdout stderr extra; do
    [ -z "${case_id}" ] && continue
    [[ "${case_id}" == \#* ]] && continue
    [ -z "${extra:-}" ] || fail "${ledger}: case ${case_id} has extra fields"
    [ -n "${stderr:-}" ] || fail "${ledger}: case ${case_id} does not have 7 fields"
    [ -z "${local_seen[$case_id]+x}" ] || fail "${ledger}: duplicate case ${case_id}"
    local_seen["${case_id}"]=1
    case "${driver}:${expectation}" in
      engine:exact|engine:plain-parity|checker:exact) ;;
      *) fail "${ledger}: invalid driver/expectation for ${case_id}: ${driver}/${expectation}" ;;
    esac
    case "${expectation}:${expected_rc}:${stdout}:${stderr}" in
      plain-parity:plain:plain:plain) ;;
      exact:plain:*|exact:*:plain:*|exact:*:*:plain) fail "${ledger}: exact case ${case_id} uses plain sentinel" ;;
      exact:[0-9]*:*) ;;
      *) fail "${ledger}: invalid expected result for ${case_id}" ;;
    esac
    safe_rel "${fixture}" || fail "unsafe fixture in ${ledger}: ${fixture}"
    [ -f "${FIXTURE_ROOT}/${family_dir}/${fixture}" ] || fail "missing fixture: ${family_dir}/${fixture}"
    refs["${family_dir}/${fixture}"]=1
    validate_expectation_file "${family_dir}" "${stdout}" stdout
    validate_expectation_file "${family_dir}" "${stderr}" stderr
    if [ "${expectation}" = exact ] && [ "${expected_rc}" -ne 0 ]; then
      [ "${stderr}" != empty ] || fail "${ledger}: failing case ${case_id} lacks an exact diagnostic"
      grep -Eq '^BASHPP-E[A-Z0-9-]+: .+' "${FIXTURE_ROOT}/${family_dir}/${stderr}" ||
        fail "${ledger}: ${case_id} diagnostic lacks a stable Bash# code and message"
      [ "$(wc -l < "${FIXTURE_ROOT}/${family_dir}/${stderr}" | tr -d ' ')" -eq 1 ] ||
        fail "${ledger}: ${case_id} diagnostic must be exactly one stable line"
    fi
    ids="${ids}${ids:+,}${case_id}"
    case_ids["${id}:${case_id}"]=1
    count=$((count + 1))
  done < "${FIXTURE_ROOT}/${ledger}"
  [ "${count}" -gt 0 ] || fail "${ledger}: zero executable cases"
  [ "${ids}" = "${required_cases[$id]}" ] || fail "${id}: weakened or reordered case denominator: ${ids}"
}

validate_lowering() {
  local id="$1" ledger="$2" family_dir ids='' count=0
  local -A local_seen=()
  family_dir="$(dirname "${ledger}")"
  while IFS=$'\t' read -r case_id fixture expectation expected_rc stdout stderr extra; do
    [ -z "${case_id}" ] && continue
    [[ "${case_id}" == \#* ]] && continue
    [ -z "${extra:-}" ] || fail "${ledger}: lowering case ${case_id} has extra fields"
    [ -n "${stderr:-}" ] || fail "${ledger}: lowering case ${case_id} does not have 6 fields"
    case_key="${id}:${case_id}"
    [ -n "${case_ids[$case_key]+x}" ] || fail "${ledger}: lowering case ${case_id} is not interpreted"
    [ -z "${local_seen[$case_id]+x}" ] || fail "${ledger}: duplicate lowering case ${case_id}"
    local_seen["${case_id}"]=1
    case "${expectation}" in run|reject) ;; *) fail "${ledger}: invalid lowering expectation for ${case_id}: ${expectation}" ;; esac
    [ "${expectation}" != reject ] || [ "${expected_rc}" -ne 0 ] || fail "${ledger}: rejected case ${case_id} expects success"
    [[ "${expected_rc}" =~ ^[0-9]+$ ]] || fail "${ledger}: invalid exit for ${case_id}"
    safe_rel "${fixture}" || fail "unsafe lowering fixture in ${ledger}: ${fixture}"
    [ -f "${FIXTURE_ROOT}/${family_dir}/${fixture}" ] || fail "missing lowering fixture: ${family_dir}/${fixture}"
    refs["${family_dir}/${fixture}"]=1
    validate_expectation_file "${family_dir}" "${stdout}" stdout
    validate_expectation_file "${family_dir}" "${stderr}" stderr
    ids="${ids}${ids:+,}${case_id}"
    count=$((count + 1))
  done < "${FIXTURE_ROOT}/${ledger}"
  [ "${count}" -gt 0 ] || fail "${ledger}: zero lowering cases"
  [ "${ids}" = "${required_lowering[$id]}" ] || fail "${id}: weakened or reordered lowering denominator: ${ids}"
}

rows=0
while IFS=$'\t' read -r id feature class cases lowering extra; do
  [ -z "${id}" ] && continue
  [[ "${id}" == \#* ]] && continue
  [ -z "${extra:-}" ] || fail "matrix row ${id} has extra fields"
  [ -n "${lowering:-}" ] || fail "matrix row ${id} does not have 5 fields"
  [ "${expected[${rows}]:-}" = "${id}" ] || fail "row ${rows} must be ${expected[${rows}]:-none}, got ${id}"
  [ -z "${seen[$id]+x}" ] || fail "duplicate feature id: ${id}"
  seen["${id}"]=1
  case "${id}:${feature}:${class}:${cases}:${lowering}" in
    kwargs:keyword-arguments:R:kwargs/cases.tsv:kwargs/lowering.tsv|defaults:default-parameters:R:defaults/cases.tsv:defaults/lowering.tsv|readonly:deep-readonly:E:readonly/cases.tsv:readonly/lowering.tsv|enums:exhaustive-enums:E:enums/cases.tsv:enums/lowering.tsv|null-safety:null-safety:checker:null-safety/cases.tsv:null-safety/lowering.tsv) ;;
    *) fail "unapproved or weakened matrix row: ${id}" ;;
  esac
  refs["${cases}"]=1
  refs["${lowering}"]=1
  validate_cases "${id}" "${cases}"
  validate_lowering "${id}" "${lowering}"
  rows=$((rows + 1))
done < "${MATRIX}"
[ "${rows}" -eq 5 ] || fail "expected exactly five approved rows, got ${rows}"

for forbidden in comprehension ternary match try-catch overloading inheritance async-await optional-chain nullish decorator; do
  [ -z "${seen[$forbidden]+x}" ] || fail "rejected Bash# feature was added: ${forbidden}"
done

refs[rejected.tsv]=1
rejected_rows=''
while IFS=$'\t' read -r feature decision extra; do
  [ -z "${feature}" ] && continue
  [[ "${feature}" == \#* ]] && continue
  [ -z "${extra:-}" ] || fail "rejected.tsv row ${feature} has extra fields"
  rejected_rows="${rejected_rows}${rejected_rows:+,}${feature}:${decision}"
done < "${FIXTURE_ROOT}/rejected.tsv"
[ "${rejected_rows}" = 'list-comprehensions:rejected,ternary:rejected,pattern-match:rejected,try-catch:rejected,operator-overloading:rejected,method-overloading:rejected,inheritance:rejected,async-await:rejected,optional-chaining:rejected,nullish-operators:rejected,separate-bashsharp-mode:rejected,decorators:deferred,arrow-syntax:never-claimed' ] ||
  fail "rejected/deferred Bash# exclusions changed: ${rejected_rows}"

grep -Eq '^command type Color enum ' "${FIXTURE_ROOT}/enums/forced-command.bpp" ||
  fail "enum command escape does not execute the committed type/enum start site"
grep -Eq '^"type" Color enum ' "${FIXTURE_ROOT}/enums/forced-quote.bpp" ||
  fail "enum quote escape does not execute the committed type/enum start site"
grep -Eq "printf .*type Color enum|printf .*readonly|printf .*name:" "${FIXTURE_ROOT}"/*/forced-*.bpp 2>/dev/null &&
  fail "forced-shell fixture merely prints Bash# source"

while IFS= read -r filepath; do
  rel="${filepath#${FIXTURE_ROOT}/}"
  case "${rel}" in README.md|matrix.tsv) continue ;; esac
  [ -n "${refs[$rel]+x}" ] || fail "unreferenced corpus file: ${rel}"
done < <(find "${FIXTURE_ROOT}" -type f \( -name '*.bpp' -o -name '*.out' -o -name '*.err' -o -name '*.tsv' \) | sort)

echo "Bash# matrix schema OK — 5 approved features, 39 interpreted cases, 33 lowering cases"
