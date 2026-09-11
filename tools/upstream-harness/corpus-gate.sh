#!/usr/bin/env bash
# Sprint: #151; Story: S151.0; Story-ID: fd3a390ec1f2
#
# Barrier A replays the whole Go 1.27 corpus: 2,726 testdir roots, 743
# typechecker roots, and 26 package roots. The exact upstream Go harnesses own
# selection and verdicts; the accepted backend seams only substitute Bash++ at
# their execution/check boundaries. Besides Barrier B, this is the only full
# replay. Its evidence is Linux-only and is not a cross-platform certification.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
harness="$root/tools/upstream-harness"
typechecker_matrix="$root/docs/upstream-harness/typechecker-matrix.tsv"
package_matrix="$root/docs/upstream-harness/package-matrix.tsv"
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

# Freeze every source and patch that forms one of the three accepted seams.
check_pin upstream "$harness/testdata/upstream/testdir_test.go"
check_pin instrumentation_patch "$harness/testdata/instrumented/testdir_test.go.patch"
check_pin instrumentation_hook "$harness/testdata/instrumented/bashpp_events_test.go"
check_pin backend_patch "$harness/testdata/backend/testdir_test.go.patch"
check_pin backend_events_patch "$harness/testdata/backend/events_test.go.patch"
check_pin backend_hook "$harness/testdata/backend/bashpp_backend_test.go"
check_pin types2_upstream "$harness/testdata/upstream-types/types2/check_test.go"
check_pin gotypes_upstream "$harness/testdata/upstream-types/gotypes/check_test.go"
check_pin types2_patch "$harness/testdata/types-backend/types2/check_test.go.patch"
check_pin gotypes_patch "$harness/testdata/types-backend/gotypes/check_test.go.patch"
check_pin types2_hook "$harness/testdata/types-backend/types2/bashpp_types_check_test.go"
check_pin gotypes_hook "$harness/testdata/types-backend/gotypes/bashpp_types_check_test.go"
check_pin typechecker_matrix "$typechecker_matrix"
check_pin gotest_upstream "$harness/testdata/upstream-go/test.go"
check_pin gotest_patch "$harness/testdata/go-backend/test.go.patch"
check_pin gotest_hook "$harness/testdata/go-backend/bashpp_backend.go"
check_pin package_matrix "$package_matrix"

go_tool=${GO127_TOOL:-go}
if test -z "${GO127_TOOL:-}"; then export GOTOOLCHAIN=go1.27.0; fi
go_version=$($go_tool version)
case "$go_version" in
	'go version go1.27.0 '*) ;;
	*) printf 'FAIL Go pin: %s\n' "$go_version" >&2; exit 1 ;;
esac
real_goroot=$($go_tool env GOROOT)

# These two runners and cmd/go must come from the same pinned SDK whose go
# command drives the replay. Digest paths directly: a cd in command
# substitution is not safe under bashy's /usr/bin/env bash dispatch.
test "$(sha256 "$real_goroot/src/cmd/compile/internal/types2/check_test.go")" = "$(pin_value types2_upstream)" || {
	printf 'FAIL GOROOT types2 runner differs from the frozen upstream\n' >&2
	exit 1
}
test "$(sha256 "$real_goroot/src/go/types/check_test.go")" = "$(pin_value gotypes_upstream)" || {
	printf 'FAIL GOROOT go/types runner differs from the frozen upstream\n' >&2
	exit 1
}
test "$(sha256 "$real_goroot/src/cmd/go/internal/test/test.go")" = "$(pin_value gotest_upstream)" || {
	printf 'FAIL GOROOT cmd/go test runner differs from the frozen upstream\n' >&2
	exit 1
}

test -n "${GO_CORPUS_ROOT:-}" && test -d "$GO_CORPUS_ROOT/test" || {
	printf 'FAIL GO_CORPUS_ROOT must name the Go 1.27 source corpus with a test/ directory\n' >&2
	exit 1
}
test_root="$GO_CORPUS_ROOT/test"

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

tab=$(printf '\t')
package_count=$(awk -F '\t' '$1 !~ /^#/ && NF == 5 { n++ } END { print n + 0 }' "$package_matrix")
test "$package_count" = 26 || { printf 'FAIL package matrix count is %s, want 26\n' "$package_count" >&2; exit 1; }

# The package matrix is the reviewed definition of the complete package axis.
pkg_digest() {
	for file in "$real_goroot/src/$1"/*.go; do
		printf '%s %s\n' "$(sha256 "$file")" "${file##*/}"
	done | sort -k2 | sha256_stdin
}
while IFS="$tab" read -r capability pkg action want companions; do
	case "$capability" in ''|'#'*) continue ;; esac
	test "$(pkg_digest "$pkg")" = "$want" || { printf 'FAIL package pin %s\n' "$pkg" >&2; exit 1; }
done < "$package_matrix"

