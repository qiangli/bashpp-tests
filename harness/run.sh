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

if [ ! -x "${BASHY_BIN}" ]; then
  echo "FATAL: ${BASHY_BIN} is not executable." >&2
  echo "Build it first (cd ../bashy && make build-bash), or set BASHY_BIN." >&2
  echo "This is fatal rather than a skip: a run that measured nothing must not" >&2
  echo "be reportable as a run." >&2
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
while IFS= read -r f; do BPP_FILES+=("$f"); done \
  < <(find "${TEST_DIR}/tests" -name '*.bpp' ! -path '*/00_superset_posix2016/*' ! -path '*/_oracles/*' | sort)

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
