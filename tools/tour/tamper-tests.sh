#!/usr/bin/env bash
# Tamper self-tests for the tour Go-baseline runner and its results gate.
#
# Sprint 98 / Story #5 / Story-ID 4895df27bdb9.
#
# Every probe runs the REAL tools/tour/run-baseline.sh and
# tools/tour/validate-results.sh against a miniature pinned world (two
# executable programs, one excluded fragment, one inline prose row) via env
# overrides, then mutates exactly one pinned fact and proves the gate fails
# closed with the expected diagnosis. A probe whose mutation is ACCEPTED is
# a failure of this suite. Hash-consistent tampering (attacker recomputes
# records_sha256 AND updates the baseline pin) is probed too — the semantic
# checks, not just the hash, must catch it.
#
# Probe families (as required by the story):
#   1. source hashes        - same-byte-count content edit (sha-only signal)
#   2. byte counts          - inventory bytes field drifts from the file
#   3. modes                - pinned source made writable (0644), and a
#                             record claiming a non-0444 mode
#   4. result records       - field edit, dropped row, row for an excluded
#                             path, and hash-consistent outcome rewrites
#   5. baseline status      - baseline token flipped against the schema
#                             coupling; run_exit flipped to nonzero
#   plus runner-behavior probes:
#   6. missing source       - a pinned row whose file vanished
#   7. invalid UTF-8        - a program emitting non-UTF-8 bytes is
#                             REJECTED and recorded as fail:invalid-utf8,
#                             never replaced or transliterated
#   8. bounded process tree - a program that spawns a child and blocks
#                             forever is TERMed/KILLed at the bound; the
#                             child dies with it, the scratch tree is
#                             removed, and the runner exits nonzero
#
# Usage: tools/tour/tamper-tests.sh
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="${ROOT}/tools/tour/run-baseline.sh"
VALIDATOR="${ROOT}/tools/tour/validate-results.sh"
GOMODCACHE_DIR="$(go env GOMODCACHE)"
REAL_SRC="${GOMODCACHE_DIR}/golang.org/x/website@$(awk -F '\t' '$1 !~ /^#/ && NF { print $2; exit }' "${ROOT}/docs/tour/pin.tsv")"
VERSION="$(awk -F '\t' '$1 !~ /^#/ && NF { print $2; exit }' "${ROOT}/docs/tour/pin.tsv")"
COMMIT="$(awk -F '\t' '$1 !~ /^#/ && NF { print $3; exit }' "${ROOT}/docs/tour/pin.tsv")"

[ -x "${RUNNER}" ] || { echo "FATAL: ${RUNNER} not executable" >&2; exit 2; }
[ -x "${VALIDATOR}" ] || { echo "FATAL: ${VALIDATOR} not executable" >&2; exit 2; }
[ -f "${REAL_SRC}/LICENSE" ] || { echo "FATAL: pinned x/website source not in module cache (${REAL_SRC}); run the acquisition in docs/tour/pin.tsv first" >&2; exit 2; }

WORK_BASE="${ROOT}/.cache/tour/tamper"
mkdir -p "${WORK_BASE}"
WORK="$(mktemp -d "${WORK_BASE}.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
LOG="${WORK}/probe.log"

pass=0 fail=0
ok()   { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }

# expect_fail <label> <expected-marker> <cmd...> : command must exit nonzero
# AND print the marker (a mutation that fails for the WRONG reason, or is
# accepted, does not pass the probe).
expect_fail() {
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

# ------------------------------------------------- miniature pinned world --
MINI="${WORK}/src"
mkdir -p "${MINI}/_content/tour"
printf 'module golang.org/x/website\n' > "${MINI}/go.mod"
cp "${REAL_SRC}/LICENSE" "${MINI}/LICENSE"

printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("alpha ok") }\n' \
  > "${MINI}/_content/tour/alpha.go"
