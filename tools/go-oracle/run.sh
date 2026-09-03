#!/usr/bin/env bash
# Execute the reviewed tranche of the official Go corpus with the pinned Go
# toolchain and emit machine-readable per-file results.
#
# This is the trusted Go ORACLE, not a Bash++ result. It says what upstream's own
# tests do under upstream's own compiler, so that later Bash++ work has something
# real to be measured against. Nothing here is evidence about bash++.
#
# The offline gates (corpus inventory, oracle pin, tranche) run first and are
# fatal. Then the driver runs, and the run is only reportable if it executed the
# whole tranche: see the denominator invariants in tools/go-oracle/main.go.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/go-oracle/pin.tsv"
OUT_DIR="${GO_ORACLE_OUT_DIR:-${ROOT}/.cache/go-oracle}"

die() { echo "FATAL: $*" >&2; exit 2; }

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")" || die "cannot read ${PIN}"
IFS=$'\t' read -r release semantics_path semantics_sha256 tranche per_action tranche_rows actions \
  unsupported_actions aux_inventory toolchain_pin <<<"${pin_row}"

# ---------------------------------------------------------------------------
# Offline gates. A tranche that drifted makes every count below meaningless, so
# they run before anything is compiled, and they are fatal.
# ---------------------------------------------------------------------------
"${ROOT}/tools/go-corpus/validate.sh" || die "Go corpus inventory validation failed"
"${ROOT}/tools/go-oracle/validate-tranche.sh" || die "Go oracle tranche validation failed"

# ---------------------------------------------------------------------------
# The corpus itself. It lives in the refresh cache, which is deliberately not
# under version control: this repo stores provenance, not a copy of Go.
# ---------------------------------------------------------------------------
CORPUS="${GO_CORPUS_ROOT:-${ROOT}/.cache/go-corpus/${release}}"
if [ ! -d "${CORPUS}/test" ]; then
  echo "FATAL: no pinned corpus at ${CORPUS}" >&2
  echo "  Run tools/go-corpus/refresh.sh (networked) to fetch and verify ${release}," >&2
  echo "  or set GO_CORPUS_ROOT to an already refreshed tree." >&2
  echo "  This is fatal rather than a skip: an oracle that executed nothing must" >&2
  echo "  not be reportable as an oracle run." >&2
  exit 2
fi
[ -f "${CORPUS}/LICENSE" ] || die "corpus at ${CORPUS} is missing upstream LICENSE"

# ---------------------------------------------------------------------------
# The toolchain. It must be the pinned release; the driver re-checks and refuses
# otherwise, but resolving it here gives a better error than a version mismatch.
# ---------------------------------------------------------------------------
GOTOOL="$("${ROOT}/tools/go-oracle/gotool.sh")" || exit 2
[ -x "${GOTOOL}" ] || die "not executable: ${GOTOOL}"

# ---------------------------------------------------------------------------
# Build the driver with the same release it drives.
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
DRIVER="${OUT_DIR}/go-oracle"
GOTOOLCHAIN="${release}" "${GOTOOL}" -C "${ROOT}/tools/go-oracle" build -o "${DRIVER}" . \
  || die "cannot build the oracle driver"

echo "=========================================================================="
echo " Go oracle: BOUNDED SEVEN-ACTION TRANCHE of the official ${release} corpus"
echo " corpus:      ${CORPUS}"
echo " toolchain:   ${GOTOOL}"
echo " tranche:     ${tranche} (${tranche_rows} files)"
echo " executes:    ${actions}"
echo " NOT run:     ${unsupported_actions}"
echo " This is not upstream's runner; it is 7 of its 17 actions. No Bash++ claim."
echo "=========================================================================="

# Every provenance input below is REQUIRED by the driver; there is no mode in
# which it produces results without them.
"${DRIVER}" \
  -corpus "${CORPUS}" \
  -gotool "${GOTOOL}" \
  -tranche "${ROOT}/${tranche}" \
  -inventory "${GO_CORPUS_INVENTORY:-${ROOT}/docs/go-corpus/inventory.tsv}" \
  -aux-inventory "${GO_ORACLE_AUX_INVENTORY:-${ROOT}/${aux_inventory}}" \
  -toolchain "${GO_ORACLE_TOOLCHAIN_PIN:-${ROOT}/${toolchain_pin}}" \
  -semantics-sha256 "${semantics_sha256}" \
  -go-version "${release}" \
  -out "${OUT_DIR}/tranche-001.results.jsonl" \
  -summary "${OUT_DIR}/tranche-001.summary.json" \
  ${GO_ORACLE_FLAGS:-}
rc=$?

echo
echo "results: ${OUT_DIR}/tranche-001.results.jsonl"
echo "summary: ${OUT_DIR}/tranche-001.summary.json"
exit "${rc}"
