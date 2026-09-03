#!/usr/bin/env bash
# Offline fail-closed gate for the pinned Go by Example corpus.
#
# What the rejected first cut did, and why it was not enough: it compared a
# COUNT (`rows` vs `find | wc -l`). A count is satisfied by any same-size set,
# so renaming a file, swapping two paths, or dropping one row while adding an
# unrelated one all passed. This validator derives the exact normalized path
# SET from disk and compares it to the inventory SET element by element, then
# verifies every copied byte. Counts are checked too, but only as a redundant
# cross-check against the pin.
#
# Overridable inputs exist so the tamper tests in tests/go-by-example/ can feed
# mutated tables without editing the checked-in ones.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS="${ROOT}/docs/go-by-example"
PIN="${GBE_PIN:-${DOCS}/pin.tsv}"
INV="${GBE_INVENTORY:-${DOCS}/inventory.tsv}"
CLS="${GBE_CLASSIFICATION:-${DOCS}/classification.tsv}"
SCHEMA="${GBE_SCHEMA:-${DOCS}/behavior-schema.tsv}"
CORPUS="${GBE_CORPUS:-${ROOT}/examples}"
# Inventory paths are repo-relative and all start with examples/, so file
# lookups resolve against the corpus PARENT. Keeping this indirection lets the
# tamper tests point the validator at a mutated copy of the tree.
BASE="$(cd "$(dirname "${CORPUS}")" && pwd)"
CORPUS_NAME="$(basename "${CORPUS}")"
[ "${CORPUS_NAME}" = examples ] || die "corpus directory must be named examples/, got ${CORPUS_NAME}"

die() { echo "FATAL: $*" >&2; exit 2; }

for f in "${PIN}" "${INV}" "${CLS}" "${SCHEMA}"; do
  [ -f "${f}" ] || die "missing required table: ${f}"
done
[ -d "${CORPUS}" ] || die "missing corpus tree: ${CORPUS}"

# ---------------------------------------------------------------------------
# 1. Pin: provenance for the exact upstream commit.
# ---------------------------------------------------------------------------
pin_rows="$(awk -F '\t' '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "${PIN}")"
[ "${pin_rows}" -eq 1 ] || die "pin must contain exactly one data row, found ${pin_rows}"
pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
pin_fields="$(awk -F '\t' '$1 !~ /^#/ && NF { print NF; exit }' "${PIN}")"
[ "${pin_fields}" -eq 9 ] || die "pin row must have 9 fields, found ${pin_fields}"
IFS=$'\t' read -r repo commit observed license provenance want_cls_rows want_inv_rows want_data_sha want_go_files <<<"${pin_row}"

[ "${repo}" = "https://github.com/mmcgrana/gobyexample.git" ] || die "pin repository must be the upstream Go by Example repository, got: ${repo}"
case "${commit}" in *[!0-9a-f]*|'') die "pin commit must be lowercase hex" ;; esac
[ "${#commit}" -eq 40 ] || die "pin commit must be a 40-character sha1, got ${#commit}"
[ "${commit}" = "7d705626375ba0263b616865a286e1587d6989c8" ] || die "pin commit drifted from the reviewed Sprint 98 pin"
case "${observed}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) die "pin observed must be YYYY-MM-DD" ;; esac
[ "${license}" = "CC-BY-3.0" ] || die "pin must preserve the upstream CC BY 3.0 grant"
[ -n "${provenance}" ] || die "pin provenance is required"
case "${want_cls_rows}${want_inv_rows}${want_go_files}" in ''|*[!0-9]*) die "pin row counts must be integers" ;; esac
[ "${want_go_files}" -eq 85 ] || die "pin upstream_go_files must be the 85 .go files present at the pinned commit, got ${want_go_files}"
case "${want_data_sha}" in *[!0-9a-f]*|'') die "pin inventory_data_sha256 must be lowercase hex" ;; esac
[ "${#want_data_sha}" -eq 64 ] || die "pin inventory_data_sha256 must be 64 hex characters"

