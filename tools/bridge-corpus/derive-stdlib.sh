#!/usr/bin/env bash
# derive-stdlib.sh — derive the actual Go stdlib package list exposed by the
# bash++ import bridge, from the sh source tree that implements the bridge.
#
# WHAT THIS DERIVES (and nothing else):
#
#   1. The reviewed import inventory: every entry of go127StdlibImports in
#      sh/syntax/go127stdlib_generated.go, whose joined list must hash to the
#      reviewed inventorySHA256 constant in sh/syntax/gen_go127stdlib.go.
#      That inventory is what the parser accepts and what the interpreter's
#      BashPPStdlibImportAllowed predicate checks — it IS the exposed list.
#
#   2. The per-package runtime capability classification: the same `go list
#      -e -json` facts (interp/bashpp_import.go bashPPPackageFacts) and the
#      same classification order (interp/bashpp_eval.go
#      classifyBashPPPackage) and decision table (bashPPPolicyFor), executed
#      under the pinned Go 1.27.0 toolchain whose identity is verified the
#      way sh's runtime verifies it (bin/go digest from sh's own review
#      table; sum.golang.org ziphash; src/ tree hash).
#
# The output stdlib-inventory.tsv therefore answers: of the 180 reviewed
# packages, which classify capReviewedStdlib (import allowed through the
# bridge on THIS host), and which are refused, with the refusal class
# derived from sh's own code — never invented here.
#
# This script claims NOTHING about bridge behaviour. Classification is the
# precondition of execution, not evidence of it. Nothing is executed through
# the bridge by this script.
#
# Usage:
#   BRIDGE_SH_ROOT=/path/to/sh  tools/bridge-corpus/derive-stdlib.sh
#
# BRIDGE_SH_ROOT defaults to ../sh relative to this repository (umbrella
# layout). BRIDGE_GO_ROOT may override the pinned toolchain root (it must
# pass the same digest review; there is no way to skip the review).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${ROOT}/docs/bridge-corpus"
OUT="${OUT_DIR}/stdlib-inventory.tsv"
PIN="${OUT_DIR}/bridge-pin.tsv"

SH_ROOT="${BRIDGE_SH_ROOT:-${ROOT}/../sh}"
SH_GEN="${SH_ROOT}/syntax/go127stdlib_generated.go"
SH_GEN_SRC="${SH_ROOT}/syntax/gen_go127stdlib.go"
SH_REVIEWS="${SH_ROOT}/interp/bashpp_import.go"
SH_EVAL="${SH_ROOT}/interp/bashpp_eval.go"

die() {
  echo "FATAL: $*" >&2
  exit 2
}

for f in "${SH_GEN}" "${SH_GEN_SRC}" "${SH_REVIEWS}" "${SH_EVAL}"; do
  [ -f "${f}" ] || die "missing sh bridge source: ${f} (set BRIDGE_SH_ROOT)"
done

# ---- 1. extract the reviewed inventory and its review constants from sh ----

sh_commit="$(git -C "${SH_ROOT}" rev-parse HEAD 2>/dev/null || echo untracked-sh)"
sh_dirty="$(git -C "${SH_ROOT}" status --porcelain -- syntax/go127stdlib_generated.go syntax/gen_go127stdlib.go interp/bashpp_import.go interp/bashpp_eval.go 2>/dev/null | wc -l | tr -d ' ')"

toolchain_version="$(sed -n 's/^[[:space:]]*toolchainVersion = "\([^"]*\)".*/\1/p' "${SH_GEN_SRC}" | head -1)"
source_sha256="$(sed -n 's/^[[:space:]]*sourceSHA256[[:space:]]*=[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "${SH_GEN_SRC}" | head -1)"
inventory_sha256="$(sed -n 's/^[[:space:]]*inventorySHA256 = "\([0-9a-f]*\)".*/\1/p' "${SH_GEN_SRC}" | head -1)"
generated_source_sha="$(sed -n 's/^const go127StdlibSourceSHA256 = "\([0-9a-f]*\)".*/\1/p' "${SH_GEN}" | head -1)"

[ -n "${toolchain_version:-}" ] || die "could not read toolchainVersion from ${SH_GEN_SRC}"
[ -n "${source_sha256:-}" ] || die "could not read sourceSHA256 from ${SH_GEN_SRC}"
[ -n "${inventory_sha256:-}" ] || die "could not read inventorySHA256 from ${SH_GEN_SRC}"
[ -n "${generated_source_sha:-}" ] || die "could not read go127StdlibSourceSHA256 from ${SH_GEN}"
[ "${generated_source_sha}" = "${source_sha256}" ] || \
  die "sh generated file and generator disagree on the reviewed src tree hash"

tmp_list="$(mktemp)"
trap 'rm -rf "${tmp_list}"' EXIT
awk '/^[[:space:]]*"/{gsub(/^[[:space:]]*"|",?[[:space:]]*$/, ""); print}' "${SH_GEN}" > "${tmp_list}"
rows="$(wc -l < "${tmp_list}" | tr -d ' ')"
[ "${rows}" -gt 0 ] || die "extracted an empty inventory from ${SH_GEN}"
case "$(sort "${tmp_list}" | uniq -d)" in "") ;; *) die "duplicate entries in extracted inventory" ;; esac
sort -c "${tmp_list}" || die "extracted inventory is not sorted"

