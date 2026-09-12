#!/usr/bin/env bash
# Builds the tools/tour Go harness (`tour`) with the pinned Go toolchain and
# prints the binary path. Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
#
# Resolution mirrors the way tools/go-by-example/launch.go is built by its
# gate: `GOTOOLCHAIN=<pinned version> go env GOROOT` names the SDK
# (docs/tour/toolchain.tsv), and `<GOROOT>/bin/go build` with GOTOOLCHAIN=local
# compiles the package. The binary lives under the repository's .cache so a
# clean checkout carries only sources. Every tools/tour/*.sh wrapper sources
# this file and execs the binary.
set -euo pipefail
TOUR_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOUR_BIN="${TOUR_ROOT_DIR}/.cache/tour/bin/tour"

tour_pinned_version() {
  local goos goarch
  goos="$(uname -s | tr '[:upper:]' '[:lower:]')"
  goarch="$(uname -m)"
  awk -F '\t' -v goos="${goos}" -v goarch="${goarch}" \
    '$1 !~ /^#/ && NF && $1 == goos && $2 == goarch { print $3; found = 1; exit } END { if (!found) exit 1 }' \
    "${TOUR_ROOT_DIR}/docs/tour/toolchain.tsv" \
    || awk -F '\t' '$1 !~ /^#/ && NF { print $3; exit }' "${TOUR_ROOT_DIR}/docs/tour/toolchain.tsv"
}

tour_build() {
  command -v go >/dev/null 2>&1 || { echo "FATAL: go is not on PATH; the pinned Go toolchain is required to build tools/tour" >&2; return 2; }
  local version goroot gobin
  version="$(tour_pinned_version)"
  goroot="$(GOTOOLCHAIN="${version}" go env GOROOT 2>/dev/null || true)"
  [ -n "${goroot}" ] || { echo "FATAL: cannot resolve GOROOT for ${version}" >&2; return 2; }
  gobin="${goroot}/bin/go"
  [ -x "${gobin}" ] || { echo "FATAL: pinned Go binary missing at ${gobin}" >&2; return 2; }
  mkdir -p "$(dirname "${TOUR_BIN}")"
  ( cd "${TOUR_ROOT_DIR}/tools/tour" && GOTOOLCHAIN=local GOWORK=off GOFLAGS= "${gobin}" build -o "${TOUR_BIN}" . ) \
    || { echo "FATAL: cannot build tools/tour with ${gobin}" >&2; return 2; }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  tour_build
  echo "${TOUR_BIN}"
fi
