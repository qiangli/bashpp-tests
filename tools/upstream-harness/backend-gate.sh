#!/bin/sh
# Sprint: #157; Story: S157.2; Story-ID: 31520c72b5e0
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
harness="$root/tools/upstream-harness"
matrix="$root/docs/upstream-harness/matrix.tsv"
pin="$harness/backend-pin.tsv"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
pin_value() { awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$pin"; }
check_pin() {
	want=$(pin_value "$1")
	got=$(sha256 "$2")
	test -n "$want" && test "$got" = "$want" || {
		printf 'FAIL pin %s: expected %s, got %s\n' "$1" "${want:-missing}" "$got" >&2
		exit 1
	}
}

# S157.1 is the authority for the unchanged native observer.
"$harness/gate.sh"

check_pin upstream "$harness/testdata/upstream/testdir_test.go"
check_pin instrumentation_patch "$harness/testdata/instrumented/testdir_test.go.patch"
check_pin instrumentation_hook "$harness/testdata/instrumented/bashpp_events_test.go"
check_pin backend_patch "$harness/testdata/backend/testdir_test.go.patch"
check_pin backend_events_patch "$harness/testdata/backend/events_test.go.patch"
check_pin backend_hook "$harness/testdata/backend/bashpp_backend_test.go"
check_pin verifier "$harness/backend-verify.go"
check_pin verifier_test "$harness/backend-verify_test.go"
check_pin observer "$harness/observer.go"
check_pin matrix "$matrix"

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

# These inherited selectors deliberately put Bash++ in its POSIX profile, where
# direct Go-source input is unavailable. Require the caller to provide the same
# non-POSIX startup environment that is then preserved at the upstream seam.
inherited_shellopts=$(env | sed -n 's/^SHELLOPTS=//p')
case ":$inherited_shellopts:" in
	*:posix:*) printf 'FAIL SHELLOPTS selects POSIX mode; run this backend gate from a non-POSIX environment\n' >&2; exit 1 ;;
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

tab=$(printf '\t')
while IFS="$tab" read -r capability test action want companions; do
	case "$capability" in ''|'#'*) continue ;; esac
	test "$(sha256 "$test_root/$test")" = "$want" || { printf 'FAIL corpus pin %s\n' "$test" >&2; exit 1; }
	if test "$companions" != '-'; then
		rest=$companions
		while test -n "$rest"; do
			item=${rest%%,*}
			if test "$rest" = "$item"; then rest=; else rest=${rest#*,}; fi
			name=${item%%=*}
			want_companion=${item#*=}
			test "$(sha256 "$test_root/$name")" = "$want_companion" || { printf 'FAIL companion pin %s\n' "$name" >&2; exit 1; }
		done
	fi
done < "$matrix"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bashpp-s1572.XXXXXX")
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

run_mode() {
	mode=$1
	dir="$tmp/evidence-$mode"
	mkdir "$dir"
	while IFS="$tab" read -r capability test action want companions; do
		case "$capability" in ''|'#'*) continue ;; esac
		case_id=$(printf '%s' "$test" | tr '/.' '__')
		file=${test##*/}
		file_re=$(printf '%s' "$file" | sed 's/\./\\./g')
		if test "$file" = "$test"; then
			selector="^Test$/^$file_re$"
		else
			directory=${test%/*}
			directory_re=$(printf '%s' "$directory" | sed 's/\./\\./g')
			selector="^Test$/^$directory_re$/^$file_re$"
		fi
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
	GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
		"$tmp/goroot/bin/go" run "$harness/backend-verify.go" \
		-matrix "$matrix" -evidence "$dir" -mode "$mode" -version "$bashpp_version" -tool "$bashpp_tool"
	GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
		"$tmp/goroot/bin/go" run "$harness/observer.go" \
		-pins "$pin" -evidence "$dir" -mode "$mode" -version "$bashpp_version" -tool "$bashpp_tool" \
		-out "$dir/observer.json"
}

printf 'Bash++ interpreted mode: %s\n' "$bashpp_version"
result=0
if ! run_mode interpreted; then result=1; fi
printf 'Bash++ compiled mode: %s\n' "$bashpp_version"
if ! run_mode compiled; then result=1; fi
test "$result" -eq 0 || exit "$result"
printf 'PASS S157.2 direct-source backend reports the two run gates and minimally classifies every other authenticated row\n'
