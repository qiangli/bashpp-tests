#!/usr/bin/env bash
# Fail-closed gate for the committed go.dev/tour corpus (tour/ tree).
#
# The corpus vendors the executable denominator of the pinned inventory —
# every applicable_go_program and build_only_go_program row — plus the
# upstream BSD LICENSE, copied verbatim from the pinned module
# materialization. This gate proves, offline on every harness run, that the
# committed bytes are still exactly those bytes:
#
#   - the join denominator is verified first: tests/tour/inventory.tsv data
#     rows must still hash to the inventory_data_sha256 frozen in
#     docs/tour/pin.tsv, so a row cannot be quietly edited to bless a tamper;
#   - path-set equality, in BOTH directions: the corpus tree must contain
#     LICENSE + exactly the executable rows — no missing file, no extra file,
#     and no same-count substitution or rename (a count-only check lets all
#     of those through; this is the lesson recorded in
#     tests/go-by-example/validate_inventory.sh);
#   - no symlink or other non-regular file may stand in for a copied source;
#   - every committed source must match its inventory row's byte count and
#     SHA-256; the LICENSE must match docs/tour/corpus.tsv;
#   - TOUR_ROOT mode (optional) byte-compares every corpus file against the
#     pinned module materialization — the proof an offline hash cannot give:
#     it catches the attacker who edits a source AND repins the inventory
#     hash, because the corpus no longer equals the pinned upstream bytes.
#
# Env overrides (used by tools/tour/corpus-tamper-tests.sh):
#   TOUR_PIN         pin table           (default docs/tour/pin.tsv)
#   TOUR_INVENTORY   inventory           (default tests/tour/inventory.tsv)
#   TOUR_CORPUS_PIN  corpus pin table    (default docs/tour/corpus.tsv)
#   TOUR_CORPUS_ROOT corpus root         (default <repo>/tour)
#   TOUR_ROOT        pinned source materialization to prove the copy against
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${TOUR_PIN:-${ROOT}/docs/tour/pin.tsv}"
INV="${TOUR_INVENTORY:-${ROOT}/tests/tour/inventory.tsv}"
CPIN="${TOUR_CORPUS_PIN:-${ROOT}/docs/tour/corpus.tsv}"
CORPUS="${TOUR_CORPUS_ROOT:-${ROOT}/tour}"

die() { echo "FATAL: $*" >&2; exit 2; }
file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes() { wc -c < "$1" | tr -d ' '; }

# ------------------------------------------------------------------ pins ----
[ -f "${PIN}" ]   || die "missing tour pin: ${PIN}"
[ -f "${INV}" ]   || die "missing tour inventory: ${INV}"
[ -f "${CPIN}" ]  || die "missing tour corpus pin: ${CPIN}"
[ -d "${CORPUS}" ] || die "missing corpus root: ${CORPUS}"

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r repo version commit go_mod_sum license _prov _rows inventory_data_sha256 <<<"${pin_row}"
[ "${repo:-}" = "golang.org/x/website" ] || die "pin repo must be golang.org/x/website, got ${repo:-}"
[ "${license:-}" = "BSD-3-Clause" ] || die "pin license must preserve upstream BSD-3-Clause provenance"
case "${inventory_data_sha256:-}" in *[!0-9a-f]*|'') die "pin inventory_data_sha256 must be lowercase hex" ;; esac
[ "${#inventory_data_sha256}" -eq 64 ] || die "pin inventory_data_sha256 must be 64 hex characters"

cpin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${CPIN}")"
IFS=$'\t' read -r c_root c_license_path c_license_bytes c_license_sha c_source_rows c_corpus_files c_prov <<<"${cpin_row}"
[ "${c_root:-}" = "tour" ] || die "corpus pin root must be tour, got ${c_root:-}"
[ "${c_license_path:-}" = "tour/LICENSE" ] || die "corpus pin license_path must be tour/LICENSE, got ${c_license_path:-}"
case "${c_license_bytes:-}" in ''|*[!0-9]*) die "corpus pin license_bytes must be an integer" ;; esac
[ "${c_license_bytes}" -gt 0 ] || die "corpus pin license_bytes must be positive"
case "${c_license_sha:-}" in *[!0-9a-f]*|'') die "corpus pin license_sha256 must be lowercase hex" ;; esac
[ "${#c_license_sha}" -eq 64 ] || die "corpus pin license_sha256 must be 64 hex characters"
case "${c_source_rows:-}" in ''|*[!0-9]*) die "corpus pin source_rows must be an integer" ;; esac
[ "${c_source_rows}" -gt 0 ] || die "corpus pin source_rows must be positive"
case "${c_corpus_files:-}" in ''|*[!0-9]*) die "corpus pin corpus_files must be an integer" ;; esac
[ "${c_corpus_files}" -gt 0 ] || die "corpus pin corpus_files must be positive"
[ "${c_corpus_files}" -eq $(( c_source_rows + 1 )) ] \
  || die "corpus pin counts inconsistent: corpus_files ${c_corpus_files} must be source_rows ${c_source_rows} + 1 (the LICENSE)"
[ -n "${c_prov:-}" ] || die "corpus pin provenance is required"

# ------------------------------------------- verified join denominator ------
# Trust the inventory only after re-proving it against the pin's frozen hash.
actual_inventory_data_sha256="$(awk '$0 !~ /^#/ && NF' "${INV}" | shasum -a 256 | awk '{print $1}')"
[ "${actual_inventory_data_sha256}" = "${inventory_data_sha256}" ] \
  || die "inventory data sha256 mismatch: pin freezes ${inventory_data_sha256}, inventory hashes ${actual_inventory_data_sha256} — the corpus may not be joined against an unpinned inventory"

