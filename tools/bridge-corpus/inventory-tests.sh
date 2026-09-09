#!/usr/bin/env bash
# inventory-tests.sh — inventory the upstream Go 1.27.0 standard-library
# *_test.go files belonging to the bridge-exposed package set.
#
# SCOPE RULE (no exclusions invented):
#   every one of the 180 rows of docs/bridge-corpus/stdlib-inventory.tsv —
#   i.e. every entry of sh's reviewed go127StdlibImports inventory — has its
#   package directory in the pinned Go source scanned for *_test.go files
#   (files directly in the package directory: exactly the set `go test
#   <pkg>` compiles, in-package plus black-box). Refused packages (cgo,
#   not-buildable on this host) are inventoried like everything else; their
#   test files are counted, not dropped. Nothing is excluded; capability
#   classification lives in the stdlib-inventory, joined by path.
#
# Per file, all facts are mechanical: package clause, black-box vs
# in-package kind, byte size, sha256, counts of Test/Benchmark/Example/Fuzz
# entrypoints, internal-package imports, build-constraint presence.
#
# Like every tool in this slice, this inventories. It executes nothing and
# claims nothing about bridge behaviour.
#
# Requires the same pinned toolchain verification as derive-stdlib.sh (the
# source tree is read out of the authenticated toolchain module, and its
# src/ tree hash must still equal sh's reviewed constant).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${ROOT}/docs/bridge-corpus"
INV="${OUT_DIR}/stdlib-inventory.tsv"
OUT="${OUT_DIR}/upstream-tests.tsv"
PIN="${OUT_DIR}/bridge-pin.tsv"

SH_ROOT="${BRIDGE_SH_ROOT:-${ROOT}/../sh}"
SH_GEN_SRC="${SH_ROOT}/syntax/gen_go127stdlib.go"

die() {
  echo "FATAL: $*" >&2
  exit 2
}

[ -f "${INV}" ] || die "missing ${INV}; run tools/bridge-corpus/derive-stdlib.sh first"
[ -f "${SH_GEN_SRC}" ] || die "missing sh generator source: ${SH_GEN_SRC} (set BRIDGE_SH_ROOT)"

# ---- pinned toolchain, verified exactly as in derive-stdlib.sh ----

toolchain_version="$(sed -n 's/^[[:space:]]*toolchainVersion = "\([^"]*\)".*/\1/p' "${SH_GEN_SRC}" | head -1)"
source_sha256="$(sed -n 's/^[[:space:]]*sourceSHA256[[:space:]]*=[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "${SH_GEN_SRC}" | head -1)"
[ -n "${toolchain_version:-}" ] || die "could not read toolchainVersion from ${SH_GEN_SRC}"
[ -n "${source_sha256:-}" ] || die "could not read sourceSHA256 from ${SH_GEN_SRC}"

if [ -n "${BRIDGE_GO_ROOT:-}" ]; then
  go_root="${BRIDGE_GO_ROOT}"
else
  command -v go >/dev/null 2>&1 || die "no bootstrap go on PATH to resolve GOTOOLCHAIN=${toolchain_version}"
  go_root="$(GOTOOLCHAIN="${toolchain_version}" go env GOROOT)"
fi
go_bin="${go_root}/bin/go"
[ -x "${go_bin}" ] || die "pinned toolchain has no executable bin/go: ${go_bin}"

tree_sha="$("${go_bin}" run "${ROOT}/tools/bridge-corpus/bridgecorpus.go" treehash "${go_root}/src")"
[ "${tree_sha}" = "${source_sha256}" ] || \
  die "toolchain src/ tree hash ${tree_sha} is not the reviewed ${source_sha256}"

# ---- inventory every reviewed package's *_test.go files ----

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

"${go_bin}" run "${ROOT}/tools/bridge-corpus/bridgecorpus.go" testfacts "${go_root}/src" "${INV}" \
  | LC_ALL=C sort > "${work}/rows.tsv"

rows="$(wc -l < "${work}/rows.tsv" | tr -d ' ')"
[ "${rows}" -gt 0 ] || die "testfacts produced zero rows"
LC_ALL=C sort -c "${work}/rows.tsv" || die "rows are not in byte order"

data_sha="$(grep -v '^#' "${work}/rows.tsv" | shasum -a 256 | awk '{print $1}')"

{
  printf '# Upstream Go standard-library test-file inventory for the bridge-exposed set.\n'
  printf '# One row per *_test.go file directly inside each reviewed package directory\n'
  printf '# of the pinned %s source. All 180 reviewed packages are scanned; no\n' "${toolchain_version}"
  printf '# package and no file is excluded. Refused-capability packages are inventoried\n'
  printf '# identically — capability lives in stdlib-inventory.tsv, joined by path.\n'
  printf '#\n'
  printf '# go_release\t%s\n' "${toolchain_version}"
  printf '# go_src_tree_sha256\t%s\n' "${tree_sha}"
  printf '# license\tBSD-3-Clause\n'
  printf '# rows\t%s\n' "${rows}"
  printf '# data_sha256\t%s\n' "${data_sha}"
  printf '# generated_by\ttools/bridge-corpus/inventory-tests.sh\n'
  printf '#\n'
  printf '# path\tpackage_clause\tkind\tbytes\tsha256\ttests\tbenchmarks\texamples\tfuzz_targets\tinternal_imports\tbuild_constraint\n'
  cat "${work}/rows.tsv"
} > "${OUT}"

# Record the artifact in the pin (same file, keyed rows, idempotent rewrite).
pin_tmp="${work}/pin.tsv"
awk -F '\t' -v OFS='\t' '
  $1 == "upstream_tests_rows" || $1 == "upstream_tests" { next }
  /^# upstream-tests artifact rows are filled by inventory-tests.sh/ { next }
  { print }
' "${PIN}" > "${pin_tmp}"
{
  cat "${pin_tmp}"
  printf 'upstream_tests_rows\t%s\n' "${rows}"
  printf 'upstream_tests\t%s\t%s\n' "docs/bridge-corpus/upstream-tests.tsv" "${data_sha}"
} > "${PIN}"

kind_summary="$(awk -F '\t' '$1 !~ /^#/ && NF { k[$3]++ } END { for (t in k) printf "%s=%d ", t, k[t]; print "" }' "${OUT}")"
echo "Upstream test inventory OK: ${rows} *_test.go files across 180 reviewed packages"
echo "  kinds: ${kind_summary}"
echo "  wrote ${OUT}"
echo "  updated ${PIN}"
