#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/go-corpus/pin.tsv"
INV="${GO_CORPUS_INVENTORY:-${ROOT}/docs/go-corpus/inventory.tsv}"

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF >= 8 { print; exit }' "${PIN}")"
IFS=$'\t' read -r release kind filename url sha256 expected_count license provenance <<<"${pin_row}"

if [ -z "${release:-}" ] || [ -z "${expected_count:-}" ]; then
  echo "FATAL: missing corpus pin" >&2
  exit 2
fi

if [ ! -f "${INV}" ]; then
  echo "FATAL: missing Go corpus inventory: ${INV}" >&2
  exit 2
fi

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
  $2 !~ /^(none|[[:alpha:]][[:alpha:]]*)$/ { printf "FATAL: invalid action token at row %d: %s\n", NR, $2 > "/dev/stderr"; bad=1 }
  $3 !~ /^[0-9]+$/ || $3 == 0 { printf "FATAL: invalid byte count at row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1 }
  $4 !~ /^[0-9a-f]{64}$/ { printf "FATAL: invalid sha256 at row %d: %s\n", NR, $4 > "/dev/stderr"; bad=1 }
  END { exit bad ? 1 : 0 }
' "${INV}"

if [ -n "${GO_CORPUS_ROOT:-}" ]; then
  if [ ! -d "${GO_CORPUS_ROOT}/test" ]; then
    echo "FATAL: GO_CORPUS_ROOT has no test directory: ${GO_CORPUS_ROOT}" >&2
    exit 2
  fi
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
fi

echo "Go corpus inventory OK: ${release} ${rows}/${expected_count}"
