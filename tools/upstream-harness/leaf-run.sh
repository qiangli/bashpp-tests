#!/bin/bash
# Sprint: #162; Story: S162.0; Story-ID: cda64bde8fea
#
# leaf-run.sh — one leaf re-measure: the exact upstream corpus gate restricted
# to a manifest's roots, on a named candidate, in a fresh directory, under the
# host's single-coordinator lock. Parameterised by base dir so the same script
# runs on the certification host and on a leaf droplet.
#
#   usage: leaf-run.sh <name> <manifest.tsv> [--candidate <cand>]
#                      [--harness <ref>] [--harness-bundle <file>]
#                      [--nowait] [--unlocked]
#
#   env:   LEAF_BASE  root of this host's sprint tree (default /srv/sprint162):
#                     base trees at $LEAF_BASE/base/<repo>, candidates under
#                     $LEAF_BASE/candidates/<cand>/ (rebuild-candidate.sh),
#                     results under $LEAF_BASE/leaf-<name>/
#          LEAF_SDK   pinned, authenticated Go SDK root (default /srv/sprint142):
#                     $LEAF_SDK/authenticated-sdk/bin/go + $LEAF_SDK/sdk-source/go
#
# The manifest is any TSV whose first column (after a header line) is the
# root id (`testdir:…` / `typechecker:…` / `package:…`); the gate derives the
# per-runner selectors from it and authenticates the terminal count against it.
# Without --candidate the published base candidate ($LEAF_BASE/base/bashy/bin/
# bashy.real over $LEAF_BASE/base/sh) is measured. The harness defaults to the
# base bashpp-tests clone's HEAD; --harness fetches a ref from origin,
# --harness-bundle an unpushed branch.
#
# ONE COORDINATOR PER HOST: the run holds $LEAF_BASE/leaf.lock for its whole
# duration (flock; --nowait fails instead of queueing; --unlocked is for the
# certification host's single full run only). Heavy ad-hoc work on a leaf host
# must take the same lock: `flock $LEAF_BASE/leaf.lock <cmd>`.
set -u

base=${LEAF_BASE:-/srv/sprint162}
sdk=${LEAF_SDK:-/srv/sprint142}
name=${1:?usage: leaf-run.sh <name> <manifest.tsv> [--candidate <cand>] [--harness <ref>|--harness-bundle <file>]}
manifest=${2:?usage: leaf-run.sh <name> <manifest.tsv> ...}
shift 2
cand= harness= hbundle= wait=1 locked=1
while test $# -gt 0; do
	case $1 in
	--candidate) cand=$2; shift 2 ;;
	--harness) harness=$2; shift 2 ;;
	--harness-bundle) hbundle=$2; shift 2 ;;
	--nowait) wait=0; shift ;;
	--unlocked) locked=0; shift ;;
	*) printf 'leaf-run: unknown argument %s\n' "$1" >&2; exit 2 ;;
	esac
