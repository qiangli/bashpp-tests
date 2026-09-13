#!/usr/bin/env bash
# Sprint: #151; Story: S151.0; Story-ID: fd3a390ec1f2
# Sprint: #155; Story: S155.11; Story-ID: 5004b3c3
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

# Sprint 157 freezes the linux/amd64 Go 1.27.0 executable, not merely the
# version string. Darwin developers may explicitly skip this one check because
# that Linux binary cannot run on Darwin; every other platform stays closed.
go_binary=$go_tool
case "$go_binary" in
	*/*) ;;
	*) go_binary=$(command -v "$go_binary" || true) ;;
esac
if test "$(uname -s)" = Darwin && test "${BASHPP_SKIP_GO_BINARY_PIN:-}" = 1; then
	printf 'SKIP pin go_binary_sha256: BASHPP_SKIP_GO_BINARY_PIN=1 (pinned binary is linux/amd64)\n'
else
	check_pin go_binary_sha256 "$go_binary"
fi
real_goroot=$($go_tool env GOROOT)
# The SDK runner is source identity, so unlike the Linux executable pin it is
# mandatory on every host and has no development escape hatch.
check_pin testdir_upstream_sha256 "$real_goroot/src/cmd/internal/testdir/testdir_test.go"

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

# BASHPP_CORPUS_SMOKE=<go test -run regexp> exercises the plumbing on a few
# roots; counts are printed but not authenticated and the exit is always 1,
# so a smoke run can never be read as a barrier result.
smoke=${BASHPP_CORPUS_SMOKE:-}

# BASHPP_CORPUS_ROOTS=<active manifest TSV> is the LEAF form: the run is
# restricted to the manifest's roots (per-runner -run selectors derived from
# the root ids, and only the packages it names), and each runner's terminal
# count is authenticated against the manifest instead of the native lane,
# which still runs first as the equivalence witness. The root-list digest is
# printed in the pin.tsv shape so a leaf run names exactly what it ran.
roots=${BASHPP_CORPUS_ROOTS:-}
leaf_testdir=; leaf_types2=; leaf_types=; leaf_packages=
want_testdir=; want_types=; want_packages=
if test -n "$roots"; then
	test -z "$smoke" || { printf 'FAIL BASHPP_CORPUS_ROOTS and BASHPP_CORPUS_SMOKE are exclusive\n' >&2; exit 1; }
	test -r "$roots" || { printf 'FAIL leaf manifest unreadable: %s\n' "$roots" >&2; exit 1; }
	rootlist=$(awk -F '\t' 'NR > 1 && $1 != "" { print $1 }' "$roots" | sort -u)
	printf 'leaf manifest %s: %s roots, root-list sha256 %s\n' "$roots" "$(printf '%s\n' "$rootlist" | grep -c .)" "$(printf '%s\n' "$rootlist" | sha256_stdin)"
	# testdir:<dir>/<file> -> ^Test$/^<dir>$/^<file>$ ; testdir:<file> -> ^Test$/^<file>$
	leaf_testdir=$(printf '%s\n' "$rootlist" | awk -F: '$1 == "testdir" { n = $2; gsub(/\./, "\\.", n); if (index(n, "/")) { d = n; sub(/\/[^\/]*$/, "", d); f = n; sub(/^.*\//, "", f); printf "^Test$/^%s$/^%s$|", d, f } else printf "^Test$/^%s$|", n }' | sed 's/|$//')
	# typechecker:<package>/<TestFunc>/<file> -> ^<TestFunc>$/^<file>$ per package
	leaf_types2=$(printf '%s\n' "$rootlist" | awk -F: '$1 == "typechecker" && index($2, "cmd/compile/internal/types2/") == 1 { n = substr($2, length("cmd/compile/internal/types2/") + 1); gsub(/\./, "\\.", n); split(n, a, "/"); printf "^%s$/^%s$|", a[1], a[2] }' | sed 's/|$//')
	leaf_types=$(printf '%s\n' "$rootlist" | awk -F: '$1 == "typechecker" && index($2, "go/types/") == 1 { n = substr($2, length("go/types/") + 1); gsub(/\./, "\\.", n); split(n, a, "/"); printf "^%s$/^%s$|", a[1], a[2] }' | sed 's/|$//')
	leaf_packages=$(printf '%s\n' "$rootlist" | awk -F: '$1 == "package" { print $2 }')
	want_testdir=$(printf '%s\n' "$rootlist" | grep -c '^testdir:' || true)
	want_types=$(printf '%s\n' "$rootlist" | grep -c '^typechecker:' || true)
	want_packages=$(printf '%s\n' "$rootlist" | grep -c '^package:' || true)
fi
# run selector for one runner: the smoke regexp, the leaf selector, or none.
# An empty leaf selector for a runner the manifest does not name skips it.
selector() {
	if test -n "$smoke"; then printf -- '-run=%s' "$smoke"
	elif test -n "$roots"; then
		case "$1" in
			testdir) test -n "$leaf_testdir" && printf -- '-run=%s' "$leaf_testdir" || printf -- '-run=^$' ;;
			types2) test -n "$leaf_types2" && printf -- '-run=%s' "$leaf_types2" || printf -- '-run=^$' ;;
			types) test -n "$leaf_types" && printf -- '-run=%s' "$leaf_types" || printf -- '-run=^$' ;;
		esac
	fi
}

seam_fail=0
product_fail=0
# The native lane (backend unset: the patched runners execute natively, the
# S157/S149/S150 native-equivalence shape) is the count authority for the
# two backend lanes; the Sprint 142 inventory numbers are printed for the
# record only. This is the "reauthenticate the native oracle" step of
# Barrier A, done by the same runner that produces the product verdicts.
native_testdir=; native_types=; native_packages=
for mode in native interpreted compiled; do
	dir="$tmp/evidence-$mode"
	mkdir -p "$dir/packages"
	if test "$mode" = native; then
		printf 'native lane (backend off): %s\n' "$go_version"
	else
		printf 'Bash++ %s mode: %s\n' "$mode" "$bashpp_version"
	fi

	(
		if test "$mode" != native; then
			export BASHPP_TESTDIR_EVENTS="$dir/testdir.events.jsonl" \
				BASHPP_TESTDIR_BACKEND="$mode" BASHPP_TESTDIR_TOOL="$bashpp_tool" \
				BASHPP_TESTDIR_GO="$go_tool" BASHPP_TESTDIR_VERSION="$bashpp_version" \
				BASHPP_SHELLRT_ROOT="$shellrt"
		fi
		BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
		GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
			"$go127" test -count=1 -json -timeout=48h -overlay="$tmp/harness-overlay.json" cmd/internal/testdir $(selector testdir) \
			>"$dir/testdir.go-test.json" 2>"$dir/testdir.stderr" || true
	)
	set -- $(test_leaf_counts "$dir/testdir.go-test.json")
	printf 'testdir %s: %s terminals, %s non-PASS (inventory 2726)\n' "$mode" "$1" "$2"
	if test "$mode" = native; then native_testdir=$1
	elif test -n "$smoke"; then :
	elif test -n "$roots" && test "$1" != "$want_testdir"; then seam_fail=1
	elif test -n "$roots"; then test "$2" = 0 || product_fail=1
	elif test "$1" != "$native_testdir"; then seam_fail=1
	elif test "$2" != 0; then product_fail=1; fi

	for entry in "cmd/compile/internal/types2 types2" "go/types types"; do
		set -- $entry
		(
			if test "$mode" != native; then
				export BASHPP_TYPES_BACKEND="$mode" BASHPP_TYPES_TOOL="$bashpp_tool" \
					BASHPP_TYPES_VERSION="$bashpp_version" BASHPP_TYPES_EVENTS="$dir/$2.events.jsonl"
			fi
			BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
			GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
				"$go127" test -count=1 -json -timeout=24h -overlay="$tmp/harness-overlay.json" "$1" $(selector "$2") \
				>"$dir/$2.go-test.json" 2>"$dir/$2.stderr" || true
		)
		set -- $(test_leaf_counts "$dir/$2.go-test.json")
		printf '%s %s: %s terminals, %s non-PASS\n' "$entry" "$mode" "$1" "$2"
	done
	set -- $(test_leaf_counts "$dir/types2.go-test.json" "$dir/types.go-test.json")
	printf 'typechecker %s: %s raw terminals, %s raw non-PASS (product denominator comes from types-backend seam evidence)\n' "$mode" "$1" "$2"
	if test "$mode" = native; then native_types=$1
	elif test -n "$smoke"; then :
	elif test -n "$roots" && test "$1" != "$want_types"; then seam_fail=1
	elif test -n "$roots"; then :
	elif test "$1" != "$native_types"; then seam_fail=1; fi

	while IFS="$tab" read -r capability pkg action want companions; do
		case "$capability" in ''|'#'*) continue ;; esac
		if test -n "$roots" && ! printf '%s\n' "$leaf_packages" | grep -qx -- "$pkg"; then continue; fi
		case_id=$(printf '%s' "$pkg" | tr '/.' '__')
		(
			cd "$tmp/goroot/src"
			if test "$mode" != native; then
				export BASHPP_GOTEST_BACKEND="$mode" BASHPP_GOTEST_TOOL="$bashpp_tool" \
					BASHPP_GOTEST_VERSION="$bashpp_version" BASHPP_GOTEST_GO="$go127" \
					BASHPP_SHELLRT_ROOT="$shellrt" BASHPP_GOTEST_EVENTS="$dir/packages/$case_id.events.jsonl"
			fi
			BASHY_OTEL_SPOOL="$tmp/bashy-otel.jsonl" BASHY_HINTS=0 BASHY_NO_COACH=1 \
			GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
				"$tmp/go-bashpp" test -count=1 -json -timeout=10m "$pkg" \
				>"$dir/packages/$case_id.go-test.json" 2>"$dir/packages/$case_id.stderr" || true
		)
	done < "$package_matrix"
	if ls "$dir"/packages/*.go-test.json >/dev/null 2>&1; then
		set -- $(package_counts "$dir"/packages/*.go-test.json)
	else
		set -- 0 0
	fi
	printf 'packages %s: %s terminals, %s non-PASS (inventory 26)\n' "$mode" "$1" "$2"
	if test "$mode" = native; then native_packages=$1
	elif test -n "$smoke"; then :
	elif test -n "$roots" && test "$1" != "$want_packages"; then seam_fail=1
	elif test -n "$roots"; then test "$2" = 0 || product_fail=1
	elif test "$1" != "$native_packages"; then seam_fail=1
	elif test "$2" != 0; then product_fail=1; fi

	# The partition emitter reads one stream per runner and one events file
	# per mode (each record already names its package and test).
	cat "$dir"/packages/*.go-test.json > "$dir/package.go-test.json" 2>/dev/null || : > "$dir/package.go-test.json"
	if test "$mode" != native; then
		cat "$dir"/*.events.jsonl "$dir"/packages/*.events.jsonl > "$dir/backend.events.jsonl" 2>/dev/null || true
	fi
done

if test -f "$harness/partition-emit.go"; then
	# BARRIER A -> PARTITION EMITTER HANDOFF (keep this invocation explicit).
	GOROOT="$tmp/goroot" GOTOOLCHAIN=local GOCACHE="$tmp/gocache" \
		"$go127" build -o "$tmp/partition-emit" "$harness/partition-emit.go"
	manifest_out=${BASHPP_CORPUS_MANIFESTS:-$root/docs/upstream-harness}
	emit_status=0
	"$tmp/partition-emit" -evidence-interpreted "$tmp/evidence-interpreted" -evidence-compiled "$tmp/evidence-compiled" \
		-out "$manifest_out" || emit_status=$?
	case "$emit_status" in 0) ;; 3) product_fail=1 ;; *) seam_fail=1 ;; esac

	# Product credit is determined by actual seam execution, not by the raw Go
	# test terminal. The emitter excludes typechecker leaves with no
	# types-backend record in either product lane and requires every remaining
	# leaf to carry a record in both lanes.
	summary="$manifest_out/active-summary.tsv"
	set -- $(awk -F '\t' '$1 == "typechecker" { print $5, $6; exit }' "$summary")
	product_types=${1:-}; native_only_types=${2:-}
	set -- $(awk -F '\t' '$1 == "product" { in_product=1; next } in_product && $1 == "total" { print $2, $3, $4, $5; exit }' "$summary")
	product_roots=${1:-}; native_applicable=${2:-}; product_skips=${3:-}; native_only=${4:-}
	if test -z "$product_types" || test -z "$native_only_types" || test -z "$product_roots" || test -z "$native_applicable" || test -z "$product_skips" || test -z "$native_only"; then
		printf 'FAIL product tally missing from %s\n' "$summary" >&2
		seam_fail=1
	else
		printf 'typechecker product tally: %s roots; %s native-only (zero credit; listed in %s/native-only-typechecker.tsv)\n' "$product_types" "$native_only_types" "$manifest_out"
		printf 'product tally: %s roots / %s native-applicable / %s SKIP; %s native-only (zero credit)\n' "$product_roots" "$native_applicable" "$product_skips" "$native_only"
		if test -z "$smoke" && test -z "$roots" && { test "$product_types" != 743 || test "$native_only_types" != 156 || test "$product_roots" != 3495 || test "$native_applicable" != 3456 || test "$product_skips" != 39 || test "$native_only" != 156; }; then
			printf 'FAIL full-corpus product tally: want typechecker 743 and 3495 / 3456 / 39 with 156 native-only\n' >&2
			seam_fail=1
		fi
		if test -n "$roots" && { test "$product_types" != "$want_types" || test "$native_only_types" != 0; }; then
			printf 'FAIL leaf manifest contains %s product typechecker roots and %s native-only roots; want %s and 0\n' "$product_types" "$native_only_types" "$want_types" >&2
			seam_fail=1
		fi
	fi
else
	retain_evidence=1
	printf 'partition emitter not present; evidence directories: %s/evidence-interpreted %s/evidence-compiled\n' "$tmp" "$tmp"
fi

if test -n "$smoke"; then
	printf 'SMOKE S151.0 corpus gate (-run=%s): plumbing exercised, no barrier verdict\n' "$smoke"
	exit 1
fi
if test "$seam_fail" -ne 0; then
	printf 'FAIL S151.0 corpus gate: setup, seam, or authenticated-count failure\n' >&2
	exit 1
fi
if test "$product_fail" -ne 0; then
	printf 'NON-GREEN S151.0 corpus gate%s: every root was accounted for; at least one root was non-PASS\n' "${roots:+ (leaf $roots)}"
	exit 3
fi
printf 'PASS S151.0 corpus gate%s: every root PASS through both Bash++ modes\n' "${roots:+ (leaf $roots)}"
