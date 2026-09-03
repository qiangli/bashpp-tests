#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashsharp-tamper.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/tests" "${tmp}/tools"
cp -R "${ROOT}/tests/bashsharp" "${tmp}/tests/bashsharp"
cp -R "${ROOT}/tools/bashsharp" "${tmp}/tools/bashsharp"

run_validator() {
  BASHPP_SHARP_ROOT="${tmp}" \
  BASHPP_SHARP_MATRIX="${tmp}/tests/bashsharp/matrix.tsv" \
  BASHPP_SHARP_TOOLS_ROOT="${tmp}/tools/bashsharp" \
    "${tmp}/tools/bashsharp/validate.sh"
}
expect_rejected() {
  local label="$1"
  if run_validator >/dev/null 2>&1; then
    echo "Bash# tamper: ${label} mutation was accepted" >&2
    exit 1
  fi
}

run_validator >/dev/null

fake_log="${tmp}/executions.log"
: > "${fake_log}"
cat > "${tmp}/fake-engine" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'engine\t%s\n' "$*" >> "${BASHSHARP_FAKE_LOG}"
enabled=false
posix=false
fixture=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bashpp) enabled=true ;;
    --posix) posix=true ;;
    -c) exit 0 ;;
    *) fixture="$1" ;;
  esac
  shift
done
family="$(basename "$PWD")"
if ! ${enabled} || ${posix}; then
  printf 'plain:%s/%s\n' "${family}" "${fixture}"
  exit 7
fi
row="$(awk -F '\t' -v needle="${fixture}" '$1 !~ /^#/ && $4 == needle { print; exit }' cases.tsv)"
[ -n "${row}" ] || exit 99
IFS=$'\t' read -r case_id driver expectation source expected_rc stdout stderr <<< "${row}"
if [ "${expectation}" = plain-parity ]; then
  printf 'plain:%s/%s\n' "${family}" "${fixture}"
  exit 7
fi
[ "${stdout}" = empty ] || cat "${stdout}"
[ "${stderr}" = empty ] || cat "${stderr}" >&2
exit "${expected_rc}"
EOF
cat > "${tmp}/fake-bashy" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'front-door\t%s\n' "$*" >> "${BASHSHARP_FAKE_LOG}"
[ "${1:-}" != transpile ] || exit 98
[ "${1:-}" = check ] || exit 99
shift
enabled=false
fixture=''
while [ "$#" -gt 0 ]; do
  case "$1" in --bashpp) enabled=true ;; *) fixture="$1" ;; esac
  shift
done
${enabled} || exit 0
row="$(awk -F '\t' -v needle="${fixture}" '$1 !~ /^#/ && $4 == needle { print; exit }' cases.tsv)"
[ -n "${row}" ] || exit 99
IFS=$'\t' read -r case_id driver expectation source expected_rc stdout stderr <<< "${row}"
[ "${stdout}" = empty ] || cat "${stdout}"
[ "${stderr}" = empty ] || cat "${stderr}" >&2
exit "${expected_rc}"
EOF
chmod +x "${tmp}/fake-engine" "${tmp}/fake-bashy"
BASHSHARP_FAKE_LOG="${fake_log}" BASH_ENGINE_BIN="${tmp}/fake-engine" BASHY_BIN="${tmp}/fake-bashy" \
  "${tmp}/tools/bashsharp/acceptance.sh" >/dev/null
[ "$(wc -l < "${fake_log}" | tr -d ' ')" -eq 124 ] || {
  echo "Bash# tamper: Sprint 114 gate did not execute its 124-command oracle" >&2
  exit 1
}
grep -q $'^front-door\ttranspile' "${fake_log}" && {
  echo "Bash# tamper: Sprint 114 gate invoked transpile" >&2
  exit 1
}

rm "${tmp}/tests/bashsharp/kwargs/missing-required.bpp"
expect_rejected "missing-fixture"
cp "${ROOT}/tests/bashsharp/kwargs/missing-required.bpp" "${tmp}/tests/bashsharp/kwargs/missing-required.bpp"

awk 'NR != 3' "${ROOT}/tests/bashsharp/matrix.tsv" > "${tmp}/tests/bashsharp/matrix.tsv"
expect_rejected "missing-approved-row"
cp "${ROOT}/tests/bashsharp/matrix.tsv" "${tmp}/tests/bashsharp/matrix.tsv"

awk 'BEGIN { FS=OFS="\t" } $1 == "kwargs" { $3="E" } { print }' "${ROOT}/tests/bashsharp/matrix.tsv" > "${tmp}/tests/bashsharp/matrix.tsv"
expect_rejected "weakened-row"
cp "${ROOT}/tests/bashsharp/matrix.tsv" "${tmp}/tests/bashsharp/matrix.tsv"

sed '2,$d' "${ROOT}/tests/bashsharp/null-safety/cases.tsv" > "${tmp}/tests/bashsharp/null-safety/cases.tsv"
expect_rejected "zero-execution"
cp "${ROOT}/tests/bashsharp/null-safety/cases.tsv" "${tmp}/tests/bashsharp/null-safety/cases.tsv"

awk '$1 != "mutate-alias"' "${ROOT}/tests/bashsharp/readonly/lowering.tsv" > "${tmp}/tests/bashsharp/readonly/lowering.tsv"
expect_rejected "weakened-lowering"
cp "${ROOT}/tests/bashsharp/readonly/lowering.tsv" "${tmp}/tests/bashsharp/readonly/lowering.tsv"

awk '$1 != "optional-chaining"' "${ROOT}/tests/bashsharp/rejected.tsv" > "${tmp}/tests/bashsharp/rejected.tsv"
expect_rejected "lost-rejected-exclusion"
cp "${ROOT}/tests/bashsharp/rejected.tsv" "${tmp}/tests/bashsharp/rejected.tsv"

sed 's/same_result "${stem}.plain.out" "${stem}.posix.out"/same_result "${stem}.enabled.out" "${stem}.posix.out"/' \
  "${ROOT}/tools/bashsharp/acceptance.sh" > "${tmp}/tools/bashsharp/acceptance.sh"
chmod +x "${tmp}/tools/bashsharp/acceptance.sh"
expect_rejected "wrong-POSIX-oracle"
cp "${ROOT}/tools/bashsharp/acceptance.sh" "${tmp}/tools/bashsharp/acceptance.sh"

mv "${tmp}/tools/bashsharp/lowering.sh" "${tmp}/tools/bashsharp/lowering.removed"
expect_rejected "lost-lowering-phase"
mv "${tmp}/tools/bashsharp/lowering.removed" "${tmp}/tools/bashsharp/lowering.sh"

printf '%s\n' "command printf '%s\\n' 'type Color enum { Red; Green }'" > "${tmp}/tests/bashsharp/enums/forced-command.bpp"
expect_rejected "fake-forced-shell"
cp "${ROOT}/tests/bashsharp/enums/forced-command.bpp" "${tmp}/tests/bashsharp/enums/forced-command.bpp"

touch "${tmp}/tests/bashsharp/kwargs/unreferenced.bpp"
expect_rejected "open-denominator"
rm "${tmp}/tests/bashsharp/kwargs/unreferenced.bpp"

ln -s bind-reordered.bpp "${tmp}/tests/bashsharp/kwargs/symlink.bpp"
expect_rejected "symlink"

echo "Bash# tamper tests OK — fixtures, execution denominator, rows, POSIX oracle, escapes, and lowering fail closed"