# ---- 2. locate the pinned toolchain and verify it the way sh's runtime does ----

if [ -n "${BRIDGE_GO_ROOT:-}" ]; then
  go_root="${BRIDGE_GO_ROOT}"
else
  command -v go >/dev/null 2>&1 || die "no bootstrap go on PATH to resolve GOTOOLCHAIN=${toolchain_version}"
  go_root="$(GOTOOLCHAIN="${toolchain_version}" go env GOROOT)"
fi
[ -n "${go_root}" ] || die "could not resolve the pinned toolchain root"
go_bin="${go_root}/bin/go"
[ -x "${go_bin}" ] || die "pinned toolchain has no executable bin/go: ${go_bin}"

goos="$(GOROOT="${go_root}" "${go_bin}" env GOOS)"
goarch="$(GOROOT="${go_root}" "${go_bin}" env GOARCH)"

# Review row from sh's own table (interp/bashpp_import.go bashPPGoReviews).
review_sha="$(sed -n "s/.*{Version: \"${toolchain_version}\", GOOS: \"${goos}\", GOARCH: \"${goarch}\", SHA256: \"\([0-9a-f]*\)\"}.*/\1/p" "${SH_REVIEWS}" | head -1)"
[ -n "${review_sha}" ] || die "sh review table has no ${toolchain_version} ${goos}/${goarch} row"
actual_bin_sha="$(shasum -a 256 "${go_bin}" | awk '{print $1}')"
[ "${actual_bin_sha}" = "${review_sha}" ] || \
  die "bin/go digest ${actual_bin_sha} is not the reviewed ${review_sha}"

# Module ziphash (sum.golang.org attestation) from sh's generator moduleSums.
ziphash_want="$(sed -n "s/.*\"${goos}-${goarch}\": \"\(h1:[^\"]*\)\".*/\1/p" "${SH_GEN_SRC}" | head -1)"
[ -n "${ziphash_want}" ] || die "sh generator has no reviewed module sum for ${goos}-${goarch}"
modcache="$(GOROOT="${go_root}" "${go_bin}" env GOMODCACHE)"
ziphash_file="${modcache}/cache/download/golang.org/toolchain/@v/v0.0.1-${toolchain_version}.${goos}-${goarch}.ziphash"
[ -f "${ziphash_file}" ] || die "missing authenticated module ziphash: ${ziphash_file}"
ziphash_got="$(tr -d '[:space:]' < "${ziphash_file}")"
[ "${ziphash_got}" = "${ziphash_want}" ] || \
  die "module ziphash ${ziphash_got} is not the reviewed ${ziphash_want}"

# The joined-list digest must equal the reviewed inventorySHA256 of sh's
# generator; this proves the extraction is byte-exact, not approximate.
list_data_sha="$("${go_bin}" run "${ROOT}/tools/bridge-corpus/bridgecorpus.go" listsha "${tmp_list}")"
[ "${list_data_sha}" = "${inventory_sha256}" ] || \
  die "extracted inventory hash ${list_data_sha} is not the reviewed ${inventory_sha256}"

# src/ tree hash, with the exact framing of sh's generator.
tree_sha="$("${go_bin}" run "${ROOT}/tools/bridge-corpus/bridgecorpus.go" treehash "${go_root}/src")"
[ "${tree_sha}" = "${source_sha256}" ] || \
  die "toolchain src/ tree hash ${tree_sha} is not the reviewed ${source_sha256}"

# ---- 3. per-package facts and capability classification ----

work="$(mktemp -d)"
trap 'rm -rf "${work}" "${tmp_list}"' EXIT

# The runtime runs `go list -e -json` per import (bashPPGoListFacts). Facts
# are per package and independent; batching is a derivation speedup only and
# the classifier is the runtime's own order.
( cd "${work}" && GOROOT="${go_root}" "${go_bin}" list -e -json $(tr '\n' ' ' < "${tmp_list}") ) > "${work}/facts.json"

