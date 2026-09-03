#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS_ROOT="${BASHPP_SHARP_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
MATRIX="${BASHPP_SHARP_MATRIX:-${CORPUS_ROOT}/tests/bashsharp/matrix.tsv}"
FIXTURE_ROOT="${CORPUS_ROOT}/tests/bashsharp"

fail() { echo "Bash# matrix: $*" >&2; exit 1; }
[ -f "${MATRIX}" ] || fail "matrix is missing: ${MATRIX}"
[ -d "${FIXTURE_ROOT}" ] || fail "fixture directory is missing: ${FIXTURE_ROOT}"
find "${FIXTURE_ROOT}" -type l -print -quit | grep -q . && fail "symlink found in corpus"
grep -Fq '\t' "${MATRIX}" && fail "matrix contains literal \\t escapes; use TSV tabs"
grep -Eiq '(^|[[:space:]])(planned|skip|skipped|n/a)([[:space:]]|$)' "${MATRIX}" &&
  fail "planned/skip status is not permitted"

declare -a expected=(kwargs defaults readonly enums null-safety)
declare -A seen=() refs=()
rows=0
while IFS=$'\t' read -r -a f; do
  [ "${#f[@]}" -eq 0 ] && continue
  [[ "${f[0]}" == \#* ]] && continue
  [ "${#f[@]}" -eq 11 ] || fail "row has ${#f[@]} fields: ${f[*]}"
  id="${f[0]}"; feature="${f[1]}"
  [ "${expected[$rows]:-}" = "${id}" ] || fail "row ${rows} must be ${expected[$rows]:-none}, got ${id}"
  [ -z "${seen[$id]+x}" ] || fail "duplicate feature id: ${id}"
  seen["$id"]=1
  case "$id:$feature" in
    kwargs:keyword-arguments|defaults:default-parameters|readonly:deep-readonly|enums:exhaustive-enums|null-safety:null-safety) ;;
    *) fail "wrong feature label for ${id}: ${feature}" ;;
  esac
  case "$id:${f[7]}" in
    null-safety:${f[2]}) ;;
    null-safety:*) fail "null-safety checker must be its positive fixture" ;;
    *:none) ;;
    *) fail "unexpected checker for ${id}" ;;
  esac
  case "$id:${f[9]}" in
    readonly:0|kwargs:0|defaults:0|enums:0|null-safety:0) ;;
    *) fail "invalid expected exit for ${id}: ${f[9]}" ;;
  esac
  for n in 2 3 4 5 6 7 8 10; do
    path="${f[$n]}"
    [ "$path" != none ] || continue
    [[ "$path" != /* && "$path" != *..* ]] || fail "unsafe path in ${id}: ${path}"
    full="${FIXTURE_ROOT}/${path}"
    [ -f "$full" ] || fail "missing fixture: ${path}"
    [ ! -L "$full" ] || fail "fixture is symlink: ${path}"
    refs["$path"]=1
  done
  rows=$((rows + 1))
done < "${MATRIX}"
[ "$rows" -eq 5 ] || fail "expected exactly five rows, got ${rows}"

while IFS= read -r path; do
  rel="${path#${FIXTURE_ROOT}/}"
  [ -n "${refs[$rel]+x}" ] || fail "unreferenced corpus file: ${rel}"
done < <(find "${FIXTURE_ROOT}" -type f \( -name '*.bpp' -o -name '*.out' \) | sort)

for id in "${expected[@]}"; do [ -n "${seen[$id]+x}" ] || fail "missing row: ${id}"; done
echo "Bash# matrix schema OK — 5 features, closed fixture set"
