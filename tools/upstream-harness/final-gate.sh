#!/bin/sh
# Sprint: #157; Story: S157.4; Story-ID: 5b4efc2910e6
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
harness="$root/tools/upstream-harness"

# The excluded implementation name is assembled so it is absent from the
# Sprint 157 deliverables themselves as well as from their runtime surface.
excluded=$(printf '\162\165\142\171')
active_files=$(find "$root/docs/upstream-harness" "$harness" -type f -print)
active_files="$active_files
$(find "$root/docs/todo" -type f -name '*s157*' -print)"
if printf '%s\n' "$active_files" | while IFS= read -r file; do
	test -n "$file" || continue
	if LC_ALL=C grep -Eiq "$excluded" "$file"; then
		printf '%s\n' "$file"
		exit 1
	fi
done; then :; else
	printf 'FAIL excluded legacy reference remains in the Sprint 157 active surface\n' >&2
	exit 1
fi

for file in $active_files; do
	case "$file" in
		*.go|*.sh|*.tsv|*.md|*.patch|*/LICENSE) ;;
		*) printf 'FAIL unexpected active-surface file type: %s\n' "$file" >&2; exit 1 ;;
	esac
done

for file in "$root"/docs/todo/*.md; do
	sprint=$(sed -n 's/^sprint: //p' "$file")
	case "$sprint" in
		149|150)
			status=$(sed -n 's/^status: //p' "$file")
			test "$status" = todo || {
				printf 'FAIL Sprint %s tracker is no longer blocked in todo: %s (%s)\n' "$sprint" "$file" "$status" >&2
				exit 1
			}
			;;
	esac
done

"$harness/backend-gate.sh"

printf 'GO S157: exact upstream harness, direct-source backend, and minimal observer gates pass\n'
printf 'NO-GO S149/S150: non-run recipes remain explicit unsupported results; trackers remain blocked\n'