done
case $name in */* | . | ..) printf 'leaf-run: bad name %s\n' "$name" >&2; exit 2 ;; esac
case $manifest in /*) ;; *) manifest=$PWD/$manifest ;; esac
test -r "$manifest" || { printf 'leaf-run: manifest unreadable: %s\n' "$manifest" >&2; exit 2; }

if test "$locked" = 1 && test -z "${LEAF_RUN_LOCKED:-}"; then
	mkdir -p "$base"
	flags=
	test "$wait" = 1 || flags=-n
	# Re-exec under the lock; the inner process sees LEAF_RUN_LOCKED and runs.
	# shellcheck disable=SC2086
	exec flock $flags "$base/leaf.lock" env LEAF_RUN_LOCKED=1 LEAF_BASE="$base" LEAF_SDK="$sdk" "$0" "$name" "$manifest" \
		${cand:+--candidate "$cand"} ${harness:+--harness "$harness"} ${hbundle:+--harness-bundle "$hbundle"} --unlocked
fi

dir=$base/leaf-$name
if test -e "$dir"; then printf 'leaf-run: %s exists — a leaf directory is fresh by rule; pick a new name\n' "$dir" >&2; exit 2; fi
mkdir -p "$dir/logs" "$dir/tmp" "$dir/evidence" "$dir/manifests" "$dir/in"
cp "$manifest" "$dir/in/roots.tsv"

# Harness: fresh clone of the base bashpp-tests, moved to the requested ref.
git clone -q "$base/base/bashpp-tests" "$dir/bashpp-tests" || exit 1
git -C "$dir/bashpp-tests" remote set-url origin "$(git -C "$base/base/bashpp-tests" remote get-url origin)"
if test -n "$hbundle"; then
	git -C "$dir/bashpp-tests" bundle verify "$hbundle" >/dev/null || exit 1
	git -C "$dir/bashpp-tests" fetch -q "$hbundle" && git -C "$dir/bashpp-tests" checkout -q --detach FETCH_HEAD || exit 1
elif test -n "$harness"; then
	git -C "$dir/bashpp-tests" rev-parse -q --verify "$harness^{commit}" >/dev/null 2>&1 || git -C "$dir/bashpp-tests" fetch -q origin
	git -C "$dir/bashpp-tests" checkout -q --detach "$harness" || exit 1
fi

# Candidate: a named rebuild, or the published base.
if test -n "$cand"; then
	tool=$base/candidates/$cand/bashy/bin/bashy.real
	shrt=$base/candidates/$cand/sh
else
	tool=$base/base/bashy/bin/bashy.real
	shrt=$base/base/sh
fi
test -x "$tool" || { printf 'leaf-run: candidate binary missing: %s (rebuild-candidate.sh)\n' "$tool" >&2; exit 1; }

cd "$dir/bashpp-tests" || exit 1
export GO127_TOOL=$sdk/authenticated-sdk/bin/go
export GO_CORPUS_ROOT=$sdk/sdk-source/go
export BASHPP_TOOL=$tool
export BASHPP_SHELLRT_ROOT=$shrt
export GOMAXPROCS=2 GOFLAGS=-p=2
export BASHPP_KEEP_EVIDENCE=1
export BASHPP_CORPUS_EVIDENCE=$dir/evidence
export BASHPP_CORPUS_MANIFESTS=$dir/manifests
export BASHPP_CORPUS_ROOTS=$dir/in/roots.tsv
export TMPDIR=$dir/tmp
unset POSIXLY_CORRECT POSIX_PEDANTIC
start=$(date -u +%FT%TZ)
{
	printf 'leaf=%s host=%s harness=%s bashpp=%s sh=%s candidate=%s manifest=%s roots=%s start=%s\n' \
		"$name" "$(hostname)" "$(git rev-parse --short HEAD)" "$(sha256sum "$BASHPP_TOOL" | cut -c1-16)" \
		"$(git -C "$BASHPP_SHELLRT_ROOT" rev-parse --short HEAD)" "${cand:-base}" "$manifest" \
		"$(awk -F '\t' 'NR > 1 && $1 != "" { print $1 }' "$manifest" | sort -u | grep -c .)" "$start"
} >> "$dir/logs/status.txt"
tools/upstream-harness/corpus-gate.sh > "$dir/logs/corpus-linux.log" 2>&1
rc=$?
printf 'leaf exit=%s start=%s end=%s\n' "$rc" "$start" "$(date -u +%FT%TZ)" >> "$dir/logs/status.txt"
rm -rf "$dir/evidence/gocache"
printf 'survivors: %s\n' "$(ps -eo args | grep -E 'testdir\.test|types2\.test|types\.test|bashy\.real|-gate\.sh|go-bashpp' | grep -v grep | wc -l)" >> "$dir/logs/status.txt"
printf 'DONE leaf-%s\n' "$name" >> "$dir/logs/status.txt"
cat "$dir/logs/status.txt"
test -r "$dir/manifests/active-summary.tsv" && cat "$dir/manifests/active-summary.tsv"
exit "$rc"
