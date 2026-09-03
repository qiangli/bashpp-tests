#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALIDATE="${SCRIPT_DIR}/validate.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashsharp-tamper.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/tests"
cp -R "${ROOT}/tests/bashsharp" "${tmp}/tests/bashsharp"
run_validator() {
  BASHPP_SHARP_ROOT="${tmp}" BASHPP_SHARP_MATRIX="${tmp}/tests/bashsharp/matrix.tsv" "${VALIDATE}"
}
run_validator >/dev/null

awk 'NR != 3' "${tmp}/tests/bashsharp/matrix.tsv" > "${tmp}/missing.tsv"
if BASHPP_SHARP_ROOT="${tmp}" BASHPP_SHARP_MATRIX="${tmp}/missing.tsv" "${VALIDATE}" >/dev/null 2>&1; then
  echo "Bash# tamper: missing-row mutation was accepted" >&2; exit 1
fi
awk 'NR == 2 { sub(/keyword-arguments/, "planned") } { print }' "${tmp}/tests/bashsharp/matrix.tsv" > "${tmp}/planned.tsv"
if BASHPP_SHARP_ROOT="${tmp}" BASHPP_SHARP_MATRIX="${tmp}/planned.tsv" "${VALIDATE}" >/dev/null 2>&1; then
  echo "Bash# tamper: planned mutation was accepted" >&2; exit 1
fi
awk 'NR == 3 { sub("defaults/near-miss.bpp", "kwargs/near-miss.bpp") } { print }' "${tmp}/tests/bashsharp/matrix.tsv" > "${tmp}/duplicate.tsv"
if BASHPP_SHARP_ROOT="${tmp}" BASHPP_SHARP_MATRIX="${tmp}/duplicate.tsv" "${VALIDATE}" >/dev/null 2>&1; then
  echo "Bash# tamper: denominator/reference mutation was accepted" >&2; exit 1
fi
touch "${tmp}/tests/bashsharp/kwargs/unreferenced.bpp"
if BASHPP_SHARP_ROOT="${tmp}" BASHPP_SHARP_MATRIX="${tmp}/tests/bashsharp/matrix.tsv" "${VALIDATE}" >/dev/null 2>&1; then
  echo "Bash# tamper: denominator expansion was accepted" >&2; exit 1
fi
ln -s positive.bpp "${tmp}/tests/bashsharp/kwargs/symlink.bpp"
if BASHPP_SHARP_ROOT="${tmp}" BASHPP_SHARP_MATRIX="${tmp}/tests/bashsharp/matrix.tsv" "${VALIDATE}" >/dev/null 2>&1; then
  echo "Bash# tamper: symlink was accepted" >&2; exit 1
fi
echo "Bash# tamper tests OK — denominator, status, references, and symlinks fail closed"
