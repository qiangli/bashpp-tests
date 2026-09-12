#!/usr/bin/env bash
# Sprint: #149; Story: S149.10; Story-ID: 8ae8f1041a8f
#
# Authenticated 149.10 typechecker packet gate. Go 1.27's own checker test
# harnesses (cmd/compile/internal/types2 and go/types check_test.go) own the
# fixture selection, the -lang / -fakeImportC / -goexperiment flags, build
# constraints, ERROR-comment collection and matching, and the terminal
# verdict. One localized patch per runner replaces the single conf.Check call
# with the Bash++ check interface on the same files. This gate authenticates
# every input, proves the patched runners are native-equivalent with the
# backend off (20/20), replays the 20 roots through Bash++, and verifies the
# recorded evidence. Product failures keep the gate honestly non-green (exit
# 3); a seam defect fails hard (exit 1).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
harness="$root/tools/upstream-harness"
matrix="$root/docs/upstream-harness/typechecker-matrix.tsv"
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

check_pin types2_upstream "$harness/testdata/upstream-types/types2/check_test.go"
check_pin gotypes_upstream "$harness/testdata/upstream-types/gotypes/check_test.go"
check_pin types2_patch "$harness/testdata/types-backend/types2/check_test.go.patch"
check_pin gotypes_patch "$harness/testdata/types-backend/gotypes/check_test.go.patch"
check_pin types2_hook "$harness/testdata/types-backend/types2/bashpp_types_check_test.go"
check_pin gotypes_hook "$harness/testdata/types-backend/gotypes/bashpp_types_check_test.go"
check_pin types_verifier "$harness/types-verify.go"
check_pin typechecker_matrix "$matrix"

tab=$(printf '\t')
rootlist=$(awk -F '\t' '$1 !~ /^#/ && NF == 5 { print $2 }' "$matrix")
root_count=$(printf '%s\n' "$rootlist" | wc -l | tr -d ' ')
test "$root_count" = 20 || { printf 'FAIL packet root count is %s, want 20\n' "$root_count" >&2; exit 1; }
rootlist_sha=$(printf '%s\n' "$rootlist" | sha256_stdin)
test "$rootlist_sha" = "$(pin_value typechecker_rootlist)" || {
	printf 'FAIL packet root list digest: expected %s, got %s\n' "$(pin_value typechecker_rootlist)" "$rootlist_sha" >&2
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

# The runner sources must be the exact upstream files of this Go 1.27 tree.
test "$(sha256 "$real_goroot/src/cmd/compile/internal/types2/check_test.go")" = "$(pin_value types2_upstream)" || { printf 'FAIL GOROOT types2 runner differs from the frozen upstream\n' >&2; exit 1; }
test "$(sha256 "$real_goroot/src/go/types/check_test.go")" = "$(pin_value gotypes_upstream)" || { printf 'FAIL GOROOT go/types runner differs from the frozen upstream\n' >&2; exit 1; }
while IFS="$tab" read -r capability test action want fixture; do
	case "$capability" in ''|'#'*) continue ;; esac
	test "$(sha256 "$real_goroot/$fixture")" = "$want" || { printf 'FAIL fixture pin %s\n' "$fixture" >&2; exit 1; }
done < "$matrix"

GOROOT="$real_goroot" GOTOOLCHAIN=local "$go_tool" vet "$harness/types-verify.go"

bashpp_tool=${BASHPP_TOOL:-}
if test -z "$bashpp_tool"; then bashpp_tool=$(command -v bashy || true); fi
test -x "$bashpp_tool" || { printf 'FAIL pinned Bash++ tool is unavailable: %s\n' "$bashpp_tool" >&2; exit 1; }
bashpp_version=$($bashpp_tool --version)
test "$bashpp_version" = "$(pin_value bashpp_version)" || {
	printf 'FAIL Bash++ pin: expected %s, got %s\n' "$(pin_value bashpp_version)" "$bashpp_version" >&2
	exit 1
}
inherited_shellopts=$(env | sed -n 's/^SHELLOPTS=//p')
case ":$inherited_shellopts:" in
	*:posix:*) printf 'FAIL SHELLOPTS selects POSIX mode; run this gate from a non-POSIX environment\n' >&2; exit 1 ;;
