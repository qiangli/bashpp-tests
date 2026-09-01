#!/usr/bin/env bash
#
# Cross-check the Go Day-1 start-site table against the measured corpus.
#
# WHY THIS EXISTS. sh/syntax/bashpp_startsites_test.go carries a table of
# (corpus id, shape, start site, class). Those classes were copied from
# baseline.tsv, which means they can silently go stale: re-measure the corpus,
# a class flips, and the Go table keeps asserting the old one. Both suites stay
# green while disagreeing, which is the failure mode this whole corpus exists
# to prevent — a gate that cannot report the thing it was built to catch.
#
# So the two are compared here, and a disagreement is a hard failure.
#
# A NOTE ON WHICH CLASS IS COMPARED. The corpus measures COMPLETE strings; the
# parser commits at the OPENING LINE. For multi-line shapes those differ (see
# the prefix-* ids). The Go table deliberately cites the corpus id whose
# measurement matches what the parser actually sees, so a straight comparison
# is correct ONLY because each row names the right id. An id naming the wrong
# measurement is exactly the bug this catches.
#
# Fail-closed: a missing sh checkout, an unreadable table, or zero extracted
# rows is a FAILURE, never a silent pass.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
baseline="$here/baseline.tsv"
sh_dir="${SH_DIR:-$here/../../../sh}"
gotable="$sh_dir/syntax/bashpp_startsites_test.go"

die() { printf 'startsites: DAY1 TABLE FAIL — %s\n' "$*" >&2; exit 1; }

[ -f "$baseline" ] || die "no baseline.tsv; run classify.sh first"
[ -f "$gotable" ]  || die "no Go table at $gotable (set SH_DIR to the sh checkout)"

# Extract {"corpus-id", ..., StartX, ClassY} rows from the Go table.
rows=$(sed -n 's/^[[:space:]]*{"\([a-z0-9-]*\)".*\(Start[A-Za-z]*\), \(Class[RE]\)},$/\1\t\3/p' "$gotable")
n=$(printf '%s' "$rows" | grep -c . || true)
[ "$n" -gt 0 ] || die "extracted ZERO rows from the Go table; the parser in this script is stale, which would otherwise pass vacuously"

fails=0
checked=0
while IFS=$'\t' read -r id goclass; do
	[ -n "$id" ] || continue
	# class column is 4; id is column 1
	measured=$(awk -F'\t' -v want="$id" '$1==want {print $4; found=1} END{if(!found) print "MISSING"}' "$baseline")
	case "$measured" in
	MISSING)
		printf '  MISSING   %-28s cited by the Go table but absent from the corpus\n' "$id"
		fails=$((fails + 1))
		;;
	*)
		want=${goclass#Class} # ClassR -> R
		if [ "$measured" != "$want" ]; then
			printf '  MISMATCH  %-28s corpus=%s go=%s\n' "$id" "$measured" "$want"
			fails=$((fails + 1))
		fi
		;;
	esac
	checked=$((checked + 1))
done <<< "$rows"

if [ "$fails" -gt 0 ]; then
	die "$fails of $checked Day-1 rows disagree with the corpus"
fi

printf 'startsites: DAY1 TABLE OK — %d rows agree with the corpus\n' "$checked"