printf '//go:build OMIT && norun\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("beta ok") }\n' \
  > "${MINI}/_content/tour/beta.go"
printf '//go:build OMIT nobuild\n\npackage main\n\nfunc main() { fmt.Println("gamma skeleton") }\n' \
  > "${MINI}/_content/tour/gamma.go"
# The pinned world is the read-only module-cache materialization.
chmod 444 "${MINI}/_content/tour/alpha.go" "${MINI}/_content/tour/beta.go" "${MINI}/_content/tour/gamma.go"

inventory_rows() { # appends the well-formed mini inventory to stdout
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

write_inventory() { # write_inventory <file> [extra-row-generator...]
  local out="$1"; shift
  {
    echo "# release	golang.org/x/website@${VERSION}"
    echo "# commit	${COMMIT}"
    echo "# go_mod_sum	pinned"
    echo "# source	https://go.googlesource.com/website"
    echo "# license	BSD-3-Clause"
    echo "# generated_by	tools/tour/refresh.sh"
    echo "# path	kind	start_line	applicability	exception	differential_schema	bytes	sha256"
    inventory_rows
    if [ "$#" -gt 0 ] && [ -n "$1" ]; then cat "$1"; fi
  } > "${out}"
}

INV="${WORK}/inv.tsv"
write_inventory "${INV}" ""

RESULTS="${WORK}/results.tsv"
BPIN="${WORK}/baseline-pin.tsv"

run_mini() { # run_mini <results> <bpin> — runs the real runner on the mini world
  local res="$1" bp="$2"
  env TOUR_ROOT="${MINI}" TOUR_INVENTORY="${INV}" TOUR_RESULTS="${res}" \
      TOUR_BASELINE_PIN="${bp}" TOUR_RUN_ROOT="${WORK}/run" \
      TOUR_BUILD_TIMEOUT="${TOUR_BUILD_TIMEOUT:-90}" TOUR_RUN_TIMEOUT="${TOUR_RUN_TIMEOUT:-10}" \
      "${ROOT}/tools/tour/run-baseline.sh"
}
val_mini() { # val_mini <results> <bpin> — runs the real offline gate
  env TOUR_INVENTORY="${INV}" TOUR_RESULTS="$1" TOUR_BASELINE_PIN="$2" \
      "${ROOT}/tools/tour/validate-results.sh"
}

# repin_results <results-file> <bpin-file> : recompute records_sha256, patch
# the results header and the baseline pin — the hash-consistent attacker.
repin_results() {
  local res="$1" bp="$2" n sha
  n="$(awk '$0 !~ /^#/ && NF' "${res}" | wc -l | tr -d ' ')"
  sha="$(awk '$0 !~ /^#/ && NF' "${res}" | shasum -a 256 | awk '{print $1}')"
  awk -F '\t' -v OFS='\t' -v n="${n}" -v sha="${sha}" '
    $1 == "# records"        { $2 = n; print; next }
    $1 == "# records_sha256" { $2 = sha; print; next }
    { print }' "${res}" > "${res}.tmp" && mv "${res}.tmp" "${res}"
  awk -F '\t' -v OFS='\t' -v n="${n}" -v sha="${sha}" '
    $1 !~ /^#/ && NF { $6 = n; $7 = sha; print; next }
    { print }' "${bp}" > "${bp}.tmp" && mv "${bp}.tmp" "${bp}"
}

restore_sources() {
  chmod u+w "${MINI}/_content/tour/alpha.go" 2>/dev/null || true
  printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("alpha ok") }\n' \
    > "${MINI}/_content/tour/alpha.go"
  chmod 444 "${MINI}/_content/tour/alpha.go"
}

# The source tree models a module-cache checkout: directories are writable
# for probe setup, while pinned program files must remain mode 0444.
find "${MINI}" -type d -exec chmod u+rwx {} + 2>/dev/null || true
find "${MINI}" -type f -name '*.go' -exec chmod 444 {} + 2>/dev/null || true