external_evidence=0
retain_evidence=0
if test -n "${BASHPP_CORPUS_EVIDENCE:-}"; then
	tmp=$BASHPP_CORPUS_EVIDENCE
	external_evidence=1
	if test -e "$tmp" && test -n "$(find "$tmp" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"; then
		printf 'FAIL BASHPP_CORPUS_EVIDENCE is not empty: %s\n' "$tmp" >&2
		exit 1
	fi
	mkdir -p "$tmp"
else
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/bashpp-s1510.XXXXXX")
fi
cleanup() {
	if test "$external_evidence" -eq 1 || test "$retain_evidence" -eq 1 || test "${BASHPP_KEEP_EVIDENCE:-0}" = 1; then
		printf 'evidence retained: %s\n' "$tmp"
	else
		rm -rf "$tmp"
	fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$tmp/patched/src/cmd/internal/testdir" \
	"$tmp/patched/src/cmd/compile/internal/types2" \
	"$tmp/patched/src/go/types" \
	"$tmp/patched/src/cmd/go/internal/test" \
	"$tmp/gocache" "$tmp/goroot"

cp "$harness/testdata/upstream/testdir_test.go" "$tmp/patched/src/cmd/internal/testdir/testdir_test.go"
cp "$harness/testdata/instrumented/bashpp_events_test.go" "$tmp/patched/src/cmd/internal/testdir/bashpp_events_test.go"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/instrumented/testdir_test.go.patch"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/backend/testdir_test.go.patch"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/backend/events_test.go.patch"

cp "$harness/testdata/upstream-types/types2/check_test.go" "$tmp/patched/src/cmd/compile/internal/types2/check_test.go"
cp "$harness/testdata/upstream-types/gotypes/check_test.go" "$tmp/patched/src/go/types/check_test.go"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/types-backend/types2/check_test.go.patch"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/types-backend/gotypes/check_test.go.patch"

cp "$harness/testdata/upstream-go/test.go" "$tmp/patched/src/cmd/go/internal/test/test.go"
patch -s -d "$tmp/patched" -p1 < "$harness/testdata/go-backend/test.go.patch"

# Overlays cannot replace files under GOMODCACHE. Mirror the pinned SDK and
# replace only test/: the full testdir corpus always comes from GO_CORPUS_ROOT.
for entry in "$real_goroot"/*; do
	name=${entry##*/}
	if test "$name" != test; then ln -s "$entry" "$tmp/goroot/$name"; fi
done
ln -s "$test_root" "$tmp/goroot/test"
go127="$tmp/goroot/bin/go"

printf '{"Replace":{"%s/src/cmd/internal/testdir/testdir_test.go":"%s/patched/src/cmd/internal/testdir/testdir_test.go","%s/src/cmd/internal/testdir/bashpp_events_test.go":"%s/patched/src/cmd/internal/testdir/bashpp_events_test.go","%s/src/cmd/internal/testdir/bashpp_backend_test.go":"%s/testdata/backend/bashpp_backend_test.go","%s/src/cmd/compile/internal/types2/check_test.go":"%s/patched/src/cmd/compile/internal/types2/check_test.go","%s/src/cmd/compile/internal/types2/bashpp_types_check_test.go":"%s/testdata/types-backend/types2/bashpp_types_check_test.go","%s/src/go/types/check_test.go":"%s/patched/src/go/types/check_test.go","%s/src/go/types/bashpp_types_check_test.go":"%s/testdata/types-backend/gotypes/bashpp_types_check_test.go"}}\n' \
	"$tmp/goroot" "$tmp" "$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" \
	"$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" "$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" > "$tmp/harness-overlay.json"
printf '{"Replace":{"%s/src/cmd/go/internal/test/test.go":"%s/patched/src/cmd/go/internal/test/test.go","%s/src/cmd/go/internal/test/bashpp_backend.go":"%s/testdata/go-backend/bashpp_backend.go"}}\n' \
	"$tmp/goroot" "$tmp" "$tmp/goroot" "$harness" > "$tmp/cmdgo-overlay.json"

# The patched go command is the package-axis runner; build it so its exit code
# is observed directly rather than collapsed by go run.
GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
	"$go127" build -overlay="$tmp/cmdgo-overlay.json" -o "$tmp/go-bashpp" cmd/go

# Print "terminal-record-count non-PASS-leaf-count" for Test*/* leaves.
# A terminal whose name prefixes another terminal is a harness grouping node,
# not a corpus root. Including FILENAME keeps identical names in the two type
# checker packages distinct.
test_leaf_counts() {
	awk '
		/"Action":"(pass|fail|skip)"/ && /"Test":"Test[^\"]*\// {
			a = $0; sub(/^.*"Action":"/, "", a); sub(/".*$/, "", a)
			t = $0; sub(/^.*"Test":"/, "", t); sub(/".*$/, "", t)
			k = FILENAME SUBSEP t
			name[k] = t; file[k] = FILENAME; seen[k]++
			if (a != "pass") bad[k] = 1
		}
		END {
			for (k in name) {
				parent = 0
				for (j in name)
					if (file[j] == file[k] && index(name[j], name[k] "/") == 1) { parent = 1; break }
				if (!parent) { count += seen[k]; nonpass += bad[k] }
			}
			print count + 0, nonpass + 0
		}' "$@"
}

