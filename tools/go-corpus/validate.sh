#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/go-corpus/pin.tsv"
INV="${GO_CORPUS_INVENTORY:-${ROOT}/docs/go-corpus/inventory.tsv}"

die() {
  echo "FATAL: $*" >&2
  exit 2
}

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r release kind filename url sha256 expected_count license provenance <<<"${pin_row}"

[ -n "${release:-}" ] || die "missing corpus pin"
[ "${kind:-}" = source ] || die "pin kind must be source"
[ "${filename:-}" = "${release}.src.tar.gz" ] || die "pin filename does not match release"
[ "${url:-}" = "https://go.dev/dl/${filename}" ] || die "pin URL is not the official Go download URL"
case "${release}" in go1.27.*) ;; *) die "pin release must be a reviewed Go 1.27 release: ${release}" ;; esac
case "${sha256:-}" in *[!0-9a-f]*|'') die "pin sha256 must be lowercase hex" ;; esac
[ "${#sha256}" -eq 64 ] || die "pin sha256 must be 64 hex characters"
case "${expected_count:-}" in ''|*[!0-9]*) die "pin test_go_files must be an integer" ;; esac
[ "${expected_count}" -gt 0 ] || die "pin test_go_files must be positive"
[ "${license:-}" = BSD-3-Clause ] || die "pin license must preserve upstream BSD-3-Clause provenance"
[ -n "${provenance:-}" ] || die "pin provenance is required"

[ -f "${INV}" ] || die "missing Go corpus inventory: ${INV}"

expect_header() {
  local key="$1" want="$2" got
  got="$(awk -F '\t' -v key="# ${key}" '$1 == key { print $2; found=1; exit } END { if (!found) exit 1 }' "${INV}")" \
    || die "inventory missing # ${key} header"
  [ "${got}" = "${want}" ] || die "inventory # ${key} header mismatch: expected ${want}, got ${got}"
}

expect_header release "${release}"
expect_header source "${url}"
expect_header source_sha256 "${sha256}"
expect_header license "${license}"
expect_header generated_by "tools/go-corpus/refresh.sh"

rows="$(awk -F '\t' '$1 !~ /^#/ && NF { count++ } END { print count + 0 }' "${INV}")"
if [ "${rows}" -ne "${expected_count}" ]; then
  echo "FATAL: inventory denominator mismatch for ${release}" >&2
  echo "  expected ${expected_count}" >&2
  echo "  actual   ${rows}" >&2
  exit 2
fi

awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  NF != 4 { printf "FATAL: malformed inventory row %d\n", NR > "/dev/stderr"; bad=1; next }
  $1 !~ /^test\/.*\.go$/ { printf "FATAL: path outside go/test at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  seen[$1]++ { printf "FATAL: duplicate inventory path at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  prev != "" && $1 <= prev { printf "FATAL: inventory path order regression at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  $2 !~ /^(none|[[:alpha:]][[:alpha:]]*)$/ { printf "FATAL: invalid action token at row %d: %s\n", NR, $2 > "/dev/stderr"; bad=1 }
  $3 !~ /^[0-9]+$/ || $3 == 0 { printf "FATAL: invalid byte count at row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1 }
  $4 !~ /^[0-9a-f]{64}$/ { printf "FATAL: invalid sha256 at row %d: %s\n", NR, $4 > "/dev/stderr"; bad=1 }
  { prev=$1 }
  END { exit bad ? 1 : 0 }
' "${INV}"

if [ -n "${GO_CORPUS_ROOT:-}" ]; then
  [ -d "${GO_CORPUS_ROOT}/test" ] || die "GO_CORPUS_ROOT has no test directory: ${GO_CORPUS_ROOT}"
  [ -f "${GO_CORPUS_ROOT}/LICENSE" ] || die "GO_CORPUS_ROOT is missing upstream LICENSE"
  disk_rows="$(find "${GO_CORPUS_ROOT}/test" -type f -name '*.go' | wc -l | tr -d ' ')"
  if [ "${disk_rows}" -ne "${expected_count}" ]; then
    echo "FATAL: local corpus denominator mismatch" >&2
    echo "  expected ${expected_count}" >&2
    echo "  actual   ${disk_rows}" >&2
    exit 2
  fi
  while IFS=$'\t' read -r path action bytes digest; do
    case "${path}" in ''|\#*) continue ;; esac
    file="${GO_CORPUS_ROOT}/${path}"
    if [ ! -f "${file}" ]; then
      echo "FATAL: inventory path missing from local corpus: ${path}" >&2
      exit 2
    fi
    actual_bytes="$(wc -c < "${file}" | tr -d ' ')"
    actual_digest="$(shasum -a 256 "${file}" | awk '{print $1}')"
    if [ "${actual_bytes}" != "${bytes}" ] || [ "${actual_digest}" != "${digest}" ]; then
      echo "FATAL: inventory digest mismatch: ${path}" >&2
      exit 2
    fi
  done < "${INV}"

  while IFS= read -r disk_path; do
    rel="${disk_path#"${GO_CORPUS_ROOT}/"}"
    if ! awk -F '\t' -v path="${rel}" '$1 == path { found=1; exit } END { exit found ? 0 : 1 }' "${INV}"; then
      die "local corpus file missing from inventory: ${rel}"
    fi
  done < <(find "${GO_CORPUS_ROOT}/test" -type f -name '*.go' | sort)
fi

echo "Go corpus inventory OK: ${release} ${rows}/${expected_count}"
