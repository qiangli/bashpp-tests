#!/usr/bin/env bash
# Sprint: #157; Story: S157.1; Story-ID: b7560ec00ec1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$ROOT/docs/upstream-harness/pin.tsv"
MATRIX="$ROOT/docs/upstream-harness/matrix.tsv"
FROZEN="$ROOT/tools/upstream-harness/testdata/upstream/testdir_test.go"
PATCH="$ROOT/tools/upstream-harness/testdata/instrumented/testdir_test.go.patch"
HOOK_SOURCE="$ROOT/tools/upstream-harness/testdata/instrumented/bashpp_events_test.go"

die() { echo "FATAL: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null || die "required command is missing: $1"; }
pin() { awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$PIN"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

need awk
need jq
need patch
need shasum

release="$(pin release)"
base_sha="$(pin upstream_sha256)"
patch_sha="$(pin patch_sha256)"
hook_sha="$(pin hook_sha256)"
schema="$(pin event_schema)"
[ "$release" = go1.27.0 ] || die "pin release is not go1.27.0"
[ "$(sha "$FROZEN")" = "$base_sha" ] || die "frozen upstream runner digest mismatch"
[ "$(sha "$PATCH")" = "$patch_sha" ] || die "instrumentation patch digest mismatch"
[ "$(sha "$HOOK_SOURCE")" = "$hook_sha" ] || die "event hook digest mismatch"

GOTOOL="${GO127_TOOL:-$($ROOT/tools/go-oracle/gotool.sh)}"
SDK="$($GOTOOL env GOROOT)"
[ "$(sha "$SDK/src/cmd/internal/testdir/testdir_test.go")" = "$base_sha" ] || \
  die "candidate Go tool does not carry the frozen upstream runner"

if [ -n "${GO_CORPUS_ROOT:-}" ]; then
  CORPUS="$GO_CORPUS_ROOT"
elif [ -d "$ROOT/.cache/go-corpus/$release/test" ]; then
  CORPUS="$ROOT/.cache/go-corpus/$release"
else
  HOST_GO="$(command -v go)"
  CORPUS="$($HOST_GO env GOROOT)"
fi
[ -d "$CORPUS/test" ] || die "no corpus test directory at $CORPUS/test"

# Authenticate every matrix byte before the harness can read it. A local older
# distribution is acceptable only when each selected file is byte-identical to
# the reviewed Go 1.27 inventory row recorded here.
while IFS=$'\t' read -r capability test action want companions; do
  case "$capability" in ''|'#'*) continue ;; esac
  file="$CORPUS/test/$test"
  [ -f "$file" ] || die "$capability: missing $test"
  [ "$(sha "$file")" = "$want" ] || die "$capability: $test is not the pinned Go 1.27 byte sequence"
  if [ "$companions" != - ]; then
    IFS=',' read -ra selected <<<"$companions"
    for item in "${selected[@]}"; do
      name="${item%%=*}"
      digest="${item#*=}"
      [ -f "$CORPUS/test/$name" ] || die "$capability: missing selected companion $name"
      [ "$(sha "$CORPUS/test/$name")" = "$digest" ] || die "$capability: companion $name digest mismatch"
    done
  fi
done < "$MATRIX"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/s157.1-gate.XXXXXX")"
cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT
cp -R "$SDK" "$WORK/goroot"
chmod u+w "$WORK/goroot"
ln -s "$CORPUS/test" "$WORK/goroot/test"
mkdir "$WORK/gocache"

cp "$FROZEN" "$WORK/testdir_test.go"
patch --silent "$WORK/testdir_test.go" < "$PATCH"

BASE="$WORK/goroot/src/cmd/internal/testdir/testdir_test.go"
HOOK="$WORK/goroot/src/cmd/internal/testdir/bashpp_events_test.go"
jq -n --arg base "$BASE" --arg patched "$WORK/testdir_test.go" \
  --arg hook "$HOOK" --arg hook_source "$HOOK_SOURCE" \
  '{Replace:{($base):$patched,($hook):$hook_source}}' > "$WORK/overlay.json"

cd "$WORK/goroot/src/cmd/internal/testdir"
rows=0
while IFS=$'\t' read -r capability test action want companions; do
  case "$capability" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  run_re="^Test/$test$"
  native="$WORK/native-$rows.json"
  observed="$WORK/observed-$rows.json"
  event_file="$WORK/events-$rows.jsonl"

  GOROOT="$WORK/goroot" GOCACHE="$WORK/gocache" "$GOTOOL" test \
    -run "$run_re" -count=1 -json > "$native"
  GOROOT="$WORK/goroot" GOCACHE="$WORK/gocache" BASHPP_TESTDIR_EVENTS="$event_file" \
    "$GOTOOL" test -overlay "$WORK/overlay.json" -run "$run_re" -count=1 -json > "$observed"

  subtest="Test/$test"
  native_terminal="$(jq -r --arg t "$subtest" 'select(.Test == $t and (.Action == "pass" or .Action == "fail" or .Action == "skip")) | .Action' "$native" | tail -1)"
  observed_terminal="$(jq -r --arg t "$subtest" 'select(.Test == $t and (.Action == "pass" or .Action == "fail" or .Action == "skip")) | .Action' "$observed" | tail -1)"
  [ -n "$native_terminal" ] || die "$test: unmodified runner emitted no terminal"
  [ "$native_terminal" = "$observed_terminal" ] || \
    die "$test: unmodified=$native_terminal instrumented=$observed_terminal"

  jq -s -e --arg schema "$schema" --arg test "$test" --arg action "$action" '
    length > 0 and
    all(.[]; .schema == $schema and .test == $test and .subtest == ("Test/" + $test)) and
    ([.[].order] == [range(0; length)]) and
    any(.[]; .kind == "selection" and .action == $action) and
    any(.[]; .kind == "terminal")
  ' "$event_file" >/dev/null || die "$test: malformed or incomplete event stream"

  case "$capability" in
    ordered-mixed-output)
      jq -s -e 'any(.[]; .kind == "phase_result" and .output_bytes == 5) and any(.[]; .kind == "comparison" and .matched == true)' "$event_file" >/dev/null || die "$test: mixed output was not observed as A\\n\\nB\\n"
      ;;
    compile-inputs-vs-program-argv)
      jq -s -e 'any(.[]; .kind == "phase" and .compile_inputs == ["cmplxdivide.go", "cmplxdivide1.go"] and .program_argv == []) and any(.[]; .kind == "companions" and .paths == ["cmplxdivide1.go"])' "$event_file" >/dev/null || die "$test: compile source/recipe companion/program argv were conflated"
      ;;
    expected-compile-error)
      jq -s -e 'any(.[]; .kind == "expected_diagnostics" and (.diagnostics | length) > 0) and any(.[]; .kind == "comparison" and .comparison_mode == "diagnostic-regexp" and .matched == true)' "$event_file" >/dev/null || die "$test: expected diagnostics or comparison missing"
      ;;
    directory-package-planning)
      jq -s -e '([.[] | select(.kind == "companions") | .paths[]] | length) > 1' "$event_file" >/dev/null || die "$test: upstream package selection missing"
      ;;
    generated-output)
      jq -s -e 'any(.[]; .kind == "generated") and any(.[]; .kind == "phase" and .phase_kind == "generate") and any(.[]; .kind == "comparison")' "$event_file" >/dev/null || die "$test: generated/output phases missing"
      ;;
    assembler-planning)
      jq -s -e 'any(.[]; .kind == "bypass" and .phase_kind == "asmcheck")' "$event_file" >/dev/null || die "$test: asmcheck target bypass missing"
      ;;
    upstream-skip|build-constraint-exclusion)
      jq -s -e 'any(.[]; .kind == "selection" and .applicable == false and (.skip_reason | length) > 0) and any(.[]; .kind == "terminal" and .skipped == true)' "$event_file" >/dev/null || die "$test: skip decision missing"
      ;;
  esac
  printf 'PASS %-34s %s (%s)\n' "$capability" "$test" "$native_terminal"
done < "$MATRIX"

[ "$rows" -eq 9 ] || die "matrix row count is $rows, want 9"
echo "PASS authenticated Go 1.27 upstream harness overlay: $rows/$rows native verdicts identical"