# ---------------------------------------------------------------------------
# 2. Schema: vocabularies and behavior->adapter/normalization coupling.
#    Loaded from the table; nothing below hardcodes a term.
# ---------------------------------------------------------------------------
schema_dump="$(awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  $1 == "behavior" {
    if (NF != 4) { printf "FATAL: behavior row %d must have 4 fields\n", NR > "/dev/stderr"; bad = 1; next }
    if ($2 in beh) { printf "FATAL: duplicate behavior %s\n", $2 > "/dev/stderr"; bad = 1 }
    beh[$2] = 1; req[$2] = $3; allow[$2] = $4; next
  }
  $1 == "adapter" {
    if (NF != 4) { printf "FATAL: adapter row %d must have 4 fields\n", NR > "/dev/stderr"; bad = 1; next }
    if ($2 in ada) { printf "FATAL: duplicate adapter %s\n", $2 > "/dev/stderr"; bad = 1 }
    if ($4 == "") { printf "FATAL: adapter %s has no description\n", $2 > "/dev/stderr"; bad = 1 }
    ada[$2] = 1; next
  }
  $1 == "normalization" {
    if (NF != 4) { printf "FATAL: normalization row %d must have 4 fields\n", NR > "/dev/stderr"; bad = 1; next }
    if ($2 in nrm) { printf "FATAL: duplicate normalization %s\n", $2 > "/dev/stderr"; bad = 1 }
    if ($4 == "") { printf "FATAL: normalization %s has no description\n", $2 > "/dev/stderr"; bad = 1 }
    nrm[$2] = 1; next
  }
  { printf "FATAL: unknown schema record type %s at row %d\n", $1, NR > "/dev/stderr"; bad = 1 }
  END {
    nb = 0; for (b in beh) nb++
    na = 0; for (a in ada) na++
    nn = 0; for (n in nrm) nn++
    if (nb == 0 || na == 0 || nn == 0) { printf "FATAL: schema vocabularies incomplete\n" > "/dev/stderr"; bad = 1 }
    if (!("none" in ada) || !("none" in nrm)) { printf "FATAL: schema must declare the none adapter and none normalization\n" > "/dev/stderr"; bad = 1 }
    if (!("deterministic" in beh)) { printf "FATAL: schema must declare the deterministic behavior\n" > "/dev/stderr"; bad = 1 }
    # every required adapter and allowed normalization must itself be declared
    for (b in beh) {
      k = split(req[b], rs, ",")
      for (i = 1; i <= k; i++) if (!(rs[i] in ada)) { printf "FATAL: behavior %s requires undeclared adapter %s\n", b, rs[i] > "/dev/stderr"; bad = 1 }
      k = split(allow[b], as, ",")
      for (i = 1; i <= k; i++) if (!(as[i] in nrm)) { printf "FATAL: behavior %s allows undeclared normalization %s\n", b, as[i] > "/dev/stderr"; bad = 1 }
    }
    if (bad) exit 1
    for (b in beh) printf "B\t%s\t%s\t%s\n", b, req[b], allow[b]
    for (a in ada) printf "A\t%s\n", a
    for (n in nrm) printf "N\t%s\n", n
  }
' "${SCHEMA}")" || die "behavior schema table is malformed: ${SCHEMA}"

