#!/usr/bin/env bash
# bash++ conformance runner.
#
# Standards: the enumerated Go profile (see ../docs/bashpp-posix-superset-syntax.md),
# POSIX 1003.1-2016, GNU Bash 5.3.
#
# THREE RESULT STATES, and the third one is why this suite can be honest.
#
#   PASS     the fixture is `supported` and behaved.
#   FAIL     the fixture is `supported` and misbehaved.        -> fails the run
#   PLANNED  the fixture is `planned`: the feature is not built yet, so it is
#            EXPECTED to fail and does not fail the run.
#
# Without the third state a TDD suite has to choose between reporting red
# forever (so nobody watches it) or scoring unimplemented features as passes
# (so red looks green). Both were live defects here. `planned` is declared in
# the manifest, never inferred from the outcome — a fixture is not excused
# because it failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASHY_BIN="${BASHY_BIN:-${TEST_DIR}/../bashy/bin/bash}"
MANIFEST="${MANIFEST:-${TEST_DIR}/tests/manifest.tsv}"

PASSED=0; FAILED=0; PLANNED=0; TOTAL=0
declare -a FAIL_NAMES=()
declare -a FEATURE_ORDER=()
declare -A FEAT_PASS=() FEAT_FAIL=() FEAT_PLAN=()

echo "=========================================================================="
echo " bash++ conformance runner"
echo " Target binary: ${BASHY_BIN}"
echo "=========================================================================="

if [ -x "${TEST_DIR}/tools/go-corpus/validate.sh" ]; then
  if ! "${TEST_DIR}/tools/go-corpus/validate.sh"; then
    echo "FATAL: Go corpus inventory validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/go-corpus/validate.sh missing — Go corpus inventory not checked" >&2
  exit 2
fi

if [ -x "${TEST_DIR}/tools/tour/validate.sh" ]; then
  if ! "${TEST_DIR}/tools/tour/validate.sh"; then
    echo "FATAL: Go tour inventory validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/tour/validate.sh missing — Go tour inventory not checked" >&2
  exit 2
fi

# The committed tour corpus (tour/: executable sources + upstream LICENSE) is
# checked on every run too: the pinned bytes must still BE the committed
# bytes, in both directions of the path-set, or the corpus is untrustworthy
# as the future Bash++ differential input.
if [ -x "${TEST_DIR}/tools/tour/validate-corpus.sh" ]; then
  if ! "${TEST_DIR}/tools/tour/validate-corpus.sh"; then
    echo "FATAL: Go tour corpus validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/tour/validate-corpus.sh missing — Go tour corpus not checked" >&2
  exit 2
fi

if [ -x "${TEST_DIR}/tools/go-by-example/validate.sh" ]; then
  if ! "${TEST_DIR}/tools/go-by-example/validate.sh"; then
    echo "FATAL: Go by Example corpus inventory validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/go-by-example/validate.sh missing — Go by Example corpus not checked" >&2
  exit 2
fi

# Final Go-by-Example verification is never optional: all 85 pinned programs
# must produce oracle, interpreted, compiled-build, and compiled-run records.
if [ -x "${TEST_DIR}/tools/go-by-example/gate.sh" ]; then
  "${TEST_DIR}/tools/go-by-example/gate.sh" || {
    echo "FATAL: Go by Example three-mode differential failed" >&2
    exit 2
  }
else
  echo "FATAL: Go by Example final gate missing" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# GO ORACLE — execute a reviewed tranche of the official Go corpus for real.
#
# This runs BEFORE the bashy checks and is independent of them: it measures the
# pinned Go toolchain against the pinned Go corpus, so that the Bash++ work above
# has a ground truth to be compared with later. It is not a Bash++ result and
# nothing here may be read as parity.
#
# Fatal by default, for the same reason the missing-binary check below is fatal:
# a run that measured nothing must not be reportable as a run. Set GO_ORACLE=off
# to declare, deliberately, that this invocation is not checking the oracle.
# ---------------------------------------------------------------------------
if [ "${GO_ORACLE:-on}" = off ]; then
  echo "NOTE: Go oracle DISABLED by GO_ORACLE=off; this run does not check the Go corpus." >&2
