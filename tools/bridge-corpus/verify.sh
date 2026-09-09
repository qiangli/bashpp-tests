#!/usr/bin/env bash
# verify.sh — the offline gate for the bridge corpus.
#
# Normal runs are offline: it reads only the checked-in artifacts under
# docs/bridge-corpus (and, when BRIDGE_SH_ROOT / BRIDGE_GO_ROOT point at a
# live sh checkout / pinned toolchain, re-verifies those too, fail-closed).
#
# WHAT IT ENFORCES
#   1. bridge-pin.tsv is structurally sound and carries digests for every
#      artifact it records.
#   2. stdlib-inventory.tsv: row count and data digest match the pin; the
#      joined path column re-hashes to sh's reviewed inventorySHA256
#      constant recorded in the pin (so the TSV is provably the reviewed
#      package list even without the sh checkout present); the capability
#      vocabulary and the policy decision table (reviewed-stdlib |
#      external-pure-go -> toolchain, everything else -> refuse) hold on
#      every row.
#   3. upstream-tests.tsv: row count and data digest match the pin; every
#      test file's package directory is a reviewed-inventory path; kinds,
#      digest formats and sort order hold.
#   4. obligations.tsv: every `executed` field is `no` (this slice executes
#      nothing and the gate forbids claiming otherwise); every denominator
#      is recomputed from the two inventories with the row's own derivation
#      filter — drift is fatal; the row set is exactly the tracked ids.
#   5. With BRIDGE_GO_ROOT: every test-file row is re-hashed against the
#      authenticated source tree in both directions, and the src/ tree hash
#      must still equal the pin's reviewed digest.
#   6. With BRIDGE_SH_ROOT: the four sh bridge files must still hash to the
#      pin's digests.
#
# A green run means: the artifacts are self-consistent, anchored to the
# reviewed pins, and claim no execution. It is NOT evidence that any bridge
# obligation is discharged.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${ROOT}/docs/bridge-corpus"
PIN="${DIR}/bridge-pin.tsv"
INV="${DIR}/stdlib-inventory.tsv"
TESTS="${DIR}/upstream-tests.tsv"
OBL="${DIR}/obligations.tsv"
LISTSHA="${ROOT}/tools/bridge-corpus/listsha.sh"
HELPER="${ROOT}/tools/bridge-corpus/bridgecorpus.go"

die() {
  echo "FATAL: $*" >&2
  exit 2
}

for f in "${PIN}" "${INV}" "${TESTS}" "${OBL}" "${LISTSHA}" "${HELPER}"; do
  [ -f "${f}" ] || die "missing artifact: ${f}"
done

pin_get() {
  awk -F '\t' -v key="$1" '$1 !~ /^#/ && $1 == key { print $2; found=1; exit } END { if (!found) exit 3 }' "${PIN}" \
    || die "bridge-pin.tsv missing key: $1"
}

expect_header() {
  local file="$1" key="$2" want="$3" got
  got="$(awk -F '\t' -v key="# ${key}" '$1 == key { print $2; found=1; exit } END { if (!found) exit 3 }' "${file}")" \
    || die "$(basename "${file}") missing # ${key} header"
  [ "${got}" = "${want}" ] || die "$(basename "${file}") # ${key}: expected ${want}, got ${got}"
}

hex64() {
  [ "${#1}" -eq 64 ] && case "${1:-}" in ''|*[!0-9a-f]*) return 1 ;; *) return 0 ;; esac
}

data_sha() {
  awk -F '\t' '$1 !~ /^#/ && NF' "$1" | shasum -a 256 | awk '{print $1}'
}

# ---- 1. pin structure ----

for key in sh_commit go_release go_bin_sha256 go_src_tree_sha256 \
           inventory_list_sha256 stdlib_inventory_rows stdlib_inventory \
           upstream_tests_rows upstream_tests; do
  pin_get "${key}" > /dev/null
done