# ---------------------------------------------------------------------------
# 3. Row-shape and coupling checks, applied identically to the authored
#    classification table and to the derived inventory.
# ---------------------------------------------------------------------------
check_rows() { # <file> <expected-field-count> <label>
  local file="$1" nf="$2" label="$3"
  printf '%s\n' "${schema_dump}" | awk -F '\t' -v nf="${nf}" -v label="${label}" '
    NR == FNR {
      if ($1 == "B") { beh[$2] = 1; req[$2] = $3; allow[$2] = $4 }
      else if ($1 == "A") ada[$2] = 1
      else if ($1 == "N") nrm[$2] = 1
      next
    }
    function fail(msg) { printf "FATAL: %s: %s (row %d)\n", label, msg, FNR > "/dev/stderr"; bad = 1 }
    # comma-joined set: sorted, unique, non-empty, all members in vocab
    function checkset(val, vocab, what,   k, parts, i) {
      if (val == "") { fail(what " is empty"); return }
      k = split(val, parts, ",")
      for (i = 1; i <= k; i++) {
        if (parts[i] == "") { fail(what " has an empty member"); return }
        if (!(parts[i] in vocab)) { fail(what " uses undeclared term " parts[i]); return }
        if (i > 1 && parts[i] <= parts[i-1]) { fail(what " must be sorted and duplicate-free: " val); return }
      }
    }
    $1 ~ /^#/ || NF == 0 { next }
    NF != nf { fail("expected " nf " fields, found " NF); next }
    {
      p = $1
      # --- path safety: exact normalized repo-relative path, nothing else ---
      if (p ~ /^\//) fail("absolute path: " p)
      if (p ~ /^[A-Za-z]:/) fail("drive-qualified path: " p)
      if (p ~ /\\/) fail("backslash in path: " p)
      if (p ~ /\/\//) fail("empty path component: " p)
      if (p ~ /\/$/) fail("trailing slash: " p)
      if (p ~ /(^|\/)\.\.(\/|$)/) fail("parent traversal: " p)
      if (p ~ /(^|\/)\.(\/|$)/) fail("dot component: " p)
      if (p ~ /^~/) fail("home-relative path: " p)
      if (p ~ /[^A-Za-z0-9._\/-]/) fail("path outside the permitted character set: " p)
      if (p !~ /^examples\//) fail("path outside the pinned examples/ tree: " p)
      if (seen[p]++) fail("duplicate path: " p)
      if (prev != "" && p <= prev) fail("path order regression (inventory must be a sorted set): " p)
      prev = p
    }
    $2 !~ /^(program|test_program|runtime_asset|provenance)$/ { fail("invalid kind: " $2) }
    {
      kind = $2; behavior = $3; normalization = $4; adapter = $5; requires = $6
      if (kind == "runtime_asset" || kind == "provenance") {
        # Structural, not failure-derived: a .txt asset is not a program, so it
        # has no behavior to classify. The gate never "discovers" this state.
        if (behavior != "not_a_program" || normalization != "not_a_program" || adapter != "not_a_program")
          fail("non-program row must use not_a_program on all three axes: " $1)
        if (requires != "none") fail("non-program row must not declare requires: " $1)
        if (kind == "provenance" && $1 !~ /\.md$/) fail("provenance row must be the upstream README: " $1)
        if (kind == "runtime_asset" && $1 ~ /\.go$/) fail("runtime asset must not be a .go file: " $1)
      } else {
        if ($1 !~ /\.go$/) fail("program row must be a .go file: " $1)
        if (kind == "test_program" && $1 !~ /_test\.go$/) fail("test_program row must be a _test.go file: " $1)
        if (kind == "program" && $1 ~ /_test\.go$/) fail("_test.go file must be kind test_program: " $1)
        if (behavior ~ /not_a_program/ || normalization ~ /not_a_program/ || adapter ~ /not_a_program/)
          fail("program row must not use not_a_program: " $1)
        # An N/A that a failing run could produce is exactly what is banned.
        if ($0 ~ /(^|\t)(n\/a|N\/A|PLANNED|planned|unsupported|skip|skipped|exception)(\t|$)/)
          fail("failure-derived or deferred state is not a valid classification: " $1)
        checkset(behavior, beh, "behavior")
        checkset(normalization, nrm, "normalization")
        checkset(adapter, ada, "adapter")

        nb = split(behavior, bs, ",")
        if (behavior ~ /(^|,)deterministic(,|$)/ && nb != 1)
          fail("deterministic is exclusive and cannot be combined: " behavior)
        if (behavior ~ /(^|,)deterministic(,|$)/ && (normalization != "none" || adapter != "none"))
          fail("a deterministic row must compare raw bytes with no adapter: " $1)
        if ((kind == "test_program") != (behavior ~ /(^|,)test_harness(,|$)/))
          fail("test_harness behavior and test_program kind must agree: " $1)

        # --- coupling: every declared behavior requires its adapters ---
        for (i = 1; i <= nb; i++) {
          if (req[bs[i]] == "none") continue
          k = split(req[bs[i]], rs, ",")
          for (j = 1; j <= k; j++)
            if (("," adapter ",") !~ ("," rs[j] ",")) fail("behavior " bs[i] " requires adapter " rs[j] ", missing on " $1)
        }
        # --- no unlicensed adapter ---
        na = split(adapter, as, ",")
        for (i = 1; i <= na; i++) {
          if (as[i] == "none") continue
          ok = 0
          for (j = 1; j <= nb; j++) if (("," req[bs[j]] ",") ~ ("," as[i] ",")) ok = 1
          if (!ok) fail("adapter " as[i] " is not required by any declared behavior on " $1)
        }
        # --- no unlicensed normalization (normalization only where licensed) ---
        nn = split(normalization, ns, ",")
        for (i = 1; i <= nn; i++) {
          if (ns[i] == "none") continue
          ok = 0
          for (j = 1; j <= nb; j++) if (("," allow[bs[j]] ",") ~ ("," ns[i] ",")) ok = 1
          if (!ok) fail("normalization " ns[i] " is not licensed by any declared behavior on " $1)
        }
        if (adapter != "none" && adapter ~ /(^|,)none(,|$)/) fail("none cannot be combined with a real adapter: " $1)
        if (normalization != "none" && normalization ~ /(^|,)none(,|$)/) fail("none cannot be combined with a real normalization: " $1)
      }
      if (requires != "none") {
        k = split(requires, rq, ",")
        for (i = 1; i <= k; i++) {
          if (rq[i] !~ /^examples\//) fail("requires entry outside examples/: " rq[i])
          if (rq[i] ~ /(^|\/)\.\.(\/|$)/ || rq[i] ~ /^\//) fail("unsafe requires entry: " rq[i])
          if (i > 1 && rq[i] <= rq[i-1]) fail("requires must be sorted and duplicate-free: " requires)
        }
      }
    }
    END { exit bad ? 1 : 0 }
  ' - "${file}" || return 1
}

check_rows "${CLS}" 6 "classification.tsv" || die "classification table rejected"
check_rows "${INV}" 8 "inventory.tsv" || die "inventory table rejected"

# ---------------------------------------------------------------------------
# 4. Inventory headers and data digest.
# ---------------------------------------------------------------------------
expect_header() {
  local key="$1" want="$2" got
  got="$(awk -F '\t' -v k="# ${key}" '$1 == k { print $2; found = 1; exit } END { if (!found) exit 1 }' "${INV}")" \
    || die "inventory is missing the # ${key} header"
  [ "${got}" = "${want}" ] || die "inventory # ${key} header mismatch: expected ${want}, got ${got}"
}
expect_header repository "${repo}"
expect_header commit "${commit}"
expect_header observed "${observed}"
expect_header license "${license}"
expect_header generated_by "tools/go-by-example/refresh.sh"
expect_header derived_from "docs/go-by-example/classification.tsv"

data_sha="$(awk '$0 !~ /^#/ && NF' "${INV}" | shasum -a 256 | awk '{ print $1 }')"
[ "${data_sha}" = "${want_data_sha}" ] \
  || die "inventory data digest mismatch: pin says ${want_data_sha}, computed ${data_sha}"

# ---------------------------------------------------------------------------
# 5. Exact normalized path SET comparisons.
#    classification set == inventory set == on-disk set.
#    A count check cannot see a substitution; a set difference always can.
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

awk -F '\t' '$1 !~ /^#/ && NF { print $1 }' "${CLS}" | LC_ALL=C sort > "${tmp}/cls.set"
awk -F '\t' '$1 !~ /^#/ && NF { print $1 }' "${INV}" | LC_ALL=C sort > "${tmp}/inv.set"
# Derive the on-disk set the same way the inventory spells it: repo-relative,
# no leading ./, sorted. -type f only: a symlink is not a copied source byte.
( cd "${BASE}" && find examples -type f -print ) | LC_ALL=C sort > "${tmp}/disk.set"

if [ -s "${tmp}/disk.set" ]; then :; else die "no files found under ${CORPUS} — the corpus did not load"; fi

report_setdiff() { # <a> <b> <a-label> <b-label>
  local only_a only_b
  only_a="$(LC_ALL=C comm -23 "$1" "$2")"
  only_b="$(LC_ALL=C comm -13 "$1" "$2")"
  [ -z "${only_a}" ] && [ -z "${only_b}" ] && return 0
  [ -n "${only_a}" ] && printf 'FATAL: present in %s but not in %s:\n%s\n' "$3" "$4" "${only_a}" >&2
  [ -n "${only_b}" ] && printf 'FATAL: present in %s but not in %s:\n%s\n' "$4" "$3" "${only_b}" >&2
  return 1
}

report_setdiff "${tmp}/cls.set" "${tmp}/inv.set" "classification.tsv" "inventory.tsv" \
  || die "classification and inventory path sets differ"
report_setdiff "${tmp}/inv.set" "${tmp}/disk.set" "inventory.tsv" "the corpus tree" \
  || die "inventory and on-disk path sets differ (missing or extra rows/files)"

# Symlinks and non-regular entries must not exist at all in the corpus tree.
strays="$( cd "${BASE}" && find examples ! -type f ! -type d -print )"
[ -z "${strays}" ] || die "corpus contains non-regular files: ${strays}"

# ---------------------------------------------------------------------------
# 6. Every copied source byte is verified, not just counted.
# ---------------------------------------------------------------------------
verified=0
while IFS=$'\t' read -r path kind behavior normalization adapter requires bytes digest; do
  case "${path}" in ''|\#*) continue ;; esac
  f="${BASE}/${path}"
  [ -f "${f}" ] || die "inventory row has no file: ${path}"
  actual_bytes="$(wc -c <"${f}" | tr -d ' ')"
  [ "${actual_bytes}" = "${bytes}" ] || die "byte-count drift on ${path}: inventory ${bytes}, file ${actual_bytes}"
  actual_digest="$(shasum -a 256 "${f}" | awk '{ print $1 }')"
  [ "${actual_digest}" = "${digest}" ] || die "content drift on ${path}: inventory ${digest}, file ${actual_digest}"
  verified=$((verified + 1))
done < "${INV}"

# ---------------------------------------------------------------------------
# 7. Classification columns of the derived inventory must equal the authored
#    table exactly, and the two must agree row for row.
# ---------------------------------------------------------------------------
awk -F '\t' 'BEGIN { OFS = "\t" } $1 !~ /^#/ && NF { print $1, $2, $3, $4, $5, $6 }' "${INV}" \
  | diff -u <(awk -F '\t' 'BEGIN { OFS = "\t" } $1 !~ /^#/ && NF { print $1, $2, $3, $4, $5, $6 }' "${CLS}") - >/dev/null \
  || die "inventory classification columns do not match the authored classification table"

# ---------------------------------------------------------------------------
# 8. Runtime-asset closure: every required asset is an inventoried asset row,
#    and every asset row is required by at least one program.
# ---------------------------------------------------------------------------
awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  { kindof[$1] = $2 }
  $6 != "none" { k = split($6, rq, ","); for (i = 1; i <= k; i++) { needed[rq[i]] = 1; by[rq[i]] = $1 } }
  END {
    for (p in needed) {
      if (!(p in kindof)) { printf "FATAL: %s requires uninventoried asset %s\n", by[p], p > "/dev/stderr"; bad = 1; continue }
      if (kindof[p] != "runtime_asset") { printf "FATAL: %s requires %s which is kind %s, not runtime_asset\n", by[p], p, kindof[p] > "/dev/stderr"; bad = 1 }
    }
    for (p in kindof) {
      if (kindof[p] == "runtime_asset" && !(p in needed)) { printf "FATAL: runtime asset %s is not required by any program row\n", p > "/dev/stderr"; bad = 1 }
    }
    exit bad ? 1 : 0
  }
' "${INV}" || die "runtime-asset closure failed"

# ---------------------------------------------------------------------------
# 9. Redundant count cross-check against the pin.
# ---------------------------------------------------------------------------
cls_rows="$(wc -l < "${tmp}/cls.set" | tr -d ' ')"
inv_rows="$(wc -l < "${tmp}/inv.set" | tr -d ' ')"
go_files="$(grep -c '\.go$' "${tmp}/inv.set" || true)"
[ "${cls_rows}" -eq "${want_cls_rows}" ] || die "classification row count ${cls_rows} != pinned ${want_cls_rows}"
[ "${inv_rows}" -eq "${want_inv_rows}" ] || die "inventory row count ${inv_rows} != pinned ${want_inv_rows}"
[ "${go_files}" -eq "${want_go_files}" ] || die "corpus holds ${go_files} .go files, pin says ${want_go_files}"
[ "${verified}" -eq "${inv_rows}" ] || die "verified ${verified} files but inventory has ${inv_rows} rows"

programs="$(awk -F '\t' '$1 !~ /^#/ && NF && ($2 == "program" || $2 == "test_program") { n++ } END { print n + 0 }' "${INV}")"
assets="$(awk -F '\t' '$1 !~ /^#/ && NF && $2 == "runtime_asset" { n++ } END { print n + 0 }' "${INV}")"

echo "Go by Example inventory OK: ${commit} — ${verified}/${inv_rows} files verified (${programs} programs, ${assets} runtime assets, ${go_files} .go)"
