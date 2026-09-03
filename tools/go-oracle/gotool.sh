#!/usr/bin/env bash
# Print the path of the pinned Go toolchain's `go` binary.
#
# The oracle must be driven by the same release the corpus was pinned to;
# running one release's tests through another release's compiler produces a
# number, not an oracle. Resolution is explicit and fails loudly rather than
# falling back to whatever `go` happens to be on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/go-oracle/pin.tsv"

die() { echo "FATAL: $*" >&2; exit 2; }

release="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1; exit }' "${PIN}")"
[ -n "${release}" ] || die "cannot read the oracle pin: ${PIN}"

if [ -n "${GO_ORACLE_GOTOOL:-}" ]; then
  [ -x "${GO_ORACLE_GOTOOL}" ] || die "GO_ORACLE_GOTOOL is not executable: ${GO_ORACLE_GOTOOL}"
  printf '%s\n' "${GO_ORACLE_GOTOOL}"
  exit 0
fi

HOST_GO="${GO:-go}"
command -v "${HOST_GO}" >/dev/null 2>&1 || die "no host go on PATH; set GO or GO_ORACLE_GOTOOL"

gomodcache="$("${HOST_GO}" env GOMODCACHE)"
goos="$("${HOST_GO}" env GOHOSTOS)"
goarch="$("${HOST_GO}" env GOHOSTARCH)"
gotool="${gomodcache}/golang.org/toolchain@v0.0.1-${release}.${goos}-${goarch}/bin/go"

if [ ! -x "${gotool}" ] && [ "${GO_ORACLE_FETCH:-0}" = 1 ]; then
  # Explicit, networked and opt-in — the same shape as tools/go-corpus/refresh.sh.
  GOTOOLCHAIN="${release}" "${HOST_GO}" version >/dev/null || die "cannot provision ${release}"
fi

if [ ! -x "${gotool}" ]; then
  # The host go may itself already BE the pinned release.
  host_version="$("${HOST_GO}" version | awk '{print $3}')"
  if [ "${host_version}" = "${release}" ]; then
    command -v "${HOST_GO}"
    exit 0
  fi
  echo "FATAL: the pinned toolchain ${release} is not available" >&2
  echo "  looked for: ${gotool}" >&2
  echo "  host go is: ${host_version}" >&2
  echo "  Re-run with GO_ORACLE_FETCH=1 to download it (networked), or point" >&2
  echo "  GO_ORACLE_GOTOOL at a ${release} go binary." >&2
  exit 2
fi

printf '%s\n' "${gotool}"
