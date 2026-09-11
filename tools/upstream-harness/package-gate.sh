#!/usr/bin/env bash
# Sprint: #150; Story: S150.8; Story-ID: 65db485f62ab
#
# Authenticated 150.8 package packet gate. Go's own package-test runner
# (cmd/go: load.TestPackagesFor enumerates the original test bodies into
# _testmain.go, builds the test binary, runs it) is the only authority. This
# gate freezes the exact Go 1.27.0 cmd/go/internal/test/test.go, applies the
# one localized patch at the site where the built test binary would be
# executed, builds that patched go command through -overlay, proves it
# native-equivalent with the backend off, and then replays the 26
# authenticated packages through the Bash++ backend in both modes: the tested
# package with its test files, the external test package, and the generated
# _testmain.go, as an explicit package map. The native test binary is never
# run in a backend lane. Retained Bash++ product failures keep the gate
# honestly non-green (exit 3); a seam defect fails hard (exit 1).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
harness="$root/tools/upstream-harness"
matrix="$root/docs/upstream-harness/package-matrix.tsv"
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
	test -n "$want" && test "$got" = "$want" || { printf 'FAIL pin %s: expected %s, got %s\n' "$1" "${want:-missing}" "$got" >&2; exit 1; }
}

check_pin gotest_upstream "$harness/testdata/upstream-go/test.go"
check_pin gotest_patch "$harness/testdata/go-backend/test.go.patch"
check_pin gotest_hook "$harness/testdata/go-backend/bashpp_backend.go"
check_pin package_verifier "$harness/package-verify.go"
check_pin package_matrix "$matrix"

tab=$(printf '\t')
rootlist=$(awk -F '\t' '$1 !~ /^#/ && NF == 5 { printf "package:%s\n", $2 }' "$matrix")
root_count=$(printf '%s\n' "$rootlist" | wc -l | tr -d ' ')
test "$root_count" = 26 || { printf 'FAIL packet root count is %s, want 26\n' "$root_count" >&2; exit 1; }
rootlist_sha=$(printf '%s\n' "$rootlist" | sha256_stdin)
test "$rootlist_sha" = "$(pin_value package_rootlist)" || { printf 'FAIL packet root list digest: expected %s, got %s\n' "$(pin_value package_rootlist)" "$rootlist_sha" >&2; exit 1; }

go_tool=${GO127_TOOL:-go}
if test -z "${GO127_TOOL:-}"; then export GOTOOLCHAIN=go1.27.0; fi
go_version=$($go_tool version)
case "$go_version" in
	'go version go1.27.0 '*) ;;
	*) printf 'FAIL Go pin: %s\n' "$go_version" >&2; exit 1 ;;
esac
real_goroot=$($go_tool env GOROOT)
test "$(sha256 "$real_goroot/src/cmd/go/internal/test/test.go")" = "$(pin_value gotest_upstream)" || { printf 'FAIL GOROOT cmd/go test runner differs from the frozen upstream\n' >&2; exit 1; }

# Every tested package is the exact Go 1.27.0 source: digest of the sorted
# "<sha256> <file>" lines over its *.go files, test files included.
pkg_digest() { for f in "$real_goroot/src/$1"/*.go; do printf '%s %s\n' "$(sha256 "$f")" "${f##*/}"; done | sort -k2 | sha256_stdin; }
while IFS="$tab" read -r capability pkg action want companions; do
	case "$capability" in ''|'#'*) continue ;; esac
	test "$(pkg_digest "$pkg")" = "$want" || { printf 'FAIL package pin %s\n' "$pkg" >&2; exit 1; }
done < "$matrix"

bashpp_tool=${BASHPP_TOOL:-}
if test -z "$bashpp_tool"; then bashpp_tool=$(command -v bashy || true); fi
test -x "$bashpp_tool" || { printf 'FAIL pinned Bash++ tool is unavailable: %s\n' "$bashpp_tool" >&2; exit 1; }
bashpp_version=$($bashpp_tool --version)
test "$bashpp_version" = "$(pin_value bashpp_version)" || { printf 'FAIL Bash++ pin: expected %s, got %s\n' "$(pin_value bashpp_version)" "$bashpp_version" >&2; exit 1; }
inherited_shellopts=$(env | sed -n 's/^SHELLOPTS=//p')
case ":$inherited_shellopts:" in
	*:posix:*) printf 'FAIL SHELLOPTS selects POSIX mode; run this gate from a non-POSIX environment\n' >&2; exit 1 ;;
