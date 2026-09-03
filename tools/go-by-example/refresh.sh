#!/usr/bin/env bash
# Re-derive docs/go-by-example/inventory.tsv from the authored classification
# table plus the measured bytes of the copied corpus.
#
#   refresh.sh [--inventory-only] [GBE_ROOT]
#
# The inventory is a pure function of (classification.tsv, copied file bytes).
# With GBE_ROOT — a clone of mmcgrana/gobyexample checked out at the pinned
# commit — the script additionally proves the copy against upstream: it derives
# the upstream `examples/**/*.go` set, checks it against the classification
# table's program rows, and byte-compares every copied file with its source.
#
# --inventory-only writes the derived inventory to stdout, which is how
# validate.sh diffs a re-derivation against the checked-in file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS="${ROOT}/docs/go-by-example"
CLS="${DOCS}/classification.tsv"
PIN="${DOCS}/pin.tsv"

die() { echo "FATAL: $*" >&2; exit 2; }

to_stdout=0
gbe_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inventory-only) to_stdout=1 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "${gbe_root}" ] || die "at most one GBE_ROOT may be given"; gbe_root="$1" ;;
  esac
  shift
done

[ -f "${CLS}" ] || die "missing classification table: ${CLS}"
[ -f "${PIN}" ] || die "missing pin: ${PIN}"

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r repo commit observed license _provenance _cls_rows _inv_rows _inv_sha _upstream_go <<<"${pin_row}"
[ -n "${commit:-}" ] || die "pin has no commit"

sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

if [ -n "${gbe_root}" ]; then
  [ -d "${gbe_root}" ] || die "GBE_ROOT is not a directory: ${gbe_root}"
  [ -d "${gbe_root}/examples" ] || die "GBE_ROOT has no examples/ tree: ${gbe_root}"
  [ -f "${gbe_root}/README.md" ] || die "GBE_ROOT has no README.md (license provenance)"
  if command -v git >/dev/null 2>&1 && [ -d "${gbe_root}/.git" ]; then
    actual="$(git -C "${gbe_root}" rev-parse HEAD)"
    [ "${actual}" = "${commit}" ] || die "GBE_ROOT commit mismatch: expected ${commit}, got ${actual}"
  fi

  upstream_go="$(cd "${gbe_root}" && find examples -type f -name '*.go' | LC_ALL=C sort)"
  classified_go="$(awk -F '\t' '$1 !~ /^#/ && NF && ($2 == "program" || $2 == "test_program") { print $1 }' "${CLS}")"
  diff <(printf '%s\n' "${upstream_go}") <(printf '%s\n' "${classified_go}") >/dev/null \
    || die "upstream examples/**/*.go set differs from the classified program rows (< upstream, > classification):
$(diff <(printf '%s\n' "${upstream_go}") <(printf '%s\n' "${classified_go}") || true)"

  while IFS=$'\t' read -r path kind _b _n _a _r; do
    case "${path}" in ''|\#*) continue ;; esac
    if [ "${kind}" = provenance ]; then
      src="${gbe_root}/README.md"
    else
      src="${gbe_root}/${path}"
    fi
    [ -f "${src}" ] || die "upstream source missing for ${path}: ${src}"
    [ -f "${ROOT}/${path}" ] || die "corpus copy missing: ${path}"
    cmp -s "${src}" "${ROOT}/${path}" || die "copied bytes differ from upstream: ${path}"
  done < "${CLS}"
fi

emit() {
  printf '# repository\t%s\n' "${repo}"
  printf '# commit\t%s\n' "${commit}"
  printf '# observed\t%s\n' "${observed}"
  printf '# license\t%s\n' "${license}"
  printf '# generated_by\ttools/go-by-example/refresh.sh\n'
  printf '# derived_from\tdocs/go-by-example/classification.tsv\n'
  printf '# path\tkind\tbehavior\tnormalization\tadapter\trequires\tbytes\tsha256\n'
  while IFS=$'\t' read -r path kind behavior normalization adapter requires; do
    case "${path}" in ''|\#*) continue ;; esac
    f="${ROOT}/${path}"
    [ -f "${f}" ] || die "classified path is not a regular file in the corpus: ${path}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${path}" "${kind}" "${behavior}" "${normalization}" "${adapter}" "${requires}" \
      "$(wc -c <"${f}" | tr -d ' ')" "$(sha256_of "${f}")"
  done < "${CLS}"
}

if [ "${to_stdout}" -eq 1 ]; then
  emit
else
  tmp="$(mktemp)"
  emit > "${tmp}"
  mv "${tmp}" "${DOCS}/inventory.tsv"
  echo "wrote ${DOCS}/inventory.tsv"
fi