echo "== probe 0: control — the miniature world must run green first =="
expect_ok "control run"        run_mini "${RESULTS}" "${BPIN}"
expect_ok "control validation" val_mini "${RESULTS}" "${BPIN}"
cp "${RESULTS}" "${WORK}/results.good.tsv"
cp "${BPIN}"    "${WORK}/bpin.good.tsv"

echo "== probe family 1: source hashes =="
# Same byte count, different bytes: only the sha256 can catch this.
chmod u+w "${MINI}/_content/tour/alpha.go"
printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Println("alpha KO") }\n' \
  > "${MINI}/_content/tour/alpha.go"
expect_fail "source-sha tamper (same byte count)" \
  "source sha256 tamper" run_mini "${RESULTS}.probe1" "${BPIN}.probe1"
restore_sources

echo "== probe family 2: byte counts =="
# Inventory bytes drift off the real file; the sha still matches the file.
inv_bytes="$(awk -F '\t' '$1 == "_content/tour/alpha.go" { print $7 }' "${INV}")"
bumped=$((inv_bytes + 1))
awk -F '\t' -v OFS='\t' -v p="_content/tour/alpha.go" -v b="${bumped}" \
  '$1 !~ /^#/ && NF && $1 == p { $7 = b } { print }' "${INV}" > "${INV}.tmp" && mv "${INV}.tmp" "${INV}"
expect_fail "byte-count tamper" \
  "source byte-count tamper" run_mini "${RESULTS}.probe2" "${BPIN}.probe2"
write_inventory "${INV}" ""

echo "== probe family 3: modes =="
chmod 644 "${MINI}/_content/tour/alpha.go"
expect_fail "writable pinned source (0644)" \
  "source mode tampered" run_mini "${RESULTS}.probe3" "${BPIN}.probe3"
restore_sources
cp "${WORK}/results.good.tsv" "${RESULTS}.probe3b"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe3b"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $1 == "_content/tour/alpha.go" { $5 = "644" } { print }' \
  "${RESULTS}.probe3b" > "${RESULTS}.probe3b.tmp" && mv "${RESULTS}.probe3b.tmp" "${RESULTS}.probe3b"
repin_results "${RESULTS}.probe3b" "${BPIN}.probe3b"
expect_fail "record claims non-0444 mode (hash-consistent)" \
  "must be read-only 444" val_mini "${RESULTS}.probe3b" "${BPIN}.probe3b"

echo "== probe family 4: result records =="
cp "${WORK}/results.good.tsv" "${RESULTS}.probe4a"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe4a"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $1 == "_content/tour/alpha.go" { $10 = "deadbeef" $10 } { print }' \
  "${RESULTS}.probe4a" > "${RESULTS}.probe4a.tmp" && mv "${RESULTS}.probe4a.tmp" "${RESULTS}.probe4a"
expect_fail "stdout sha256 field edit" \
  "records_sha256 mismatch" val_mini "${RESULTS}.probe4a" "${BPIN}.probe4a"

cp "${WORK}/results.good.tsv" "${RESULTS}.probe4b"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe4b"
awk -F '\t' -v OFS='\t' '$0 ~ /^#/ || NF == 0 || $1 != "_content/tour/alpha.go"' "${RESULTS}.probe4b" > "${RESULTS}.probe4b.tmp" \
  && mv "${RESULTS}.probe4b.tmp" "${RESULTS}.probe4b"
repin_results "${RESULTS}.probe4b" "${BPIN}.probe4b"
expect_fail "dropped record (hash-consistent)" \
  "missing record for executable inventory row" val_mini "${RESULTS}.probe4b" "${BPIN}.probe4b"

cp "${WORK}/results.good.tsv" "${RESULTS}.probe4c"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe4c"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $1 == "_content/tour/alpha.go" { $14 = "fail:run-exit:1" } { print }' \
  "${RESULTS}.probe4c" > "${RESULTS}.probe4c.tmp" && mv "${RESULTS}.probe4c.tmp" "${RESULTS}.probe4c"
