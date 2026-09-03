#!/usr/bin/env bash
# Tamper self-tests for the committed tour corpus gate (validate-corpus.sh).
#
# Every probe runs the REAL tools/tour/validate-corpus.sh against a miniature
# pinned world — a tiny source materialization (one applicable program, one
# build-only program, one excluded fragment, the real upstream LICENSE) with
# its own inventory, pin and corpus pin — then mutates exactly one fact and
# proves the gate fails closed with the expected diagnosis. A probe whose
# mutation is ACCEPTED is a failure of this suite.
#
# Probe families:
#   1. source bytes        - same-byte-count content edit (sha-only signal)
#   2. byte counts         - corpus file drifts off its inventory row
#   3. path-set integrity  - missing file, extra file, same-count rename, and
#                            an excluded fragment smuggled into the corpus
#   4. file kind           - a symlink standing in for a copied source
#   5. LICENSE             - license file tamper; corpus-pin digest tamper
#   6. corpus pin counts   - source_rows / corpus_files drift
#   7. join denominator    - an inventory row edit without repinning the pin
#                            hash must fail before any corpus check runs
#   8. hash-consistent     - the attacker who edits a source AND repins the
#                            inventory hash is beyond offline hashes (the
#                            reviewed pin is the trust anchor — asserted
#                            explicitly); TOUR_ROOT mode must still catch them
#
# Usage: tools/tour/corpus-tamper-tests.sh
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="${ROOT}/tools/tour/validate-corpus.sh"

[ -x "${GATE}" ] || { echo "FATAL: ${GATE} not executable" >&2; exit 2; }

WORK_BASE="${ROOT}/.cache/tour/corpus-tamper"
mkdir -p "${WORK_BASE}"
WORK="$(mktemp -d "${WORK_BASE}.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
LOG="${WORK}/probe.log"

pass=0 fail=0
ok()   { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }

expect_fail() { # <label> <expected-marker> <cmd...>
  local label="$1" marker="$2"; shift 2
  local rc=0
  "$@" > "${LOG}" 2>&1 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    bad "${label}: mutation was ACCEPTED (exit 0)"
    sed -n '1,5p' "${LOG}" | sed 's/^/    /' >&2
    return
  fi
  if ! grep -qF -- "${marker}" "${LOG}"; then
    bad "${label}: failed (exit ${rc}) without the expected diagnosis '${marker}'"
    sed -n '1,5p' "${LOG}" | sed 's/^/    /' >&2
    return
  fi
  ok "${label} (exit ${rc}, caught: ${marker})"
}

expect_ok() {
  local label="$1"; shift
  local rc=0
  "$@" > "${LOG}" 2>&1 || rc=$?
  [ "${rc}" -eq 0 ] && { ok "${label}"; return; }
  bad "${label}: expected success, got exit ${rc}"
  sed -n '1,8p' "${LOG}" | sed 's/^/    /' >&2
}

sha_of()   { shasum -a 256 "$1" | awk '{print $1}'; }
bytes_of() { wc -c < "$1" | tr -d ' '; }

VERSION="$(awk -F '\t' '$1 !~ /^#/ && NF { print $2; exit }' "${ROOT}/docs/tour/pin.tsv")"
COMMIT="$(awk -F '\t' '$1 !~ /^#/ && NF { print $3; exit }' "${ROOT}/docs/tour/pin.tsv")"
REAL_LICENSE="$(awk -F '\t' '$1 !~ /^#/ && NF { print $2; exit }' "${ROOT}/docs/tour/pin.tsv" \
  | { read -r _v; GOMODCACHE_DIR="$(go env GOMODCACHE)"; ls -d "${GOMODCACHE_DIR}/golang.org/x/website@${_v}" 2>/dev/null; })"
