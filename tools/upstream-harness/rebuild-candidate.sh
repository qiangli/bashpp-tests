#!/bin/bash
# Sprint: #162; Story: S162.0; Story-ID: cda64bde8fea
#
# rebuild-candidate.sh — build one named Bash++ candidate (bashy.real over a
# chosen sh / coreutils / bashy commit set) on a leaf or certification host,
# WITHOUT touching the base trees. Every candidate lives in its own flat
# sibling set so bashy's `../sh` / `../coreutils` / `../readline` /
# `../filebrowser` replaces resolve inside it, and several candidates coexist.
#
#   usage: rebuild-candidate.sh <name> [--sh <ref>] [--sh-bundle <file>]
#                                      [--coreutils <ref>] [--coreutils-bundle <file>]
#                                      [--bashy <ref>] [--bashy-bundle <file>]
#
#   env:   LEAF_BASE  root of this host's sprint tree (default /srv/sprint162);
#                     base trees at $LEAF_BASE/base/<repo> (the published pins)
#          LEAF_SDK   pinned, authenticated Go SDK root (default /srv/sprint142)
#
# A <ref> is any commit reachable from the base clone after `git fetch origin`
# (a sha, a branch, a tag); a bundle is fetched into the candidate's clone
# first, so a worker can ship an unpushed branch as `git bundle create`.
# Output: $LEAF_BASE/candidates/<name>/bashy/bin/bashy.real and
# $LEAF_BASE/candidates/<name>/candidate.txt (the six shas + the binary digest).
set -eu

base=${LEAF_BASE:-/srv/sprint162}
sdk=${LEAF_SDK:-/srv/sprint142}
name=${1:?usage: rebuild-candidate.sh <name> [--sh <ref>] [--sh-bundle <file>] ...}
shift
declare -A ref=([sh]= [coreutils]= [bashy]=)
declare -A bundle=([sh]= [coreutils]= [bashy]=)
while test $# -gt 0; do
	case $1 in
	--sh) ref[sh]=$2; shift 2 ;;
	--sh-bundle) bundle[sh]=$2; shift 2 ;;
	--coreutils) ref[coreutils]=$2; shift 2 ;;
	--coreutils-bundle) bundle[coreutils]=$2; shift 2 ;;
	--bashy) ref[bashy]=$2; shift 2 ;;
	--bashy-bundle) bundle[bashy]=$2; shift 2 ;;
	*) printf 'rebuild-candidate: unknown argument %s\n' "$1" >&2; exit 2 ;;
	esac
done
case $name in */* | . | ..) printf 'rebuild-candidate: bad name %s\n' "$name" >&2; exit 2 ;; esac

cand=$base/candidates/$name
mkdir -p "$base/candidates"
for r in bashy sh coreutils readline filebrowser; do
	test -d "$base/base/$r/.git" || { printf 'rebuild-candidate: base tree missing: %s\n' "$base/base/$r" >&2; exit 1; }
	if ! test -d "$cand/$r/.git"; then
		git clone -q "$base/base/$r" "$cand/$r"
		git -C "$cand/$r" remote set-url origin "$(git -C "$base/base/$r" remote get-url origin)"
	fi
	want=${ref[$r]:-}
	if test -n "${bundle[$r]:-}"; then
		test -r "${bundle[$r]}" || { printf 'rebuild-candidate: bundle unreadable: %s\n' "${bundle[$r]}" >&2; exit 1; }
		git -C "$cand/$r" bundle verify "${bundle[$r]}" >/dev/null
		# A worker's bundle usually carries only HEAD (`git bundle create x HEAD`):
		# fetch its tip by sha so the checkout never depends on FETCH_HEAD state.
		tip=$(git -C "$cand/$r" bundle list-heads "${bundle[$r]}" | awk '$2 == "HEAD" { print $1; exit }')
		test -n "$tip" || tip=$(git -C "$cand/$r" bundle list-heads "${bundle[$r]}" | awk 'NR == 1 { print $1 }')
		git -C "$cand/$r" fetch -q "${bundle[$r]}" "$tip"
		test -n "$want" || want=$tip
	elif test -n "$want"; then
		git -C "$cand/$r" fetch -q "$base/base/$r" '+refs/heads/*:refs/base/*' || true
		git -C "$cand/$r" rev-parse -q --verify "$want^{commit}" >/dev/null 2>&1 || git -C "$cand/$r" fetch -q origin
	else
		want=$(git -C "$base/base/$r" rev-parse HEAD)
	fi
	git -C "$cand/$r" checkout -q --detach "$want"
done

cd "$cand/bashy"
export PATH=$sdk/authenticated-sdk/bin:$PATH GOTOOLCHAIN=local GOFLAGS=-mod=mod
cmd=$(make -n build-bashy 2>/dev/null | grep -o 'go build -trimpath -ldflags "[^"]*" -o [^ ]* ./cmd/bashy' | head -1)
test -n "$cmd" || { printf 'rebuild-candidate: could not derive the bashy build command from make -n build-bashy\n' >&2; exit 1; }
cmd=${cmd//\$out/bin/bashy.real}
mkdir -p bin
eval "$cmd"
{
	printf 'candidate=%s built=%s\n' "$name" "$(date -u +%FT%TZ)"
	for r in bashy sh coreutils readline filebrowser; do
		printf '%-12s %s\n' "$r" "$(git -C "$cand/$r" rev-parse HEAD)"
	done
	printf 'go           %s\n' "$(sha256sum "$sdk/authenticated-sdk/bin/go" | cut -c1-64)"
	printf 'bashy.real   %s\n' "$(sha256sum bin/bashy.real | cut -c1-64)"
} > "$cand/candidate.txt"
bin/bashy.real --version
cat "$cand/candidate.txt"