elif [ -x "${TEST_DIR}/tools/go-oracle/run.sh" ]; then
  echo
  if ! "${TEST_DIR}/tools/go-oracle/run.sh"; then
    echo "FATAL: the Go oracle did not execute its tranche cleanly" >&2
    exit 2
  fi
else
  echo "FATAL: tools/go-oracle/run.sh missing — the Go oracle was not run" >&2
  exit 2
fi

# Tour Go-baseline results: offline tamper-evident check that the checked-in
# records still bind to the pinned inventory revision, the exact pinned Go
# toolchain identity+checksum and the official helper module. Executing the
# baseline itself is the explicit tools/tour/run-baseline.sh step; this gate
# runs on every invocation so a stale or edited results file fails the run.
if [ -x "${TEST_DIR}/tools/tour/validate-results.sh" ]; then
  if ! "${TEST_DIR}/tools/tour/validate-results.sh"; then
    echo "FATAL: Go tour baseline results validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/tour/validate-results.sh missing — Go tour baseline results not checked" >&2
  exit 2
fi

# Story #4's three-mode JSONL ledger is validated independently from its
# producer. A FAIL verdict is honest evidence (and expected while the Bash++
# compiler is absent); structural/authenticity failure is fatal.
if [ -x "${TEST_DIR}/tools/tour/validate-evidence.sh" ]; then
  if ! "${TEST_DIR}/tools/tour/validate-evidence.sh"; then
    echo "FATAL: Tour JSONL evidence validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/tour/validate-evidence.sh missing — Tour evidence not checked" >&2
  exit 2
fi

# Bash# is an executable acceptance denominator, not a collection of optional
# fixtures. Validate both its closed file set and its tamper resistance before
# any target-binary check; a missing binary must not hide corpus corruption.
if [ -x "${TEST_DIR}/tools/bashsharp/validate.sh" ]; then
  if ! "${TEST_DIR}/tools/bashsharp/validate.sh"; then
    echo "FATAL: Bash# acceptance matrix validation failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/bashsharp/validate.sh missing — Bash# matrix not checked" >&2
  exit 2
fi
if [ -x "${TEST_DIR}/tools/bashsharp/tamper-tests.sh" ]; then
  if ! "${TEST_DIR}/tools/bashsharp/tamper-tests.sh"; then
    echo "FATAL: Bash# denominator/tamper tests failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/bashsharp/tamper-tests.sh missing — Bash# tamper checks not run" >&2
  exit 2
fi

if [ ! -x "${BASHY_BIN}" ]; then
  echo "FATAL: ${BASHY_BIN} is not executable." >&2
  echo "Build it first (cd ../bashy && make build-bash), or set BASHY_BIN." >&2
  echo "This is fatal rather than a skip: a run that measured nothing must not" >&2
  echo "be reportable as a run." >&2
  exit 2
fi

if [ -x "${TEST_DIR}/tools/bashsharp/acceptance.sh" ]; then
  if ! "${TEST_DIR}/tools/bashsharp/acceptance.sh"; then
    echo "FATAL: Bash# executable acceptance matrix failed" >&2
    exit 2
  fi
else
  echo "FATAL: tools/bashsharp/acceptance.sh missing — Bash# matrix not executed" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Manifest: id<TAB>status<TAB>feature.  Optional; absent means every fixture is
# `supported`, which is the conservative reading — an unlisted fixture is held
# to the full standard rather than quietly excused.
# ---------------------------------------------------------------------------
declare -A MF_STATUS=() MF_FEATURE=()
if [ -f "${MANIFEST}" ]; then
  while IFS=$'\t' read -r mid mstatus mfeature _rest; do
    case "${mid}" in ''|\#*) continue ;; esac
    MF_STATUS["${mid}"]="${mstatus}"
    MF_FEATURE["${mid}"]="${mfeature}"
  done < "${MANIFEST}"
fi

rel_id() { printf '%s' "${1#"${TEST_DIR}/"}"; }

status_of() {
  local id="$1"
  printf '%s' "${MF_STATUS[$id]:-supported}"
}