"${go_bin}" run "${ROOT}/tools/bridge-corpus/bridgecorpus.go" classify "${tmp_list}" < "${work}/facts.json" > "${work}/rows.tsv"

classified="$(wc -l < "${work}/rows.tsv" | tr -d ' ')"
[ "${classified}" = "${rows}" ] || \
  die "classified ${classified} packages but the reviewed inventory has ${rows}"

# ---- 4. write the inventory and the pin ----

mkdir -p "${OUT_DIR}"
data_sha="$(grep -v '^#' "${work}/rows.tsv" | shasum -a 256 | awk '{print $1}')"

{
  printf '# Bridge-exposed Go standard library inventory, derived from sh.\n'
  printf '# Every row is one entry of the reviewed go127StdlibImports inventory\n'
  printf '# (sh/syntax/go127stdlib_generated.go), classified by the runtime rules\n'
  printf '# of sh/interp/bashpp_eval.go under the pinned toolchain on this host.\n'
  printf '#\n'
  printf '# sh_commit\t%s\n' "${sh_commit}"
  printf '# sh_bridge_files_dirty\t%s\n' "${sh_dirty}"
  printf '# go_release\t%s\n' "${toolchain_version}"
  printf '# goos\t%s\n' "${goos}"
  printf '# goarch\t%s\n' "${goarch}"
  printf '# go_bin_sha256\t%s\n' "${actual_bin_sha}"
  printf '# go_src_tree_sha256\t%s\n' "${tree_sha}"
  printf '# inventory_list_sha256\t%s\n' "${list_data_sha}"
  printf '# inventory_rows\t%s\n' "${rows}"
  printf '# data_sha256\t%s\n' "${data_sha}"
  printf '# generated_by\ttools/bridge-corpus/derive-stdlib.sh\n'
  printf '#\n'
  printf '# path\tgo_list_name\tstandard\tgo_files\tcgo_files\tignored_files\tincomplete\terr_len\tcapability\tpolicy\tlist_error\n'
  cat "${work}/rows.tsv"
} > "${OUT}"

{
  printf '# Bridge corpus provenance pin.\n'
  printf '#\n'
  printf '# The sh side: which checkout the exposed-package derivation read, and\n'
  printf '# the digests of the files whose constants anchor the review.\n'
  printf '# The Go side: the pinned toolchain identity, verified three ways\n'
  printf '# (bin/go digest from sh review table, sum.golang.org module ziphash,\n'
  printf '# src/ tree hash) exactly as sh runtime + generator do.\n'
  printf '#\n'
  printf '# key\tvalue\n'
  printf 'sh_commit\t%s\n' "${sh_commit}"
  printf 'sh_go127stdlib_generated\tsyntax/go127stdlib_generated.go\t%s\n' "$(shasum -a 256 "${SH_GEN}" | awk '{print $1}')"
  printf 'sh_gen_go127stdlib\tsyntax/gen_go127stdlib.go\t%s\n' "$(shasum -a 256 "${SH_GEN_SRC}" | awk '{print $1}')"
  printf 'sh_bashpp_import\tinterp/bashpp_import.go\t%s\n' "$(shasum -a 256 "${SH_REVIEWS}" | awk '{print $1}')"
  printf 'sh_bashpp_eval\tinterp/bashpp_eval.go\t%s\n' "$(shasum -a 256 "${SH_EVAL}" | awk '{print $1}')"
  printf 'go_release\t%s\n' "${toolchain_version}"
  printf 'go_module\tgolang.org/toolchain\tv0.0.1-%s.%s-%s\t%s\n' "${toolchain_version}" "${goos}" "${goarch}" "${ziphash_got}"
  printf 'go_bin_sha256\t%s\n' "${actual_bin_sha}"
  printf 'go_src_tree_sha256\t%s\n' "${tree_sha}"
  printf 'inventory_list_sha256\t%s\n' "${list_data_sha}"
  printf 'stdlib_inventory_rows\t%s\n' "${rows}"
  printf 'stdlib_inventory\t%s\t%s\n' "docs/bridge-corpus/stdlib-inventory.tsv" "${data_sha}"
  printf '# upstream-tests artifact rows are filled by inventory-tests.sh\n'
} > "${PIN}"

reviewed_n="$(awk -F '\t' '$1 !~ /^#/ && $9 == "reviewed-stdlib"' "${OUT}" | wc -l | tr -d ' ')"
echo "Bridge stdlib inventory OK: ${rows} reviewed packages, ${reviewed_n} classify reviewed-stdlib on ${goos}/${goarch}"
echo "  wrote ${OUT}"
echo "  wrote ${PIN}"
