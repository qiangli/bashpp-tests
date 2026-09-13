#!/usr/bin/env bash
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Build tools/go-by-example/gbe -- the one Go program behind every wrapper in
# this directory -- with the pinned Go toolchain, the same way the gate builds
# launch.go: the release named in docs/go-by-example/toolchain.tsv for this
# host is resolved through `GOTOOLCHAIN=<version> go env GOROOT` and its own
# bin/go does the build with GOTOOLCHAIN=local. Prints the binary path. The
# build is skipped while the sources and the pinned version are unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${ROOT}/tools/go-by-example/gbe"
OUT_DIR="${ROOT}/.cache/go-by-example/bin"
OUT="${OUT_DIR}/gbe"

die() { echo "FATAL: $*" >&2; exit 2; }

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "${arch}" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
esac
version="$(awk -F '\t' -v os="${os}" -v arch="${arch}" '$1 !~ /^#/ && $1 == os && $2 == arch { print $3; exit }' "${ROOT}/docs/go-by-example/toolchain.tsv")"
[ -n "${version}" ] || die "no authenticated Go toolchain pin for ${os}/${arch}"
command -v go >/dev/null 2>&1 || die "go is not on PATH; the pinned ${version} toolchain cannot be resolved"
GOROOT_PINNED="$(GOTOOLCHAIN="${version}" go env GOROOT)" || die "cannot resolve pinned Go toolchain ${version}"
# The resolved bin/go must carry the reviewed digest; a same-version
# distribution build on PATH is not the pinned SDK, so the toolchain module
# GOTOOLCHAIN itself would select is tried next (digest still required).
pinned_sha="$(awk -F '\t' -v os="${os}" -v arch="${arch}" '$1 !~ /^#/ && $1 == os && $2 == arch { print $5; exit }' "${ROOT}/docs/go-by-example/toolchain.tsv")"
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'; }
if [ "$(sha_of "${GOROOT_PINNED}/bin/go")" != "${pinned_sha}" ]; then
  module="$(GOTOOLCHAIN=local go env GOMODCACHE)/golang.org/toolchain@v0.0.1-${version}.${os}-${arch}"
  [ "$(sha_of "${module}/bin/go")" = "${pinned_sha}" ] || die "no Go toolchain with the reviewed ${version} digest ${pinned_sha}: ${GOROOT_PINNED}/bin/go"
  GOROOT_PINNED="${module}"
fi
GO="${GOROOT_PINNED}/bin/go"
[ -x "${GO}" ] || die "pinned Go toolchain has no bin/go: ${GOROOT_PINNED}"

stamp="$( (cd "${SRC}" && printf '%s\n' "${version}" && cat go.mod ./*.go) | shasum -a 256 | awk '{ print $1 }')"
if [ -x "${OUT}" ] && [ "$(cat "${OUT}.stamp" 2>/dev/null || true)" = "${stamp}" ]; then
  printf '%s\n' "${OUT}"
  exit 0
fi
mkdir -p "${OUT_DIR}"
tmp="${OUT}.tmp.$$"
( cd "${SRC}" && env GOTOOLCHAIN=local GOFLAGS= GOWORK=off "${GO}" build -trimpath -o "${tmp}" . ) >&2 \
  || die "cannot build tools/go-by-example/gbe with ${version}"
mv "${tmp}" "${OUT}"
printf '%s\n' "${stamp}" > "${OUT}.stamp"
printf '%s\n' "${OUT}"