feature_of() {
  local id="$1" f="${MF_FEATURE[$id]:-}"
  [ -n "$f" ] || f="$(basename "$(dirname "$id")")"
  printf '%s' "$f"
}

# Action header: `// run`, `// errorcheck`, `// build` on one of the first
# lines. The README has always claimed these are parsed. Until now they were
# not, so an errorcheck fixture was graded BACKWARDS — it passed by silently
# accepting invalid code.
action_of() {
  local file="$1" a
  a="$(sed -n '1,10p' "$file" | grep -m1 -oE '^// *(run|errorcheck|build)' | awk '{print $2}')"
  [ -n "$a" ] || a=run
  printf '%s' "$a"
}

record() { # record <state> <id> <feature>
  local state="$1" id="$2" feat="$3"
  if [ -z "${FEAT_PASS[$feat]+x}" ]; then
    FEATURE_ORDER+=("$feat"); FEAT_PASS[$feat]=0; FEAT_FAIL[$feat]=0; FEAT_PLAN[$feat]=0
  fi
  case "$state" in
    pass)    PASSED=$((PASSED+1));  FEAT_PASS[$feat]=$(( ${FEAT_PASS[$feat]} + 1 )) ;;
    fail)    FAILED=$((FAILED+1));  FEAT_FAIL[$feat]=$(( ${FEAT_FAIL[$feat]} + 1 )); FAIL_NAMES+=("$id") ;;
    planned) PLANNED=$((PLANNED+1));FEAT_PLAN[$feat]=$(( ${FEAT_PLAN[$feat]} + 1 )) ;;
  esac
}

# Verify `// ERROR "regex"` annotations against captured stderr.
check_error_annotations() { # <file> <stderr-file>
  local file="$1" errf="$2" pat missing=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    grep -qE -- "$pat" "$errf" || { echo "      missing diagnostic matching: $pat"; missing=1; }
  done < <(grep -oE '// *ERROR +"[^"]*"' "$file" | sed -E 's|// *ERROR +"(.*)"|\1|')
  return $missing
}

run_fixture() { # <file> <label> <extra bashy args...>
  local file="$1"; shift
  local label="$1"; shift
  local id feat st action rc out err
  id="$(rel_id "$file")"; feat="$(feature_of "$id")"
  st="$(status_of "$id")"; action="$(action_of "$file")"
  TOTAL=$((TOTAL+1))
  printf '[%s] %-52s ' "$label" "$id"

  out="$(mktemp)"; err="$(mktemp)"
  rc=0
  "${BASHY_BIN}" "$@" "$file" >"$out" 2>"$err" || rc=$?

  local ok=0
  case "$action" in
    run|build)   [ "$rc" -eq 0 ] && ok=1 ;;
    errorcheck)  # must FAIL, and every // ERROR pattern must appear
                 if [ "$rc" -ne 0 ] && check_error_annotations "$file" "$err" >/dev/null; then ok=1; fi ;;
  esac

  if [ "$ok" -eq 1 ]; then
    echo "PASS"; record pass "$id" "$feat"
  elif [ "$st" = planned ]; then
    echo "PLANNED (not built yet)"; record planned "$id" "$feat"
  else
    echo "FAIL (${action}, exit ${rc})"
    [ "$action" = errorcheck ] && check_error_annotations "$file" "$err" || true
    sed -n '1,3p' "$err" | sed 's/^/      /'
    record fail "$id" "$feat"
  fi
  rm -f "$out" "$err"
}

# ---------------------------------------------------------------------------
# Collect first, then iterate. The previous runner piped `find` into `while`,
# so every counter was incremented inside a SUBSHELL and none survived — the
# summary always printed 0/0 while looking like it had measured something.
# ---------------------------------------------------------------------------
declare -a POSIX_FILES=() BPP_FILES=()
if [ -d "${TEST_DIR}/tests/00_superset_posix2016" ]; then
while IFS= read -r f; do POSIX_FILES+=("$f"); done \
    < <(find "${TEST_DIR}/tests/00_superset_posix2016" \( -name '*.sh' -o -name '*.bpp' \) | sort)