repin_results "${RESULTS}.probe4c" "${BPIN}.probe4c"
expect_fail "outcome flipped to fail (hash-consistent)" \
  "outcome fail:run-exit:1" val_mini "${RESULTS}.probe4c" "${BPIN}.probe4c"

# A record for an excluded/unknown path is unexpected, hash-consistent or not.
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $1 == "_content/tour/alpha.go" { $1 = "_content/tour/gamma.go" } { print }' \
  "${WORK}/results.good.tsv" > "${RESULTS}.probe4d"
cp "${WORK}/bpin.good.tsv" "${BPIN}.probe4d"
repin_results "${RESULTS}.probe4d" "${BPIN}.probe4d"
expect_fail "record for an excluded path (hash-consistent)" \
  "non-executable or unknown path" val_mini "${RESULTS}.probe4d" "${BPIN}.probe4d"

echo "== probe family 5: baseline status =="
cp "${WORK}/results.good.tsv" "${RESULTS}.probe5a"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe5a"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $2 == "build_only_go_program" { $6 = "go-run" } { print }' \
  "${RESULTS}.probe5a" > "${RESULTS}.probe5a.tmp" && mv "${RESULTS}.probe5a.tmp" "${RESULTS}.probe5a"
repin_results "${RESULTS}.probe5a" "${BPIN}.probe5a"
expect_fail "build-only baseline token flipped to go-run (hash-consistent)" \
  "baseline token go-run must follow the schema coupling" val_mini "${RESULTS}.probe5a" "${BPIN}.probe5a"

cp "${WORK}/results.good.tsv" "${RESULTS}.probe5b"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe5b"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF && $1 == "_content/tour/alpha.go" { $8 = "1" } { print }' \
  "${RESULTS}.probe5b" > "${RESULTS}.probe5b.tmp" && mv "${RESULTS}.probe5b.tmp" "${RESULTS}.probe5b"
repin_results "${RESULTS}.probe5b" "${BPIN}.probe5b"
expect_fail "applicable run_exit flipped to 1 (hash-consistent)" \
  "run_exit 1" val_mini "${RESULTS}.probe5b" "${BPIN}.probe5b"

echo "== extra runner probes: missing source, toolchain identity =="
mv "${MINI}/_content/tour/alpha.go" "${WORK}/alpha.go.hidden"
expect_fail "missing pinned source" \
  "missing pinned source" run_mini "${RESULTS}.probe6" "${BPIN}.probe6"
mv "${WORK}/alpha.go.hidden" "${MINI}/_content/tour/alpha.go"

cp "${WORK}/results.good.tsv" "${RESULTS}.probe7"
cp "${WORK}/bpin.good.tsv"    "${BPIN}.probe7"
awk -F '\t' -v OFS='\t' -v id="go version go9.9.9 $(uname -m)" \
  '$1 == "# toolchain" { $2 = id } { print }' "${RESULTS}.probe7" > "${RESULTS}.probe7.tmp" && mv "${RESULTS}.probe7.tmp" "${RESULTS}.probe7"
expect_fail "results recorded under an unpinned toolchain identity" \
  "not a pinned row" val_mini "${RESULTS}.probe7" "${BPIN}.probe7"

echo "== runner probe: invalid UTF-8 is rejected, not replaced =="
printf '//go:build OMIT\n\npackage main\n\nimport "fmt"\n\nfunc main() { fmt.Print("delta \\xff\\xfe raw") }\n' \
  > "${MINI}/_content/tour/delta.go"
chmod 444 "${MINI}/_content/tour/delta.go"
d_sha="$(sha_of "${MINI}/_content/tour/delta.go")"
d_bytes="$(bytes_of "${MINI}/_content/tour/delta.go")"
{ printf '_content/tour/delta.go\tlesson_play_program\tn/a\tapplicable_go_program\texception:none\tbaseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run\t%s\t%s\n' \
    "${d_bytes}" "${d_sha}"; } > "${WORK}/delta-row.tsv"