# --------------------------------------------------------- expected set -----
mkdir -p "${ROOT}/.cache/tour"
TMP="$(mktemp -d "${ROOT}/.cache/tour/corpus-validate.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

awk -F '\t' '$1 !~ /^#/ && NF && ($4 == "applicable_go_program" || $4 == "build_only_go_program") { print $1 "\t" $7 "\t" $8 }' \
  "${INV}" > "${TMP}/exec.tsv"
while IFS=$'\t' read -r e_path _b _s; do
  case "${e_path}" in
    _content/tour/*.go) ;;
    *) die "executable inventory row is not an _content/tour .go path: ${e_path}" ;;
  esac
done < "${TMP}/exec.tsv"
cut -f1 "${TMP}/exec.tsv" | sort > "${TMP}/exec-paths.txt"
{ printf 'LICENSE\n'; cat "${TMP}/exec-paths.txt"; } | sort > "${TMP}/expected"

exec_rows="$(wc -l < "${TMP}/exec.tsv" | tr -d ' ')"
[ "${exec_rows}" -eq "${c_source_rows}" ] \
  || die "corpus pin source_rows mismatch: pin says ${c_source_rows}, inventory has ${exec_rows} executable rows"

# ----------------------------------------------------------- actual set ------
(cd "${CORPUS}" && find . -mindepth 1 -type l -print) > "${TMP}/symlinks.txt"
[ ! -s "${TMP}/symlinks.txt" ] \
  || die "symlink in corpus tree standing in for a copied source: $(head -1 "${TMP}/symlinks.txt")"
(cd "${CORPUS}" && find . -mindepth 1 ! -type f ! -type d -print) > "${TMP}/nonregular.txt"
[ ! -s "${TMP}/nonregular.txt" ] \
  || die "non-regular file in corpus tree: $(head -1 "${TMP}/nonregular.txt")"
(cd "${CORPUS}" && find . -mindepth 1 -type f | sed 's|^\./||') | sort > "${TMP}/actual"

actual_files="$(wc -l < "${TMP}/actual" | tr -d ' ')"
if ! diff -u "${TMP}/expected" "${TMP}/actual" > "${TMP}/setdiff.txt"; then
  sed -n '1,20p' "${TMP}/setdiff.txt" >&2
  die "corpus file set differs from the executable denominator (LICENSE + ${exec_rows} executable rows): ${actual_files} files present; missing/unexpected paths above"
fi
# corpus_files is not re-compared against the tree here: given the pin's
# enforced consistency (corpus_files == source_rows + 1), the enforced join
# (source_rows == executable rows) and set equality above, the comparison is
# implied — asserting it again would be a dead check pretending to be a gate.

# ------------------------------------------------------------- LICENSE ------
[ -f "${CORPUS}/LICENSE" ] || die "corpus is missing the upstream LICENSE at tour/LICENSE"
[ "$(file_bytes "${CORPUS}/LICENSE")" = "${c_license_bytes}" ] \
  || die "corpus LICENSE byte-count mismatch: pin ${c_license_bytes}, file $(file_bytes "${CORPUS}/LICENSE")"
[ "$(file_sha "${CORPUS}/LICENSE")" = "${c_license_sha}" ] \
  || die "corpus LICENSE sha256 mismatch: pin ${c_license_sha}, file $(file_sha "${CORPUS}/LICENSE")"

# ------------------------------------------------------------- sources ------
while IFS=$'\t' read -r s_path want_bytes want_sha; do
  f="${CORPUS}/${s_path}"
  [ -f "${f}" ] || die "missing corpus source for ${s_path} (set check above should have caught this)"
  [ "$(file_bytes "${f}")" = "${want_bytes}" ] \
    || die "corpus byte-count mismatch for ${s_path}: inventory ${want_bytes}, file $(file_bytes "${f}")"
  [ "$(file_sha "${f}")" = "${want_sha}" ] \
    || die "corpus sha256 mismatch for ${s_path}: inventory ${want_sha}, file $(file_sha "${f}")"
done < "${TMP}/exec.tsv"

# ------------------------------------------------- TOUR_ROOT copy proof -----
# Optional: prove the committed bytes against the pinned source
# materialization (module cache or clone at the pinned commit). This is the
# check an offline hash cannot give: it catches a source edited AND repinned,
# because the corpus then no longer equals upstream.
if [ -n "${TOUR_ROOT:-}" ]; then
  [ -d "${TOUR_ROOT}" ] || die "TOUR_ROOT is not a directory: ${TOUR_ROOT}"
  [ -f "${TOUR_ROOT}/LICENSE" ] || die "TOUR_ROOT is missing upstream LICENSE"
  cmp -s "${TOUR_ROOT}/LICENSE" "${CORPUS}/LICENSE" \
    || die "corpus LICENSE is not byte-identical to the pinned source materialization: ${TOUR_ROOT}/LICENSE"
  while IFS= read -r p_path; do
    [ -f "${TOUR_ROOT}/${p_path}" ] \
      || die "pinned source materialization is missing executable inventory row: ${p_path}"
    cmp -s "${TOUR_ROOT}/${p_path}" "${CORPUS}/${p_path}" \
      || die "corpus file is not byte-identical to the pinned source materialization: ${p_path}"
  done < "${TMP}/exec-paths.txt"
fi

echo "Go tour corpus OK: tour/ = ${exec_rows} executable sources + LICENSE, ${actual_files} files, byte-exact against the pinned inventory"