# Print "package-terminal-count non-PASS-package-count". Package roots are
# authenticated by package-level terminal records, not their many test bodies.
package_counts() {
	awk '
		/"Action":"(pass|fail|skip)"/ && !/"Test":/ {
			a = $0; sub(/^.*"Action":"/, "", a); sub(/".*$/, "", a)
			count++; if (a != "pass") nonpass++
		}
		END { print count + 0, nonpass + 0 }' "$@"
}

seam_fail=0
product_fail=0
for mode in interpreted compiled; do
	dir="$tmp/evidence-$mode"
	mkdir -p "$dir"
	printf 'Bash++ %s mode: %s\n' "$mode" "$bashpp_version"

	BASHPP_TESTDIR_EVENTS="$dir/testdir.events.jsonl" \
	BASHPP_TESTDIR_BACKEND="$mode" BASHPP_TESTDIR_TOOL="$bashpp_tool" \
	BASHPP_TESTDIR_GO="$go_tool" BASHPP_TESTDIR_VERSION="$bashpp_version" \
	BASHPP_SHELLRT_ROOT="$shellrt" \
	BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
	GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
		"$go127" test -count=1 -json -timeout=6h -overlay="$tmp/harness-overlay.json" cmd/internal/testdir \
		>"$dir/testdir.go-test.json" 2>"$dir/testdir.stderr" || true
	set -- $(test_leaf_counts "$dir/testdir.go-test.json")
	printf 'testdir %s: %s terminals, %s non-PASS (want 2726)\n' "$mode" "$1" "$2"
	if test "$1" != 2726; then seam_fail=1; elif test "$2" != 0; then product_fail=1; fi

	for entry in "cmd/compile/internal/types2 types2" "go/types gotypes"; do
		set -- $entry
		BASHPP_TYPES_BACKEND="$mode" BASHPP_TYPES_TOOL="$bashpp_tool" \
		BASHPP_TYPES_VERSION="$bashpp_version" BASHPP_TYPES_EVENTS="$dir/$2.events.jsonl" \
		BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
		GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
			"$go127" test -count=1 -json -overlay="$tmp/harness-overlay.json" "$1" \
			>"$dir/$2.go-test.json" 2>"$dir/$2.stderr" || true
		set -- $(test_leaf_counts "$dir/$2.go-test.json")
		printf '%s %s: %s terminals, %s non-PASS\n' "$entry" "$mode" "$1" "$2"
	done
	set -- $(test_leaf_counts "$dir/types2.go-test.json" "$dir/gotypes.go-test.json")
	printf 'typechecker %s: %s terminals, %s non-PASS (want 743)\n' "$mode" "$1" "$2"
	if test "$1" != 743; then seam_fail=1; elif test "$2" != 0; then product_fail=1; fi

	while IFS="$tab" read -r capability pkg action want companions; do
		case "$capability" in ''|'#'*) continue ;; esac
		case_id=$(printf '%s' "$pkg" | tr '/.' '__')
		(
			cd "$tmp/goroot/src"
			BASHPP_GOTEST_BACKEND="$mode" BASHPP_GOTEST_TOOL="$bashpp_tool" \
			BASHPP_GOTEST_VERSION="$bashpp_version" BASHPP_GOTEST_GO="$go127" \
			BASHPP_SHELLRT_ROOT="$shellrt" BASHPP_GOTEST_EVENTS="$dir/$case_id.events.jsonl" \
			BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
			GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
				"$tmp/go-bashpp" test -count=1 -json "$pkg" \
				>"$dir/$case_id.go-test.json" 2>"$dir/$case_id.stderr" || true
		)
	done < "$package_matrix"
	set -- $(package_counts "$dir"/*__*.go-test.json)
	printf 'packages %s: %s terminals, %s non-PASS (want 26)\n' "$mode" "$1" "$2"
	if test "$1" != 26; then seam_fail=1; elif test "$2" != 0; then product_fail=1; fi
done

if test -f "$harness/partition-emit.go"; then
	# BARRIER A -> PARTITION EMITTER HANDOFF (keep this invocation explicit).
	GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" "$go127" run "$harness/partition-emit.go" -evidence "$tmp/evidence-interpreted" -evidence "$tmp/evidence-compiled" || seam_fail=1
else
	retain_evidence=1
	printf 'partition emitter not present; evidence directories: %s/evidence-interpreted %s/evidence-compiled\n' "$tmp" "$tmp"
fi

if test "$seam_fail" -ne 0; then
	printf 'FAIL S151.0 corpus gate: setup, seam, or authenticated-count failure\n' >&2
	exit 1
fi
if test "$product_fail" -ne 0; then
	printf 'NON-GREEN S151.0 corpus gate: all 3,495 roots were accounted for; at least one root was non-PASS\n'
	exit 3
fi
printf 'PASS S151.0 corpus gate: all 3,495 roots PASS through both Bash++ modes\n'
