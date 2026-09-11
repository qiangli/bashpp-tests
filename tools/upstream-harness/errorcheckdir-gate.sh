#!/usr/bin/env bash
# Sprint: #149; Story: S149.5; Story-ID: 2b9f89926646
#
# Authenticated 149.5 `errorcheckdir` packet gate. The upstream Go 1.27 testdir runner
# owns recipe selection, flags, runenv (including GOEXPERIMENT), and terminal
# verdicts; this gate only authenticates inputs, replays the 26 packet roots
# through the S157 backend seam in both modes, and verifies the recorded
# evidence. Retained Bash++ product failures keep the gate honestly non-green
# (exit 3); a backend-seam defect fails hard (exit 1).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
harness="$root/tools/upstream-harness"
matrix="$root/docs/upstream-harness/errorcheckdir-matrix.tsv"
pin="$harness/backend-pin.tsv"

if command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$1" | awk '{print $1}'; }
	sha256_stdin() { sha256sum | awk '{print $1}'; }
else
	sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
	sha256_stdin() { shasum -a 256 | awk '{print $1}'; }
fi
pin_value() { awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$pin"; }
check_pin() {
	want=$(pin_value "$1")
	got=$(sha256 "$2")
	test -n "$want" && test "$got" = "$want" || {
		printf 'FAIL pin %s: expected %s, got %s\n' "$1" "${want:-missing}" "$got" >&2
		exit 1
	}
}

check_pin upstream "$harness/testdata/upstream/testdir_test.go"
check_pin instrumentation_patch "$harness/testdata/instrumented/testdir_test.go.patch"
check_pin instrumentation_hook "$harness/testdata/instrumented/bashpp_events_test.go"
check_pin backend_patch "$harness/testdata/backend/testdir_test.go.patch"
check_pin backend_events_patch "$harness/testdata/backend/events_test.go.patch"
check_pin backend_hook "$harness/testdata/backend/bashpp_backend_test.go"
check_pin verifier "$harness/backend-verify.go"
check_pin verifier_test "$harness/backend-verify_test.go"
check_pin errorcheckdir_matrix "$matrix"

# Authenticate the exact packet-149.5 root selection: 26 roots whose
# `testdir:<root>` list reproduces the published manifest root-list digest.
tab=$(printf '\t')
rootlist=$(awk -F '\t' '$1 !~ /^#/ && NF == 5 { printf "testdir:%s\n", $2 }' "$matrix")
root_count=$(printf '%s\n' "$rootlist" | wc -l | tr -d ' ')
test "$root_count" = 26 || { printf 'FAIL packet root count is %s, want 26\n' "$root_count" >&2; exit 1; }
rootlist_sha=$(printf '%s\n' "$rootlist" | sha256_stdin)
test "$rootlist_sha" = "$(pin_value errorcheckdir_rootlist)" || {
	printf 'FAIL packet root list digest: expected %s, got %s\n' "$(pin_value errorcheckdir_rootlist)" "$rootlist_sha" >&2
	exit 1
}

go_tool=${GO127_TOOL:-go}
if test -z "${GO127_TOOL:-}"; then export GOTOOLCHAIN=go1.27.0; fi
go_version=$($go_tool version)
case "$go_version" in
	'go version go1.27.0 '*) ;;
	*) printf 'FAIL Go pin: %s\n' "$go_version" >&2; exit 1 ;;
esac
real_goroot=$($go_tool env GOROOT)

GOROOT="$real_goroot" GOTOOLCHAIN=local "$go_tool" test "$harness/backend-verify.go" "$harness/backend-verify_test.go"

bashpp_tool=${BASHPP_TOOL:-}
if test -z "$bashpp_tool"; then bashpp_tool=$(command -v bashy || true); fi
test -x "$bashpp_tool" || { printf 'FAIL pinned Bash++ tool is unavailable: %s\n' "$bashpp_tool" >&2; exit 1; }
bashpp_version=$($bashpp_tool --version)
expected_bashpp_version=$(pin_value bashpp_version)
test "$bashpp_version" = "$expected_bashpp_version" || {
	printf 'FAIL Bash++ pin: expected %s, got %s\n' "$expected_bashpp_version" "$bashpp_version" >&2
	exit 1
}

# The direct Go-source interface refuses Bash++'s POSIX profile; require the
# same non-POSIX startup environment the S157 backend gate documents.
inherited_shellopts=$(env | sed -n 's/^SHELLOPTS=//p')
case ":$inherited_shellopts:" in
	*:posix:*) printf 'FAIL SHELLOPTS selects POSIX mode; run this gate from a non-POSIX environment\n' >&2; exit 1 ;;
esac
inherited_posix=$(env | sed -n '/^POSIXLY_CORRECT=/p; /^POSIX_PEDANTIC=/p')
test -z "$inherited_posix" || {
	printf 'FAIL inherited POSIX selector blocks the Bash++ direct Go-source interface\n' >&2
	exit 1
}

shellrt=${BASHPP_SHELLRT_ROOT:-}
test -n "$shellrt" && test -f "$shellrt/go.mod" || {
	printf 'FAIL BASHPP_SHELLRT_ROOT must name the caller-supplied mvdan.cc/sh/v3 source tree\n' >&2
	exit 1
}
grep -Eq '^module[[:space:]]+mvdan\.cc/sh/v3$' "$shellrt/go.mod" || {
	printf 'FAIL BASHPP_SHELLRT_ROOT is not an mvdan.cc/sh/v3 module\n' >&2
	exit 1
}
shellrt_commit=$(git -C "$shellrt" rev-parse HEAD 2>/dev/null || true)
test "$shellrt_commit" = "$(pin_value shellrt_commit)" || {
	printf 'FAIL Bash++ runtime source commit: expected %s, got %s\n' "$(pin_value shellrt_commit)" "${shellrt_commit:-missing}" >&2
	exit 1
}
test -z "$(git -C "$shellrt" status --porcelain)" || {
	printf 'FAIL Bash++ runtime source tree is not clean\n' >&2
	exit 1
}