esac
inherited_posix=$(env | sed -n '/^POSIXLY_CORRECT=/p; /^POSIX_PEDANTIC=/p')
test -z "$inherited_posix" || { printf 'FAIL inherited POSIX selector blocks the Bash++ direct Go-source interface\n' >&2; exit 1; }
shellrt=${BASHPP_SHELLRT_ROOT:-}
test -n "$shellrt" && test -f "$shellrt/go.mod" || { printf 'FAIL BASHPP_SHELLRT_ROOT must name the caller-supplied mvdan.cc/sh/v3 source tree\n' >&2; exit 1; }
shellrt_commit=$(git -C "$shellrt" rev-parse HEAD 2>/dev/null || true)
test "$shellrt_commit" = "$(pin_value shellrt_commit)" || { printf 'FAIL Bash++ runtime source commit: expected %s, got %s\n' "$(pin_value shellrt_commit)" "${shellrt_commit:-missing}" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bashpp-s1508.XXXXXX")
cleanup() {
	if test "${BASHPP_KEEP_EVIDENCE:-0}" = 1; then printf 'evidence retained: %s\n' "$tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/patched/src/cmd/go/internal/test" "$tmp/gocache" "$tmp/goroot"
# Overlays may not replace files beneath GOMODCACHE; mirror the SDK by symlink.
for entry in "$real_goroot"/*; do ln -s "$entry" "$tmp/goroot/${entry##*/}"; done
go127="$tmp/goroot/bin/go"
cp "$harness/testdata/upstream-go/test.go" "$tmp/patched/src/cmd/go/internal/test/test.go"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/go-backend/test.go.patch"
printf '{"Replace":{"%s/src/cmd/go/internal/test/test.go":"%s/patched/src/cmd/go/internal/test/test.go","%s/src/cmd/go/internal/test/bashpp_backend.go":"%s/testdata/go-backend/bashpp_backend.go"}}\n' \
	"$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" > "$tmp/overlay.json"

# The patched go command IS the runner; it is built once through -overlay.
GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$go127" build -overlay="$tmp/overlay.json" -o "$tmp/go-bashpp" cmd/go
GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$go127" build -o "$tmp/package-verify" "$harness/package-verify.go"

terminal() { awk -v pkg="$2" 'BEGIN{FS="\""} /"Action":"(pass|fail|skip)"/ && !/"Test":/ { for (i = 1; i <= NF; i++) if ($i == "Action") print $(i+2) }' "$1"; }

# Native-equivalence canary: the smallest packet package, native go vs the
# patched go with the backend off, must reach the same package terminal.
canary=internal/types/errors
mkdir -p "$tmp/evidence-native"
(cd "$tmp/goroot/src" && GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$go127" test -count=1 -json "$canary" > "$tmp/evidence-native/canary-go.json" 2>/dev/null || true)
(cd "$tmp/goroot/src" && GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$tmp/go-bashpp" test -count=1 -json "$canary" > "$tmp/evidence-native/canary-patched.json" 2>/dev/null || true)
native_terminal=$(terminal "$tmp/evidence-native/canary-go.json" "$canary")
patched_terminal=$(terminal "$tmp/evidence-native/canary-patched.json" "$canary")
test -n "$native_terminal" && test "$native_terminal" = "$patched_terminal" || { printf 'FAIL patched go is not native-equivalent with the backend off: native=%s patched=%s\n' "$native_terminal" "$patched_terminal" >&2; exit 1; }
printf 'PASS patched cmd/go native-equivalent with the backend off (%s: %s)\n' "$canary" "$native_terminal"

run_mode() {
	mode=$1
	dir="$tmp/evidence-$mode"
	mkdir -p "$dir"
	while IFS="$tab" read -r capability pkg action want companions; do
		case "$capability" in ''|'#'*) continue ;; esac
		case_id=$(printf '%s' "$pkg" | tr '/.' '__')
		(cd "$tmp/goroot/src" && \
		BASHPP_GOTEST_BACKEND="$mode" BASHPP_GOTEST_TOOL="$bashpp_tool" BASHPP_GOTEST_VERSION="$bashpp_version" \
		BASHPP_GOTEST_GO="$go127" BASHPP_SHELLRT_ROOT="$shellrt" BASHPP_GOTEST_EVENTS="$dir/$case_id.events.jsonl" \
		BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
		GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
		"$tmp/go-bashpp" test -count=1 -json "$pkg" > "$dir/$case_id.go-test.json" 2> "$dir/$case_id.stderr" || true)
	done < "$matrix"
	"$tmp/package-verify" -matrix "$matrix" -evidence "$dir" -mode "$mode" -version "$bashpp_version" -tool "$bashpp_tool"
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
if test "$seam_fail" -ne 0; then printf 'FAIL S150.8 package packet: backend-seam defect\n' >&2; exit 1; fi
if test "$product_fail" -ne 0; then
	printf 'NON-GREEN S150.8 package packet: every package enumerated its original test bodies through cmd/go and handed them to Bash++; honest Bash++ product failures are retained for the product-fix sprints\n'
	exit 3
fi
printf 'PASS S150.8 package packet: 26 authenticated packages executed their original test bodies through Bash++ in both modes\n'
