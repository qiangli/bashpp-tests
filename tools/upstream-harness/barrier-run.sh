#!/bin/bash
# Sprint: #162; Story: S162.0; Story-ID: cda64bde8fea
#
# barrier-run.sh — one FULL corpus-gate run (no root manifest: every upstream
# root, native lane first as the equivalence witness) on a named candidate,
# in a fresh directory, under the host's single-coordinator lock. This is the
# Barrier form of leaf-run.sh: same base/candidate/harness layout, same pin
# rewrite for a named candidate, no BASHPP_CORPUS_ROOTS.
#
#   usage: barrier-run.sh <name> [--candidate <cand>] [--harness <ref>|--harness-bundle <file>]
#   env:   LEAF_BASE (default /srv/sprint162), LEAF_SDK (default /srv/sprint142)
set -u
base=${LEAF_BASE:-/srv/sprint162}
sdk=${LEAF_SDK:-/srv/sprint142}
name=${1:?usage: barrier-run.sh <name> [--candidate <cand>] [--harness <ref>|--harness-bundle <file>]}
shift
cand= harness= hbundle= locked=1
while test $# -gt 0; do
	case $1 in
	--candidate) cand=$2; shift 2 ;;
	--harness) harness=$2; shift 2 ;;
	--harness-bundle) hbundle=$2; shift 2 ;;
	--unlocked) locked=0; shift ;;
	*) printf 'barrier-run: unknown argument %s\n' "$1" >&2; exit 2 ;;
	esac
done
case $name in */* | . | ..) printf 'barrier-run: bad name %s\n' "$name" >&2; exit 2 ;; esac
if test "$locked" = 1 && test -z "${LEAF_RUN_LOCKED:-}"; then
	mkdir -p "$base"
	exec flock "$base/leaf.lock" env LEAF_RUN_LOCKED=1 LEAF_BASE="$base" LEAF_SDK="$sdk" "$0" "$name" \
		${cand:+--candidate "$cand"} ${harness:+--harness "$harness"} ${hbundle:+--harness-bundle "$hbundle"} --unlocked
fi
dir=$base/$name
if test -e "$dir"; then printf 'barrier-run: %s exists — a barrier directory is fresh by rule\n' "$dir" >&2; exit 2; fi
mkdir -p "$dir/logs" "$dir/tmp" "$dir/evidence" "$dir/manifests"
git clone -q "$base/base/bashpp-tests" "$dir/bashpp-tests" || exit 1
git -C "$dir/bashpp-tests" remote set-url origin "$(git -C "$base/base/bashpp-tests" remote get-url origin)"
if test -n "$hbundle"; then
	git -C "$dir/bashpp-tests" bundle verify "$hbundle" >/dev/null || exit 1
	git -C "$dir/bashpp-tests" fetch -q "$hbundle" && git -C "$dir/bashpp-tests" checkout -q --detach FETCH_HEAD || exit 1
elif test -n "$harness"; then
	git -C "$dir/bashpp-tests" rev-parse -q --verify "$harness^{commit}" >/dev/null 2>&1 || git -C "$dir/bashpp-tests" fetch -q origin
	git -C "$dir/bashpp-tests" checkout -q --detach "$harness" || exit 1
fi
if test -n "$cand"; then
	tool=$base/candidates/$cand/bashy/bin/bashy.real; shrt=$base/candidates/$cand/sh
else
	tool=$base/base/bashy/bin/bashy.real; shrt=$base/base/sh
fi
test -x "$tool" || { printf 'barrier-run: candidate binary missing: %s\n' "$tool" >&2; exit 1; }
if test -n "$cand"; then
	pinfile=$dir/bashpp-tests/tools/upstream-harness/backend-pin.tsv
	cand_sh=$(git -C "$shrt" rev-parse HEAD)
	cand_ver=$("$tool" --version 2>/dev/null | head -1)
	awk -F '\t' -v OFS='\t' -v sh="$cand_sh" -v ver="$cand_ver" '$1 == "shellrt_commit" { $2 = sh } $1 == "bashpp_version" { $2 = ver } { print }' "$pinfile" > "$pinfile.cand" && mv "$pinfile.cand" "$pinfile"
	printf 'pin override (candidate %s): shellrt_commit=%s bashpp_version=%s\n' "$cand" "$cand_sh" "$cand_ver" >> "$dir/logs/status.txt"
fi
cd "$dir/bashpp-tests" || exit 1
export GO127_TOOL=$sdk/authenticated-sdk/bin/go GO_CORPUS_ROOT=$sdk/sdk-source/go
export BASHPP_TOOL=$tool BASHPP_SHELLRT_ROOT=$shrt
export GOMAXPROCS=2 GOFLAGS=-p=2 BASHPP_KEEP_EVIDENCE=1
export BASHPP_CORPUS_EVIDENCE=$dir/evidence BASHPP_CORPUS_MANIFESTS=$dir/manifests TMPDIR=$dir/tmp
unset POSIXLY_CORRECT POSIX_PEDANTIC BASHPP_CORPUS_ROOTS
start=$(date -u +%FT%TZ)
printf 'barrier=%s host=%s harness=%s bashpp=%s sh=%s candidate=%s start=%s\n' "$name" "$(hostname)" "$(git rev-parse --short HEAD)" \
	"$(sha256sum "$BASHPP_TOOL" | cut -c1-16)" "$(git -C "$BASHPP_SHELLRT_ROOT" rev-parse --short HEAD)" "${cand:-base}" "$start" >> "$dir/logs/status.txt"
tools/upstream-harness/corpus-gate.sh > "$dir/logs/corpus-linux.log" 2>&1
rc=$?
printf 'corpus exit=%s start=%s end=%s\n' "$rc" "$start" "$(date -u +%FT%TZ)" >> "$dir/logs/status.txt"
rm -rf "$dir/evidence/gocache"
printf 'survivors: %s\n' "$(ps -eo args | grep -E 'testdir\.test|types2\.test|types\.test|bashy\.real|-gate\.sh|go-bashpp' | grep -v grep | wc -l)" >> "$dir/logs/status.txt"
printf 'DONE %s\n' "$name" >> "$dir/logs/status.txt"
cat "$dir/logs/status.txt"
test -r "$dir/manifests/active-summary.tsv" && cat "$dir/manifests/active-summary.tsv"
exit "$rc"