if test -n "${GO_CORPUS_ROOT:-}"; then
	if test -d "$GO_CORPUS_ROOT/test"; then test_root="$GO_CORPUS_ROOT/test"; else test_root="$GO_CORPUS_ROOT"; fi
elif test -d "$real_goroot/test"; then
	test_root="$real_goroot/test"
else
	local_goroot=$(GOTOOLCHAIN=local go env GOROOT)
	test_root="$local_goroot/test"
fi

while IFS="$tab" read -r capability test action want companions; do
	case "$capability" in ''|'#'*) continue ;; esac
	test "$(sha256 "$test_root/$test")" = "$want" || { printf 'FAIL corpus pin %s\n' "$test" >&2; exit 1; }
	test "$companions" = "-" && continue
	printf '%s\n' "$companions" | tr ',' '\n' | while IFS='=' read -r cpath csha; do
		test "$(sha256 "$test_root/$cpath")" = "$csha" || { printf 'FAIL companion pin %s\n' "$cpath" >&2; exit 1; }
	done || exit 1
done < "$matrix"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bashpp-s1495.XXXXXX")
cleanup() {
	if test "${BASHPP_KEEP_EVIDENCE:-0}" = 1; then
		printf 'evidence retained: %s\n' "$tmp"
	else
		rm -rf "$tmp"
	fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/patched/src/cmd/internal/testdir" "$tmp/goroot" "$tmp/gocache"
cp "$harness/testdata/upstream/testdir_test.go" "$tmp/patched/src/cmd/internal/testdir/testdir_test.go"
cp "$harness/testdata/instrumented/bashpp_events_test.go" "$tmp/patched/src/cmd/internal/testdir/bashpp_events_test.go"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/instrumented/testdir_test.go.patch"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/backend/testdir_test.go.patch"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/backend/events_test.go.patch"

for entry in "$real_goroot"/*; do
	name=${entry##*/}
	if test "$name" != test; then ln -s "$entry" "$tmp/goroot/$name"; fi
done
ln -s "$test_root" "$tmp/goroot/test"

printf '{"Replace":{"%s/src/cmd/internal/testdir/testdir_test.go":"%s/patched/src/cmd/internal/testdir/testdir_test.go","%s/src/cmd/internal/testdir/bashpp_events_test.go":"%s/patched/src/cmd/internal/testdir/bashpp_events_test.go","%s/src/cmd/internal/testdir/bashpp_backend_test.go":"%s/testdata/backend/bashpp_backend_test.go"}}\n' \
	"$tmp/goroot" "$tmp" "$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" > "$tmp/overlay.json"

# `go run` collapses every nonzero child exit to 1; build the verifier once so
# its non-green product-failure exit (3) stays distinguishable from a seam FAIL.
GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
	"$tmp/goroot/bin/go" build -o "$tmp/backend-verify" "$harness/backend-verify.go"

run_mode() {
	mode=$1
	dir="$tmp/evidence-$mode"
	mkdir "$dir"
	while IFS="$tab" read -r capability test action want companions; do
		case "$capability" in ''|'#'*) continue ;; esac
		case_id=$(printf '%s' "$test" | tr '/.' '__')
		file=${test##*/}
		file_re=$(printf '%s' "$file" | sed 's/\./\\./g')
		directory=${test%/*}
		directory_re=$(printf '%s' "$directory" | sed 's/\./\\./g')
		selector="^Test$/^$directory_re$/^$file_re$"
		BASHPP_TESTDIR_EVENTS="$dir/$case_id.events.jsonl" \
		BASHPP_TESTDIR_BACKEND="$mode" \
		BASHPP_TESTDIR_TOOL="$bashpp_tool" \
		BASHPP_TESTDIR_GO="$go_tool" \
		BASHPP_TESTDIR_VERSION="$bashpp_version" \
		BASHPP_SHELLRT_ROOT="$shellrt" \
		BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
		GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
		"$tmp/goroot/bin/go" test -count=1 -json -overlay="$tmp/overlay.json" cmd/internal/testdir -run="$selector" \
		>"$dir/$case_id.go-test.json" 2>"$dir/$case_id.stderr" || true
	done < "$matrix"
	"$tmp/backend-verify" \
		-matrix "$matrix" -evidence "$dir" -mode "$mode" -version "$bashpp_version" -tool "$bashpp_tool"
}

seam_fail=0
product_fail=0
for mode in interpreted compiled; do
	printf 'Bash++ %s mode: %s\n' "$mode" "$bashpp_version"
	status=0
	run_mode "$mode" || status=$?
	case "$status" in
		0) ;;
		3) product_fail=1 ;;
		*) seam_fail=1 ;;
	esac
done

if test "$seam_fail" -ne 0; then
	printf 'FAIL S149.5 errorcheckdir packet: backend-seam defect\n' >&2
	exit 1
fi
if test "$product_fail" -ne 0; then
	printf 'NON-GREEN S149.5 errorcheckdir packet: every root kept the upstream errorcheckdir contract; honest Bash++ product failures are retained for the product-fix sprints\n'
	exit 3
fi
printf 'PASS S149.5 errorcheckdir packet: 26 authenticated roots through the exact upstream errorcheckdir action\n'
