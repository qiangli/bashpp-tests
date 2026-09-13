#!/usr/bin/env bash
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Self-tests of the Go port: the comparator, JSON and validator unit tests in
# tools/go-by-example/gbe/*_test.go, run with the pinned toolchain build.sh
# resolves. The retained-evidence suites are separate subcommands
# (`gbe.sh tamper-retained-evidence EVIDENCE`, `gbe.sh bounded-evidence-selftests`)
# because they need retained evidence trees this repository does not carry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"${ROOT}/tools/go-by-example/build.sh" >/dev/null
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "${arch}" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
version="$(awk -F '\t' -v os="${os}" -v arch="${arch}" '$1 !~ /^#/ && $1 == os && $2 == arch { print $3; exit }' "${ROOT}/docs/go-by-example/toolchain.tsv")"
GO="$(GOTOOLCHAIN="${version}" go env GOROOT)/bin/go"
cd "${ROOT}/tools/go-by-example/gbe"
GBE_ROOT="${ROOT}" GOTOOLCHAIN=local GOFLAGS= GOWORK=off exec "${GO}" test "$@" .
