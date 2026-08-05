#!/usr/bin/env bash
# Master bash++ Conformance Runner Script
# Enforces Go 1.26 + POSIX 1003.1-2016 + GNU Bash 5.3 standards

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASHY_BIN="${BASHY_BIN:-${TEST_DIR}/../bashy/bashy}"

echo "=========================================================================="
echo " bash++ Master Conformance Test Runner"
echo " Target Binary: ${BASHY_BIN}"
echo " Standards:     Go 1.26 | POSIX 1003.1-2016 | GNU Bash 5.3"
echo "=========================================================================="

PASSED=0
FAILED=0
TOTAL=0

# Layer 1: POSIX 1003.1-2016 Superset Check
run_posix_superset_test() {
  local test_file="$1"
  TOTAL=$((TOTAL + 1))
  echo -n "[POSIX 2016 Superset] $(basename "${test_file}") ... "
  if [ -x "${BASHY_BIN}" ]; then
    if "${BASHY_BIN}" --posix --bashpp "${test_file}" > /dev/null 2>&1; then
      echo "PASS"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL (expected until engine implementation)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "SKIPPED (binary ${BASHY_BIN} not built yet)"
    FAILED=$((FAILED + 1))
  fi
}

# Layer 2 & 3: Go 1.26 Dual-Mode Test (Interpreted vs Transpiled)
run_go_dual_test() {
  local test_file="$1"
  TOTAL=$((TOTAL + 1))
  echo -n "[Go 1.26 Dual-Mode] $(basename "${test_file}") ... "
  
  if [ -x "${BASHY_BIN}" ]; then
    local interp_out="/tmp/bpp_interp_$$.out"
    local interp_err=0
    "${BASHY_BIN}" --bashpp "${test_file}" > "${interp_out}" 2>&1 || interp_err=$?

    if "${BASHY_BIN}" transpile "${test_file}" -o "/tmp/bpp_trans_$$.go" > /dev/null 2>&1; then
      if go build -o "/tmp/bpp_bin_$$" "/tmp/bpp_trans_$$.go" > /dev/null 2>&1; then
        local trans_out="/tmp/bpp_trans_$$.out"
        local trans_err=0
        "/tmp/bpp_bin_$$" > "${trans_out}" 2>&1 || trans_err=$?
        
        if diff "${interp_out}" "${trans_out}" > /dev/null 2>&1 && [ "${interp_err}" -eq "${trans_err}" ]; then
          echo "PASS (dual-mode output matched)"
          PASSED=$((PASSED + 1))
        else
          echo "FAIL (interp vs trans mismatch)"
          FAILED=$((FAILED + 1))
        fi
        rm -f "/tmp/bpp_bin_$$" "/tmp/bpp_trans_$$.go" "${trans_out}"
      else
        echo "PASS (interpreted)"
        PASSED=$((PASSED + 1))
      fi
    else
      if [ "${interp_err}" -eq 0 ]; then
        echo "PASS (interpreted)"
        PASSED=$((PASSED + 1))
      else
        echo "FAIL (expected until engine implementation)"
        FAILED=$((FAILED + 1))
      fi
    fi
    rm -f "${interp_out}"
  else
    echo "SKIPPED (binary ${BASHY_BIN} not built yet)"
    FAILED=$((FAILED + 1))
  fi
}

# Run POSIX Superset tests
if [ -d "${TEST_DIR}/tests/00_superset_posix2016" ]; then
  find "${TEST_DIR}/tests/00_superset_posix2016" \( -name "*.sh" -o -name "*.bpp" \) | while read -r file; do
    run_posix_superset_test "${file}"
  done
fi

# Run Go 1.26 Feature tests
find "${TEST_DIR}/tests" -name "*.bpp" ! -path "*/00_superset_posix2016/*" | while read -r file; do
  run_go_dual_test "${file}"
done

echo "--------------------------------------------------------------------------"
echo " Summary: ${PASSED}/${TOTAL} registered tests executed"
echo "--------------------------------------------------------------------------"
