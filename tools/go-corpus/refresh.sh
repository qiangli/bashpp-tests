#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/go-corpus/pin.tsv"
OUT="${ROOT}/docs/go-corpus/inventory.tsv"
CACHE="${GO_CORPUS_CACHE:-${ROOT}/.cache/go-corpus}"

read_pin() {
  awk -F '\t' 'BEGIN { OFS="\t" } $1 !~ /^#/ && NF >= 8 { print; exit }' "${PIN}"
}

pin_row="$(read_pin)"
IFS=$'\t' read -r release kind filename url sha256 expected_count license provenance inventory_data_sha256 <<<"${pin_row}"

archive="${CACHE}/${filename}"
src="${CACHE}/${release}"
tmp="${OUT}.tmp"

mkdir -p "${CACHE}"
if [ ! -f "${archive}" ]; then
  curl -L --fail --show-error --silent "${url}" -o "${archive}"
fi

actual_sha="$(shasum -a 256 "${archive}" | awk '{print $1}')"
if [ "${actual_sha}" != "${sha256}" ]; then
  echo "FATAL: ${filename} sha256 mismatch" >&2
  echo "  expected ${sha256}" >&2
  echo "  actual   ${actual_sha}" >&2
  exit 2
fi

rm -rf "${src}.tmp"
mkdir -p "${src}.tmp"
tar -xzf "${archive}" -C "${src}.tmp" --strip-components=1
rm -rf "${src}"
mv "${src}.tmp" "${src}"

if [ ! -f "${src}/LICENSE" ]; then
  echo "FATAL: extracted Go source is missing LICENSE" >&2
  exit 2
fi

{
  printf '# release\t%s\n' "${release}"
  printf '# source\t%s\n' "${url}"
  printf '# source_sha256\t%s\n' "${sha256}"
  printf '# license\t%s\n' "${license}"
  printf '# generated_by\ttools/go-corpus/refresh.sh\n'
  printf '# path\taction\tbytes\tsha256\n'
  while IFS= read -r file; do
    rel="${file#"${src}/"}"
    action="$(sed -n '1,10p' "${file}" | awk '/^\/\/[[:space:]]*(run|build|errorcheck|compile|compiledir|rundir)/ { sub("^//[[:space:]]*", "", $0); print $1; exit }')"
    [ -n "${action}" ] || action="none"
    bytes="$(wc -c < "${file}" | tr -d ' ')"
    digest="$(shasum -a 256 "${file}" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\n' "${rel}" "${action}" "${bytes}" "${digest}"
  done < <(find "${src}/test" -type f -name '*.go' | sort)
} > "${tmp}"

mv "${tmp}" "${OUT}"
actual_inventory_data_sha256="$(awk '$0 !~ /^#/ && NF' "${OUT}" | shasum -a 256 | awk '{print $1}')"
if [ "${actual_inventory_data_sha256}" != "${inventory_data_sha256}" ]; then
  echo "FATAL: refreshed inventory data sha256 differs from reviewed pin" >&2
  echo "  expected ${inventory_data_sha256}" >&2
  echo "  actual   ${actual_inventory_data_sha256}" >&2
  exit 2
fi
GO_CORPUS_ROOT="${src}" "${ROOT}/tools/go-corpus/validate.sh"