[ -n "${REAL_LICENSE}" ] || { echo "FATAL: pinned x/website source not in module cache (${VERSION}); run the acquisition in docs/tour/pin.tsv first" >&2; exit 2; }
[ -f "${REAL_LICENSE}/LICENSE" ] || { echo "FATAL: pinned source materialization missing LICENSE" >&2; exit 2; }

# ---------------------------------------------- miniature pinned world ------
MINI="${WORK}/src"                 # the pinned source materialization
CORPUS="${WORK}/corpus"            # the committed corpus tree under test
mkdir -p "${MINI}/_content/tour" "${CORPUS}/_content/tour"

cp "${REAL_LICENSE}/LICENSE" "${MINI}/LICENSE"
printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("alpha ok") }\n' \
  > "${MINI}/_content/tour/alpha.go"
printf '//go:build OMIT && norun\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("beta ok") }\n' \
  > "${MINI}/_content/tour/beta.go"
printf '//go:build OMIT nobuild\n\npackage main\n\nfunc main() { fmt.Println("gamma skeleton") }\n' \
  > "${MINI}/_content/tour/gamma.go"
chmod 444 "${MINI}"/_content/tour/*.go

# The corpus vendors LICENSE + the two executable rows only; gamma is an
# excluded fragment and must NOT be copied. Corpus files carry git's ordinary
# 0644 (unlike the read-only module-cache materialization they came from) —
# the gate pins bytes, not host modes.
cp "${MINI}/LICENSE" "${CORPUS}/LICENSE"
cp "${MINI}/_content/tour/alpha.go" "${CORPUS}/_content/tour/alpha.go"
cp "${MINI}/_content/tour/beta.go"  "${CORPUS}/_content/tour/beta.go"
chmod 644 "${CORPUS}/LICENSE" "${CORPUS}"/_content/tour/*.go

INV="${WORK}/inv.tsv"
PIN="${WORK}/pin.tsv"
CPIN="${WORK}/corpus.tsv"

inventory_rows() {
  ruby -rdigest - "${MINI}/_content/tour" <<'RUBY'
tour = ARGV[0]
rows = []
{
  "alpha.go" => "lesson_play_program",
  "beta.go"  => "lesson_play_program",
  "gamma.go" => "lesson_play_program",
}.each do |f, kind|
  path = "_content/tour/#{f}"
  text = File.binread(File.join(tour, f))
  tag = text.lines.first
  appl =
    if tag.include?("nobuild") then "excluded_fragment"
    elsif tag.include?("norun") then "build_only_go_program"
    else "applicable_go_program"
    end
  exc = appl == "excluded_fragment" ? "fragment" : "none"
  schema =
    case appl
    when "applicable_go_program" then "baseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run"
    when "build_only_go_program" then "baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build-run"
    else "baseline:syntax-context-only;bpp_interpreted:not-run;bpp_compiled:not-run"
    end
  rows << [path, kind, "n/a", appl, "exception:#{exc}", schema, text.bytesize, Digest::SHA256.hexdigest(text)]
end
inline = "\tInline prose: never executed by the tour.\n"
rows << ["_content/tour/basics.article#inline-01-L1", "article_inline_block", "1",
         "excluded_fragment", "exception:fragment",
         "baseline:syntax-context-only;bpp_interpreted:not-run;bpp_compiled:not-run",
         inline.bytesize, Digest::SHA256.hexdigest(inline)]
rows.sort_by!(&:first)
rows.each { |r| puts r.join("\t") }
RUBY
}

write_inventory() {
  {
    echo "# release	golang.org/x/website@${VERSION}"
    echo "# commit	${COMMIT}"
    echo "# go_mod_sum	pinned"
    echo "# source	https://go.googlesource.com/website"
    echo "# license	BSD-3-Clause"
    echo "# generated_by	tools/tour/refresh.sh"
    echo "# path	kind	start_line	applicability	exception	differential_schema	bytes	sha256"
    inventory_rows
  } > "${INV}"
}

write_pin() { # rebinds the miniature pin to the current miniature inventory
  local sha
  sha="$(awk '$0 !~ /^#/ && NF' "${INV}" | shasum -a 256 | awk '{print $1}')"
  {
    echo "# Miniature tour pin for corpus tamper probes (regenerated per run)."
    echo "# repo	version	commit	go_mod_sum	license	provenance	inventory_rows	inventory_data_sha256"
    printf 'golang.org/x/website\t%s\t%s\th1:miniature\tBSD-3-Clause\tminiature pinned world for corpus tamper probes\t4\t%s\n' \
      "${VERSION}" "${COMMIT}" "${sha}"
  } > "${PIN}"
}

write_cpin() { # miniature corpus pin: 2 executable rows + LICENSE = 3 files
  {
    echo "# Miniature corpus pin for corpus tamper probes."
    echo "# root	license_path	license_bytes	license_sha256	source_rows	corpus_files	provenance"
    printf 'tour\ttour/LICENSE\t%s\t%s\t2\t3\tminiature corpus pin for tamper probes\n' \
      "$(bytes_of "${MINI}/LICENSE")" "$(sha_of "${MINI}/LICENSE")"
  } > "${CPIN}"
}

write_inventory; write_pin; write_cpin
cp -R "${CORPUS}" "${WORK}/corpus.good"

gate() { # gate [TOUR_ROOT] — the real gate on the miniature world
  local root="${1:-}"
  if [ -n "${root}" ]; then
    env TOUR_PIN="${PIN}" TOUR_INVENTORY="${INV}" TOUR_CORPUS_PIN="${CPIN}" \
        TOUR_CORPUS_ROOT="${CORPUS}" TOUR_ROOT="${root}" "${GATE}"
  else
    env TOUR_PIN="${PIN}" TOUR_INVENTORY="${INV}" TOUR_CORPUS_PIN="${CPIN}" \
        TOUR_CORPUS_ROOT="${CORPUS}" "${GATE}"
  fi
}
restore_corpus() { rm -rf "${CORPUS}"; cp -R "${WORK}/corpus.good" "${CORPUS}"; }

echo "== probe 0: control — the miniature corpus must validate green first =="
expect_ok "control (offline)"            gate
expect_ok "control (TOUR_ROOT proof)"    gate "${MINI}"

echo "== probe family 1: source bytes (same byte count, different bytes) =="
printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("alpha KO") }\n' \
  > "${CORPUS}/_content/tour/alpha.go"
expect_fail "source-sha tamper (same byte count)" "corpus sha256 mismatch" gate
restore_corpus

echo "== probe family 2: byte counts =="
printf '\n' >> "${CORPUS}/_content/tour/alpha.go"
expect_fail "corpus file byte drift" "corpus byte-count mismatch" gate
restore_corpus

echo "== probe family 3: path-set integrity (both directions) =="
mv "${CORPUS}/_content/tour/alpha.go" "${WORK}/alpha.hidden"
expect_fail "missing corpus source" "corpus file set differs" gate
mv "${WORK}/alpha.hidden" "${CORPUS}/_content/tour/alpha.go"

printf 'package rogue\n' > "${CORPUS}/_content/tour/rogue.go"
expect_fail "extra untracked corpus file" "corpus file set differs" gate
rm -f "${CORPUS}/_content/tour/rogue.go"

mv "${CORPUS}/_content/tour/alpha.go" "${CORPUS}/_content/tour/delta.go"
expect_fail "same-count rename (count-only blind spot)" "corpus file set differs" gate
mv "${CORPUS}/_content/tour/delta.go" "${CORPUS}/_content/tour/alpha.go"

cp "${MINI}/_content/tour/gamma.go" "${CORPUS}/_content/tour/gamma.go"
expect_fail "excluded fragment smuggled into the corpus" "corpus file set differs" gate
rm -f "${CORPUS}/_content/tour/gamma.go"

echo "== probe family 4: file kind =="
rm "${CORPUS}/_content/tour/alpha.go"
ln -s beta.go "${CORPUS}/_content/tour/alpha.go"
expect_fail "symlink standing in for a source" "symlink" gate
rm "${CORPUS}/_content/tour/alpha.go"
cp "${WORK}/corpus.good/_content/tour/alpha.go" "${CORPUS}/_content/tour/alpha.go"

echo "== probe family 5: LICENSE =="
printf '\n' >> "${CORPUS}/LICENSE"
expect_fail "LICENSE file tamper" "corpus LICENSE" gate
restore_corpus

cp "${CPIN}" "${WORK}/cpin.good"
awk -F '\t' -v OFS='\t' -v s="0000000000000000000000000000000000000000000000000000000000000000" \
  '$1 !~ /^#/ && NF { $4 = s } { print }' "${CPIN}" > "${CPIN}.tmp" && mv "${CPIN}.tmp" "${CPIN}"
expect_fail "corpus pin LICENSE digest tamper" "corpus LICENSE sha256 mismatch" gate
cp "${WORK}/cpin.good" "${CPIN}"

echo "== probe family 6: corpus pin counts =="
# source_rows drift that keeps the internal counts consistent, so the join
# check (pin vs inventory executable rows) is what fires.
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF { $5 = 3; $6 = 4 } { print }' "${CPIN}" > "${CPIN}.tmp" && mv "${CPIN}.tmp" "${CPIN}"
expect_fail "corpus pin source_rows drift" "source_rows mismatch" gate
cp "${WORK}/cpin.good" "${CPIN}"
# corpus_files drifting off source_rows + 1 is caught at pin-parse time.
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF { $6 = 99 } { print }' "${CPIN}" > "${CPIN}.tmp" && mv "${CPIN}.tmp" "${CPIN}"
expect_fail "corpus pin corpus_files drift" "counts inconsistent" gate
cp "${WORK}/cpin.good" "${CPIN}"

echo "== probe family 7: join denominator is verified first =="
cp "${INV}" "${WORK}/inv.good"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $1 == "_content/tour/alpha.go" { $8 = "0" $8 } { print }' \
  "${INV}" > "${INV}.tmp" && mv "${INV}.tmp" "${INV}"
expect_fail "inventory row edit without repinning the pin hash" "inventory data sha256 mismatch" gate
cp "${WORK}/inv.good" "${INV}"

echo "== probe family 8: the hash-consistent attacker =="
# Edit the corpus source, rewrite the inventory row to match it, and repin
# the inventory hash — everything the offline gate can see is now consistent.
# The reviewed pin is the trust anchor, so this is the documented offline
# residual (asserted explicitly so a silent regression of the boundary is
# visible); TOUR_ROOT mode must still catch it against upstream bytes.
printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("alpha KO") }\n' \
  > "${CORPUS}/_content/tour/alpha.go"
new_sha="$(sha_of "${CORPUS}/_content/tour/alpha.go")"
awk -F '\t' -v OFS='\t' -v p="_content/tour/alpha.go" -v s="${new_sha}" \
  '$1 !~ /^#/ && NF && $1 == p { $8 = s } { print }' "${INV}" > "${INV}.tmp" && mv "${INV}.tmp" "${INV}"
write_pin
expect_ok "hash-consistent repin accepted offline (documented trust-anchor residual)" gate
expect_fail "hash-consistent repin caught by TOUR_ROOT copy proof" \
  "not byte-identical to the pinned source materialization" gate "${MINI}"
restore_corpus
write_inventory; write_pin; write_cpin

echo "== final control: the restored world is green again =="
expect_ok "final control (offline)"         gate
expect_ok "final control (TOUR_ROOT proof)" gate "${MINI}"

echo
echo "corpus tamper suite: ${pass} passed, ${fail} failed (${WORK})"
[ "${fail}" -eq 0 ] || exit 1