release="$(pin_get go_release)"
case "${release}" in go1.27.*) ;; *) die "pin go_release must be a reviewed Go 1.27 release: ${release}" ;; esac
hex64 "$(pin_get go_bin_sha256)" || die "pin go_bin_sha256 must be 64 lowercase hex chars"
hex64 "$(pin_get go_src_tree_sha256)" || die "pin go_src_tree_sha256 must be 64 lowercase hex chars"
hex64 "$(pin_get inventory_list_sha256)" || die "pin inventory_list_sha256 must be 64 lowercase hex chars"

inv_row="$(awk -F '\t' '$1 == "stdlib_inventory" { print $2 "\t" $3; exit }' "${PIN}")"
tests_row="$(awk -F '\t' '$1 == "upstream_tests" { print $2 "\t" $3; exit }' "${PIN}")"
[ "${inv_row%%$'\t'*}" = "docs/bridge-corpus/stdlib-inventory.tsv" ] || die "pin stdlib_inventory path: ${inv_row%%$'\t'*}"
[ "${tests_row%%$'\t'*}" = "docs/bridge-corpus/upstream-tests.tsv" ] || die "pin upstream_tests path: ${tests_row%%$'\t'*}"
hex64 "${inv_row#*$'\t'}" || die "pin stdlib_inventory digest must be 64 hex chars"
hex64 "${tests_row#*$'\t'}" || die "pin upstream_tests digest must be 64 hex chars"

# ---- 2. stdlib-inventory.tsv ----

inv_sha="${inv_row#*$'\t'}"
actual_inv_sha="$(data_sha "${INV}")"
[ "${actual_inv_sha}" = "${inv_sha}" ] || die "stdlib-inventory data sha: expected ${inv_sha}, got ${actual_inv_sha}"

inv_rows="$(awk -F '\t' '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "${INV}")"
pin_inv_rows="$(pin_get stdlib_inventory_rows)"
[ "${inv_rows}" = "${pin_inv_rows}" ] || die "stdlib-inventory rows: expected ${pin_inv_rows}, got ${inv_rows}"

# The joined path column must re-hash to sh's reviewed inventorySHA256.
# listsha.sh emits exactly the generator framing (join "\n" + trailing "\n").
joined_sha="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1 }' "${INV}" | "${LISTSHA}")"
[ "${joined_sha}" = "$(pin_get inventory_list_sha256)" ] || \
  die "stdlib-inventory path set hashes to ${joined_sha}, not the reviewed $(pin_get inventory_list_sha256)"

awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  NF != 11 { printf "FATAL: malformed stdlib-inventory row %d (%d fields)\n", NR, NF > "/dev/stderr"; bad = 1; next }
  $1 !~ /^[a-z0-9]/ || $1 ~ /[[:space:]]/ { printf "FATAL: bad package path at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
  seen[$1]++ { printf "FATAL: duplicate package path at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
  prev != "" && $1 <= prev { printf "FATAL: path order regression at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
  $3 !~ /^[01]$/ || $7 !~ /^[01]$/ { printf "FATAL: boolean fields must be 0/1 at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
  $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $8 !~ /^[0-9]+$/ { printf "FATAL: count fields must be numeric at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
  $9 !~ /^(reviewed-stdlib|external-pure-go|cgo|compiled-only|not-buildable|unreviewed-stdlib|missing|unknown)$/ { printf "FATAL: unknown capability at row %d: %s -> %s\n", NR, $1, $9 > "/dev/stderr"; bad = 1 }
  { if ($9 == "reviewed-stdlib" || $9 == "external-pure-go") want = "toolchain"; else want = "refuse"
    if ($10 != want) { printf "FATAL: policy table violated at row %d: %s %s -> %s\n", NR, $1, $9, $10 > "/dev/stderr"; bad = 1 } }
  $9 != "missing" && $3 != "1" { printf "FATAL: non-missing stdlib row without standard=1 at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
  { prev = $1 }
  END { exit bad ? 1 : 0 }
' "${INV}"

# ---- 3. upstream-tests.tsv ----

tests_sha="${tests_row#*$'\t'}"
actual_tests_sha="$(data_sha "${TESTS}")"
[ "${actual_tests_sha}" = "${tests_sha}" ] || die "upstream-tests data sha: expected ${tests_sha}, got ${actual_tests_sha}"

tests_rows="$(awk -F '\t' '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "${TESTS}")"
pin_tests_rows="$(pin_get upstream_tests_rows)"
[ "${tests_rows}" = "${pin_tests_rows}" ] || die "upstream-tests rows: expected ${pin_tests_rows}, got ${tests_rows}"

expect_header "${TESTS}" "go_release" "${release}"
expect_header "${TESTS}" "go_src_tree_sha256" "$(pin_get go_src_tree_sha256)"

pkgs_tmp="$(mktemp)"
join_tmp="$(mktemp)"
trap 'rm -f "${pkgs_tmp}" "${join_tmp}"' EXIT
awk -F '\t' '$1 !~ /^#/ && NF { print $1 }' "${INV}" > "${pkgs_tmp}"

awk -F '\t' -v pkgfile="${pkgs_tmp}" '
  BEGIN { while ((getline line < pkgfile) > 0) pkg[line] = 1 }
  $1 ~ /^#/ || NF == 0 { next }
  NF != 11 { printf "FATAL: malformed upstream-tests row %d (%d fields)\n", NR, NF > "/dev/stderr"; bad = 1; next }
  {
    n = split($1, seg, "/")
    dir = seg[1]; for (i = 2; i < n; i++) dir = dir "/" seg[i]
    if (!pkg[dir]) { printf "FATAL: test file outside reviewed packages at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    if (seen[$1]++) { printf "FATAL: duplicate test path at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    if (prev != "" && $1 <= prev) { printf "FATAL: test path order regression at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    if ($3 !~ /^(black_box|in_package|other)$/) { printf "FATAL: unknown kind at row %d: %s -> %s\n", NR, $1, $3 > "/dev/stderr"; bad = 1 }
    if ($4 !~ /^[0-9]+$/ || $4 == 0) { printf "FATAL: bad byte count at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    if ($5 !~ /^[0-9a-f]{64}$/) { printf "FATAL: bad sha256 at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    for (i = 6; i <= 11; i++) if ($i !~ /^[0-9]+$/) { printf "FATAL: non-numeric count field %d at row %d: %s\n", i, NR, $1 > "/dev/stderr"; bad = 1 }
    if ($11 !~ /^[01]$/) { printf "FATAL: build_constraint must be 0/1 at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    prev = $1
  }
  END { exit bad ? 1 : 0 }
' "${TESTS}"

# ---- 4. obligations.tsv ----
# Recompute every derivation filter and compare against the stated
# denominator. Unknown ids are fatal: adding an obligation row without
# teaching this gate its filter cannot pass. Every filter lives in ONE awk
# program below so there is a single source for what each id means.

obligation_filter() {
  case "$1" in
    O1)
      awk -F '\t' '$1 !~ /^#/ && NF && $9 == "reviewed-stdlib" { n++ } END { print n + 0 }' "${INV}"
      ;;
    O9)
      awk -F '\t' '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "${TESTS}"
      ;;
    O2|O3|O4|O5|O6|O7|O8)
      awk -F '\t' -v inv="${INV}" -v ob="$1" '
        BEGIN { while ((getline line < inv) > 0) { if (line ~ /^#/ || !line) continue; split(line, f, "\t"); cap[f[1]] = f[9] } }
        $1 !~ /^#/ && NF {
          n = split($1, seg, "/"); dir = seg[1]; for (i = 2; i < n; i++) dir = dir "/" seg[i]
          c = (dir in cap) ? cap[dir] : "none"
          ok = 0
          if      (ob == "O2" && c == "reviewed-stdlib" && $3 == "black_box" && $10 == 0) ok = 1
          else if (ob == "O3" && c == "reviewed-stdlib" && $3 == "black_box" && $10 > 0)  ok = 1
          else if (ob == "O4" && c == "reviewed-stdlib" && $3 == "in_package")            ok = 1
          else if (ob == "O5" && c == "reviewed-stdlib" && $11 == 1)                       ok = 1
          else if (ob == "O6" && c == "cgo")                                               ok = 1
          else if (ob == "O7" && c == "not-buildable")                                     ok = 1
          else if (ob == "O8" && c == "reviewed-stdlib")                                   ok = 1
          if (ok) n_ok++
        }
        END { print n_ok + 0 }' "${TESTS}"
      ;;
    *) echo "UNKNOWN" ;;
  esac
}

while IFS=$'\t' read -r id scope stated derivation mode obligation executed; do
  case "${id}" in ''|\#*) continue ;; esac
  [ "${executed}" = "no" ] || die "obligation ${id} claims executed=${executed}: this slice executes nothing and the gate forbids the claim"
  got="$(obligation_filter "${id}")"
  [ "${got}" != "UNKNOWN" ] || die "obligation ${id} has no derivation filter in verify.sh — teach the gate or drop the row"
  [ "${got}" = "${stated}" ] || die "obligation ${id} denominator drift: stated ${stated}, recomputed ${got}"
done < "${OBL}"

obl_rows="$(awk -F '\t' '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "${OBL}")"
[ "${obl_rows}" = "9" ] || die "obligations.tsv has ${obl_rows} rows; the gate tracks exactly 9 (O1..O9)"

# ---- 5. live Go source re-verification (optional, fail-closed) ----

if [ -n "${BRIDGE_GO_ROOT:-}" ]; then
  go_root="${BRIDGE_GO_ROOT}"
  [ -d "${go_root}/src" ] || die "BRIDGE_GO_ROOT has no src tree: ${go_root}"
  [ -x "${go_root}/bin/go" ] || die "BRIDGE_GO_ROOT has no bin/go: ${go_root}"
  tree_sha="$("${go_root}/bin/go" run "${HELPER}" treehash "${go_root}/src")"
  [ "${tree_sha}" = "$(pin_get go_src_tree_sha256)" ] || die "BRIDGE_GO_ROOT src/ tree hash is not the reviewed digest"
  while IFS=$'\t' read -r path clause kind bytes digest rest; do
    case "${path}" in ''|\#*) continue ;; esac
    file="${go_root}/src/${path}"
    [ -f "${file}" ] || die "pinned source missing test file: ${path}"
    actual_bytes="$(wc -c < "${file}" | tr -d ' ')"
    actual_digest="$(shasum -a 256 "${file}" | awk '{print $1}')"
    [ "${actual_bytes}" = "${bytes}" ] || die "byte mismatch for ${path}"
    [ "${actual_digest}" = "${digest}" ] || die "digest mismatch for ${path}"
  done < "${TESTS}"
  while IFS= read -r disk; do
    rel="${disk#"${go_root}/src/"}"
    awk -F '\t' -v p="${rel}" '$1 !~ /^#/ && $1 == p { found = 1; exit } END { exit found ? 0 : 1 }' "${TESTS}" || \
      die "disk test file missing from inventory: ${rel}"
  done < <(while IFS= read -r pkg; do
    find "${go_root}/src/${pkg}" -maxdepth 1 -type f -name '*_test.go' 2>/dev/null
  done < "${pkgs_tmp}" | sort)
fi

# ---- 6. live sh re-verification (optional, fail-closed) ----

if [ -n "${BRIDGE_SH_ROOT:-}" ]; then
  sh_root="${BRIDGE_SH_ROOT}"
  while IFS=$'\t' read -r key rel digest; do
    case "${key}" in sh_go127stdlib_generated|sh_gen_go127stdlib|sh_bashpp_import|sh_bashpp_eval) ;; *) continue ;; esac
    f="${sh_root}/${rel}"
    [ -f "${f}" ] || die "sh pin row ${key}: file missing: ${f}"
    got="$(shasum -a 256 "${f}" | awk '{print $1}')"
    [ "${got}" = "${digest}" ] || die "sh pin row ${key}: digest drift for ${rel} (expected ${digest}, got ${got})"
  done < <(awk -F '\t' '$1 !~ /^#/ && NF == 3 { print }' "${PIN}")
fi

reviewed_n="$(awk -F '\t' '$1 !~ /^#/ && $9 == "reviewed-stdlib"' "${INV}" | wc -l | tr -d ' ')"
echo "Bridge corpus OK: ${release}; ${inv_rows} reviewed packages (${reviewed_n} classify reviewed-stdlib on this host), ${tests_rows} upstream test files, ${obl_rows} obligations, 0 executed"