fi
# Bash# has expected negative and inert-mode cases; its dedicated executable
# gate above owns those outcomes, so the generic supported-fixture loop must
# not double-grade them as ordinary run fixtures.
while IFS= read -r f; do BPP_FILES+=("$f"); done \
  < <(find "${TEST_DIR}/tests" -name '*.bpp' ! -path '*/00_superset_posix2016/*' ! -path '*/_oracles/*' ! -path '*/bashsharp/*' | sort)

for f in ${POSIX_FILES+"${POSIX_FILES[@]}"}; do run_fixture "$f" "POSIX-2016 superset" --posix --bashpp; done
for f in ${BPP_FILES+"${BPP_FILES[@]}"};   do run_fixture "$f" "bash++ interpreted"   --bashpp; done

# ---------------------------------------------------------------------------
# CERTIFICATION SAFETY GATE — every invocation, authoritative.
#
# The certification profile invokes the shell with --posix and NO Bash++
# selector, and extended grammar must be inert there. Proven per shape rather
# than assumed, and wired here rather than left as a command someone remembers.
# ---------------------------------------------------------------------------
POSIX_GATE_RC=0
if [ -x "${TEST_DIR}/tools/startsites/classify.sh" ]; then
  echo
  echo "--------------------------------------------------------------------------"
  echo " Certification-safety gate: is bash++ inert under --posix?"
  echo "--------------------------------------------------------------------------"
  BASHY="${BASHY_BIN}" "${TEST_DIR}/tools/startsites/classify.sh" --posix-gate || POSIX_GATE_RC=$?
else
  echo "WARNING: tools/startsites/classify.sh missing — cert-safety gate NOT run" >&2
  POSIX_GATE_RC=1
fi

# The Go Day-1 table copies its classes from the corpus, so it can go stale
# without either suite turning red. Advisory here rather than fatal: it needs a
# sibling sh checkout, and a missing sibling is a layout fact, not a defect.
# Its own exit code is non-zero on a real disagreement, so CI can gate on it
# directly when sh is guaranteed present.
if [ -x "${TEST_DIR}/tools/startsites/verify-day1-table.sh" ] \
   && [ -f "${SH_DIR:-${TEST_DIR}/../sh}/syntax/bashpp_startsites_test.go" ]; then
  echo
  echo "--------------------------------------------------------------------------"
  echo " Day-1 table: does sh/syntax agree with the measured corpus?"
  echo "--------------------------------------------------------------------------"
  if ! "${TEST_DIR}/tools/startsites/verify-day1-table.sh"; then
    echo "ADVISORY: the Go Day-1 table disagrees with the corpus (see above)." >&2
    echo "          Not fatal here because this check needs a sibling sh checkout," >&2
    echo "          but it IS fatal when run directly, which is how CI should gate it." >&2
  fi
fi

echo
echo "--------------------------------------------------------------------------"
echo " Per-feature breakdown"
echo "--------------------------------------------------------------------------"
printf ' %-26s %6s %6s %8s\n' FEATURE PASS FAIL PLANNED
for feat in $(printf '%s\n' ${FEATURE_ORDER+"${FEATURE_ORDER[@]}"} | sort -u); do
  printf ' %-26s %6d %6d %8d\n' "$feat" "${FEAT_PASS[$feat]}" "${FEAT_FAIL[$feat]}" "${FEAT_PLAN[$feat]}"
done

echo "--------------------------------------------------------------------------"
echo " Total ${TOTAL}   passed ${PASSED}   failed ${FAILED}   planned ${PLANNED}"
echo "--------------------------------------------------------------------------"

# A zero denominator is not a pass. It means the corpus did not load, and a run
# that measured nothing must never be reportable as a green run.
if [ "${TOTAL}" -eq 0 ]; then
  echo "FATAL: 0 fixtures executed — the corpus did not load." >&2
  exit 2
fi

if [ "${FAILED}" -gt 0 ]; then
  echo "FAILED fixtures:" >&2
  printf '  %s\n' "${FAIL_NAMES[@]}" >&2
fi

[ "${FAILED}" -eq 0 ] && [ "${POSIX_GATE_RC}" -eq 0 ] && exit 0
[ "${POSIX_GATE_RC}" -ne 0 ] && echo "FAIL: certification-safety gate did not pass." >&2
exit 1