esac
inherited_posix=$(env | sed -n '/^POSIXLY_CORRECT=/p; /^POSIX_PEDANTIC=/p')
test -z "$inherited_posix" || { printf 'FAIL inherited POSIX selector blocks the Bash++ direct Go-source interface\n' >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bashpp-s14910.XXXXXX")
cleanup() {
	if test "${BASHPP_KEEP_EVIDENCE:-0}" = 1; then printf 'evidence retained: %s\n' "$tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/patched/src/cmd/compile/internal/types2" "$tmp/patched/src/go/types" "$tmp/gocache" "$tmp/goroot"
# Overlays may not replace files beneath GOMODCACHE, so mirror the resolved
# SDK by symlink and run its own go command from the mirror.
for entry in "$real_goroot"/*; do ln -s "$entry" "$tmp/goroot/${entry##*/}"; done
go127="$tmp/goroot/bin/go"
cp "$harness/testdata/upstream-types/types2/check_test.go" "$tmp/patched/src/cmd/compile/internal/types2/check_test.go"
cp "$harness/testdata/upstream-types/gotypes/check_test.go" "$tmp/patched/src/go/types/check_test.go"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/types-backend/types2/check_test.go.patch"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/types-backend/gotypes/check_test.go.patch"
printf '{"Replace":{"%s/src/cmd/compile/internal/types2/check_test.go":"%s/patched/src/cmd/compile/internal/types2/check_test.go","%s/src/cmd/compile/internal/types2/bashpp_types_check_test.go":"%s/testdata/types-backend/types2/bashpp_types_check_test.go","%s/src/cmd/compile/internal/types2/bashpp_types_check_unit_test.go":"%s/testdata/types-backend/types2/bashpp_types_check_unit_test.go","%s/src/go/types/check_test.go":"%s/patched/src/go/types/check_test.go","%s/src/go/types/bashpp_types_check_test.go":"%s/testdata/types-backend/gotypes/bashpp_types_check_test.go","%s/src/go/types/bashpp_types_check_unit_test.go":"%s/testdata/types-backend/gotypes/bashpp_types_check_unit_test.go"}}\n' \
	"$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" "$tmp/goroot" "$harness" "$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" "$tmp/goroot" "$harness" > "$tmp/overlay.json"

GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$go127" build -o "$tmp/types-verify" "$harness/types-verify.go"

# One selector per runner package covers every root of that package.
selector_for() {
	pkg=$1
	checks=$(awk -F '\t' -v pkg="$pkg" '$1 !~ /^#/ && NF == 5 { split($2, a, ":"); if (a[1] == pkg) { split(a[2], b, "/"); if (b[1] == "TestCheck") printf "%s|", b[2] } }' "$matrix" | sed 's/\./\\./g; s/|$//')
	fixed=$(awk -F '\t' -v pkg="$pkg" '$1 !~ /^#/ && NF == 5 { split($2, a, ":"); if (a[1] == pkg) { split(a[2], b, "/"); if (b[1] == "TestFixedbugs") printf "%s|", b[2] } }' "$matrix" | sed 's/\./\\./g; s/|$//')
	printf '^TestCheck$/^(%s)$|^TestFixedbugs$/^(%s)$' "$checks" "$fixed"
}
terminals() {
	awk 'BEGIN{FS="\"Test\":\""} /"Action":"(pass|fail|skip)"/ { split($2, t, "\""); if (index(t[1], "/")) { match($0, /"Action":"[a-z]+"/); a = substr($0, RSTART + 10, RLENGTH - 11); print t[1], a } }' "$1" | sort
}

run_lane() {
	lane=$1 pkg=$2 id=$3 overlay=$4 backend=$5
	dir="$tmp/evidence-$lane"
	mkdir -p "$dir"
	(
		if test -n "$backend"; then
			export BASHPP_TYPES_BACKEND="$backend" BASHPP_TYPES_TOOL="$bashpp_tool" \
				BASHPP_TYPES_VERSION="$bashpp_version" BASHPP_TYPES_EVENTS="$dir/$id.events.jsonl"
		fi
		BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
			GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
			"$go127" test -count=1 -json $overlay "$pkg" -run="$(selector_for "$pkg")" \
			>"$dir/$id.go-test.json" 2>"$dir/$id.stderr" || true
	)
}

for entry in "cmd/compile/internal/types2 types2" "go/types gotypes"; do
	set -- $entry
	run_lane native "$1" "$2" "" ""
	run_lane instrumented "$1" "$2" "-overlay=$tmp/overlay.json" ""
	run_lane backend "$1" "$2" "-overlay=$tmp/overlay.json" interpreted
	native_count=$(terminals "$tmp/evidence-native/$2.go-test.json" | wc -l | tr -d ' ')
	if ! cmp -s <(terminals "$tmp/evidence-native/$2.go-test.json") <(terminals "$tmp/evidence-instrumented/$2.go-test.json"); then
		printf 'FAIL %s: patched runner is not native-equivalent with the backend off\n' "$1" >&2
		diff <(terminals "$tmp/evidence-native/$2.go-test.json") <(terminals "$tmp/evidence-instrumented/$2.go-test.json") >&2 || true
		exit 1
	fi
	test "$native_count" = 10 || { printf 'FAIL %s: %s native terminals, want 10\n' "$1" "$native_count" >&2; exit 1; }
	printf 'PASS %s: 10/10 native and instrumented terminal verdicts identical\n' "$1"
	GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$go127" test -overlay "$tmp/overlay.json" -count=1 -run '^TestBashppParse' "$1"
done

printf 'Bash++ interpreted mode: %s\n' "$bashpp_version"
status=0
"$tmp/types-verify" -matrix "$matrix" -evidence "$tmp/evidence-backend" -version "$bashpp_version" -tool "$bashpp_tool" || status=$?
case "$status" in
	0) printf 'PASS S149.10 typechecker packet: 20 authenticated roots through the exact upstream checker harnesses\n' ;;
	3) printf 'NON-GREEN S149.10 typechecker packet: every root kept the upstream checker contract; honest Bash++ product failures are retained for the product-fix sprints\n'; exit 3 ;;
	*) printf 'FAIL S149.10 typechecker packet: backend-seam defect\n' >&2; exit 1 ;;
esac