write_inventory "${INV}" "${WORK}/delta-row.tsv"
rc=0
run_mini "${RESULTS}.probe8" "${BPIN}.probe8" > "${LOG}" 2>&1 || rc=$?
if [ "${rc}" -eq 0 ]; then
  bad "invalid-utf8 run: REJECTED output was ACCEPTED (exit 0)"
elif ! grep -qF "REJECTED non-UTF-8" "${LOG}"; then
  bad "invalid-utf8 run: exit ${rc} but no REJECTED marker"
  sed -n '1,5p' "${LOG}" | sed 's/^/    /' >&2
elif ! grep -qF "fail:invalid-utf8" "${RESULTS}.probe8"; then
  bad "invalid-utf8 run: outcome not recorded as fail:invalid-utf8"
else
  ok "invalid UTF-8 rejected and recorded (exit ${rc})"
fi
rm -f "${MINI}/_content/tour/delta.go"
write_inventory "${INV}" ""

echo "== runner probe: bounded process-tree and scratch cleanup =="
chmod u+w "${MINI}"
cat > "${MINI}/_content/tour/omega.go" <<'EOF'
//go:build OMIT

package main

import (
	"fmt"
	"os/exec"
	"time"
)

func main() {
	// A child in the same process group that outlives a naive parent kill.
	exec.Command("sleep", "37").Start()
	fmt.Println("omega started")
	for {
		time.Sleep(time.Hour)
	}
}
EOF
o_sha="$(sha_of "${MINI}/_content/tour/omega.go")"
o_bytes="$(bytes_of "${MINI}/_content/tour/omega.go")"
chmod 444 "${MINI}/_content/tour/omega.go"
{ printf '_content/tour/omega.go\tlesson_play_program\tn/a\tapplicable_go_program\texception:none\tbaseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run\t%s\t%s\n' \
    "${o_bytes}" "${o_sha}"; } > "${WORK}/omega-row.tsv"
write_inventory "${INV}" "${WORK}/omega-row.tsv"
SECONDS=0
rc=0
env TOUR_ROOT="${MINI}" TOUR_INVENTORY="${INV}" TOUR_RESULTS="${RESULTS}.probe9" \
    TOUR_BASELINE_PIN="${BPIN}.probe9" TOUR_RUN_ROOT="${WORK}/omega-run" \
    TOUR_RUN_TIMEOUT=2 TOUR_KILL_GRACE=1 \
    "${RUNNER}" > "${LOG}" 2>&1 || rc=$?
elapsed="${SECONDS}"
leftovers="$(pgrep -fl 'sleep 37' || true)"
scratch_left="$(ls -d "${WORK}"/omega-run.* 2>/dev/null || true)"
if [ "${rc}" -eq 0 ]; then
  bad "bounded run: unbounded program was ACCEPTED (exit 0)"
else
  if [ -n "${leftovers}" ]; then
    bad "bounded run: child survived the process-tree kill: ${leftovers}"
  elif [ -n "${scratch_left}" ]; then
    bad "bounded run: scratch run root not cleaned: ${scratch_left}"
  elif [ "${elapsed}" -gt 30 ]; then
    bad "bounded run: took ${elapsed}s — the bound did not hold"
  elif ! grep -qF "run FAILED" "${LOG}"; then
    bad "bounded run: exit ${rc} but no failed-row diagnosis"
  else
    ok "bounded process-tree kill + cleanup (${elapsed}s, exit ${rc})"
  fi
fi
rm -f "${MINI}/_content/tour/omega.go"
write_inventory "${INV}" ""

echo
echo "tamper suite: ${pass} passed, ${fail} failed (${WORK})"
[ "${fail}" -eq 0 ] || exit 1
