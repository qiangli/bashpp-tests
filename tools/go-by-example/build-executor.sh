#!/usr/bin/env bash
# Reproduce and independently verify the reviewed Sprint 98 Bash++ executor.
#
# The executor is bound to the SAME pinned Go toolchain as the oracle, so a
# passing gate cannot be assembled from a Go 1.27 oracle plus an executor that
# was actually built by some other (e.g. Go 1.26) compiler. Both the reviewed
# pin and the resolved builder are checked against docs/go-by-example/
# toolchain.tsv, and the build itself runs the pinned toolchain directly with
# GOTOOLCHAIN=local so nothing can re-dispatch to a different release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${GBE_EXECUTOR_PIN:-$ROOT/docs/go-by-example/executor.tsv}"
TOOLCHAIN="${GBE_TOOLCHAIN:-$ROOT/docs/go-by-example/toolchain.tsv}"
SOURCE="${BASHY_SOURCE:-}"
OUT="${1:-$ROOT/.cache/go-by-example/executor/bash}"
die() { echo "FATAL: $*" >&2; exit 2; }

IFS=$'\t' read -r tos tarch tversion tidentity tgosha < <(awk -F '\t' '$1 !~ /^#/ && NF {print; exit}' "$TOOLCHAIN")
[ -n "${tversion:-}" ] && [ -n "${tidentity:-}" ] && [ -n "${tgosha:-}" ] || die "toolchain pin is unreadable"
case "$tversion" in go1.27.*) ;; *) die "reviewed toolchain pin is $tversion, not a Go 1.27 release" ;; esac

IFS=$'\t' read -r os arch want repo commit tree go_identity recipe < <(awk -F '\t' '$1 !~ /^#/ && NF {print; exit}' "$PIN")
[ "$os" = "$tos" ] && [ "$arch" = "$tarch" ] || die "executor pin and toolchain pin describe different hosts"
# A Go 1.26 provenance record is rejected here, before anything is built.
[ "$go_identity" = "$tidentity" ] \
  || die "executor pin was built by '$go_identity', but the reviewed toolchain is '$tidentity'"

# Resolve the pinned toolchain by version and authenticate it by digest. An
# ambient go1.26 on PATH is only ever used to perform this resolution.
goroot="$(GOTOOLCHAIN="$tversion" go env GOROOT)" || die "cannot resolve pinned Go toolchain $tversion"
GO="$goroot/bin/go"
[ -x "$GO" ] || die "resolved Go toolchain has no executable at $GO"
[ "$("$GO" version)" = "$tidentity" ] || die "resolved builder is '$("$GO" version)', not the reviewed '$tidentity'"
[ "$(head -n 1 "$goroot/VERSION")" = "$tversion" ] || die "resolved GOROOT is not the $tversion release source"
got_go="$(shasum -a 256 "$GO" | awk '{print $1}')"
[ "$got_go" = "$tgosha" ] || die "pinned Go binary digest $got_go differs from reviewed $tgosha"
[ "$(GOTOOLCHAIN=local "$GO" env GOOS)" = "$os" ] && [ "$(GOTOOLCHAIN=local "$GO" env GOARCH)" = "$arch" ] \
  || die "executor pin has no row for host"

work="$(mktemp -d "${TMPDIR:-/tmp}/gbe-executor.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ -n "$SOURCE" ]; then
  [ "$(git -C "$SOURCE" rev-parse HEAD)" = "$commit" ] || die "Bashy source commit mismatch"
  [ "$(git -C "$SOURCE" rev-parse HEAD^{tree})" = "$tree" ] || die "Bashy source tree mismatch"
  [ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ] || die "Bashy source is not clean (tracked or untracked files differ)"
  src="$SOURCE"
else
  git clone --quiet "$repo" "$work/src" || die "cannot acquire pinned Bashy source"
  git -C "$work/src" checkout --quiet --detach "$commit" || die "cannot checkout pinned Bashy commit"
  src="$work/src"
fi
# The pinned Bashy tree deliberately uses flat sibling replacements. Its own
# committed sibling manifest is part of the reviewed tree and is therefore the
# authority for acquiring their exact commits in a standalone reproduction.
BASHY= "$src/scripts/bootstrap-siblings.sh" >/dev/null || die "cannot acquire pinned Bashy sibling sources"
# bootstrap-siblings intentionally leaves existing umbrella siblings alone.
# That is convenient for development but cannot be accepted by a reproducible
# artifact builder: every path replacement must be the exact reviewed commit,
# and its tree must contain no tracked or untracked drift.
while IFS= read -r pin_line; do
  case "$pin_line" in ''|'#'*) continue ;; esac
  sibling=${pin_line%%=*}
  sibling_sha=${pin_line#*=}
  sibling_sha=$(printf %s "$sibling_sha" | tr -d '[:space:]')
  sibling_dir="$src/../$sibling"
  [ -d "$sibling_dir" ] || die "pinned Bashy sibling $sibling is missing"
  [ "$(git -C "$sibling_dir" rev-parse HEAD 2>/dev/null)" = "$sibling_sha" ] \
    || die "Bashy sibling $sibling does not match pinned commit $sibling_sha"
  [ -z "$(git -C "$sibling_dir" status --porcelain --untracked-files=all)" ] \
    || die "Bashy sibling $sibling is not clean"
done < "$src/.sibling-pins"
flags="-s -w -buildid= -X github.com/qiangli/bashy/internal/cli.bashVersion=5.3.0(1)-bashy-sprint98 -X github.com/qiangli/bashy/internal/cli.buildID=$commit"
(cd "$src" && GOTOOLCHAIN=local CGO_ENABLED=0 "$GO" build -trimpath -ldflags "$flags" -o "$work/a" ./cmd/bash)
(cd "$src" && GOTOOLCHAIN=local GOCACHE="$work/go-cache-b" CGO_ENABLED=0 "$GO" build -trimpath -ldflags "$flags" -o "$work/b" ./cmd/bash)
cmp -s "$work/a" "$work/b" || die "independent executor builds differ"
got="$(shasum -a 256 "$work/a" | awk '{print $1}')"
[ "$got" = "$want" ] || die "reproduced executor digest $got differs from reviewed $want"
mkdir -p "$(dirname "$OUT")"
cp "$work/a" "$OUT.tmp.$$"
chmod 555 "$OUT.tmp.$$"
mv "$OUT.tmp.$$" "$OUT"
echo "PASS: reproduced twice with $tidentity and installed reviewed executor $want at $OUT"
