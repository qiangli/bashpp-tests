#!/usr/bin/env bash
# Offline gate for the Go oracle's pin and tranche.
#
# This runs no Go code. It answers one question: is the denominator the reviewed
# one? Every row must exist in the pinned corpus inventory with the same action,
# the selection must still be exactly what the mechanical rule produces, and the
# per-action quotas must be met for all seven actions. A tranche that quietly
# shrank would make the oracle's "35/35 executed" true and meaningless.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${GO_ORACLE_PIN:-${ROOT}/docs/go-oracle/pin.tsv}"
CORPUS_PIN="${ROOT}/docs/go-corpus/pin.tsv"
INV="${GO_CORPUS_INVENTORY:-${ROOT}/docs/go-corpus/inventory.tsv}"

die() { echo "FATAL: $*" >&2; exit 2; }

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r release semantics_path semantics_sha256 tranche per_action tranche_rows actions \
  unsupported_actions aux_inventory toolchain_pin <<<"${pin_row}"

[ -n "${release:-}" ] || die "missing oracle pin"
case "${release}" in go1.27.*) ;; *) die "oracle pin release must be a reviewed Go 1.27 release: ${release}" ;; esac

corpus_release="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1; exit }' "${CORPUS_PIN}")"
[ "${release}" = "${corpus_release}" ] || \
  die "oracle release ${release} does not match corpus release ${corpus_release}"

[ "${semantics_path}" = "src/cmd/internal/testdir/testdir_test.go" ] || \
  die "unexpected upstream runner path: ${semantics_path}"
case "${semantics_sha256:-}" in *[!0-9a-f]*|'') die "semantics_sha256 must be lowercase hex" ;; esac
[ "${#semantics_sha256}" -eq 64 ] || die "semantics_sha256 must be 64 hex characters"

[ "${tranche}" = "docs/go-oracle/tranche-001.tsv" ] || die "unexpected tranche path: ${tranche}"
# GO_ORACLE_TRANCHE exists so the gate can be tested against a mutated copy
# without editing the reviewed file, mirroring GO_CORPUS_INVENTORY in
# tools/go-corpus/validate.sh.
TRANCHE_FILE="${GO_ORACLE_TRANCHE:-${ROOT}/${tranche}}"
[ -f "${TRANCHE_FILE}" ] || die "missing tranche: ${TRANCHE_FILE}"

case "${per_action:-}" in ''|*[!0-9]*) die "per_action must be an integer" ;; esac
case "${tranche_rows:-}" in ''|*[!0-9]*) die "tranche_rows must be an integer" ;; esac
[ "${per_action}" -gt 0 ] || die "per_action must be positive"
[ "${tranche_rows}" -gt 0 ] || die "tranche_rows must be positive"

EXPECTED_ACTIONS='run,build,errorcheck,compile,compiledir,rundir,runoutput'
[ "${actions}" = "${EXPECTED_ACTIONS}" ] || \
  die "oracle action set drifted: expected ${EXPECTED_ACTIONS}, got ${actions}"

# The bounded tranche must state its own boundary. The seven executed actions and
# the ten deliberately-unexecuted ones must together be exactly the vocabulary of
# the pinned upstream runner: an unclassified upstream action is how a seven
# action tranche starts being read as a full run.go.
EXPECTED_UNSUPPORTED='asmcheck,builddir,buildrun,buildrundir,errorcheckandrundir,errorcheckdir,errorcheckoutput,errorcheckwithauto,runindir,skip'
[ "${unsupported_actions}" = "${EXPECTED_UNSUPPORTED}" ] || \
  die "oracle unsupported-action set drifted: expected ${EXPECTED_UNSUPPORTED}, got ${unsupported_actions}"
overlap="$(printf '%s\n%s\n' "${actions//,/$'\n'}" "${unsupported_actions//,/$'\n'}" | sort | uniq -d)"
[ -z "${overlap}" ] || die "actions listed as both executed and unsupported: ${overlap}"
total_actions="$(printf '%s\n%s\n' "${actions//,/$'\n'}" "${unsupported_actions//,/$'\n'}" | grep -c .)"
[ "${total_actions}" -eq 17 ] || \
  die "the pinned upstream runner has 17 actions; the pin classifies ${total_actions}"

# ---------------------------------------------------------------------------
# Auxiliary provenance. The corpus inventory covers test/**/*.go only, so this
# is where the .out sidecars and the .dir manifests are pinned. An absent .out is
# a real row, because "no .out" means "must print nothing".
# ---------------------------------------------------------------------------
[ "${aux_inventory}" = "docs/go-oracle/aux-inventory.tsv" ] || \
  die "unexpected auxiliary inventory path: ${aux_inventory}"
AUX="${GO_ORACLE_AUX_INVENTORY:-${ROOT}/${aux_inventory}}"
[ -f "${AUX}" ] || die "missing auxiliary inventory: ${AUX}"

awk -F '\t' '
  $1 ~ /^#/ || NF == 0 { next }
  NF != 5 { printf "FATAL: malformed auxiliary row %d\n", NR > "/dev/stderr"; bad=1; next }
  $1 !~ /^(expected_output|dir_manifest|dir_input)$/ { printf "FATAL: unknown auxiliary role at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  $2 !~ /^test\// { printf "FATAL: auxiliary path outside go/test at row %d: %s\n", NR, $2 > "/dev/stderr"; bad=1 }
  $3 !~ /^(present|absent)$/ { printf "FATAL: bad presence at row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1 }
  $4 !~ /^[0-9]+$/ { printf "FATAL: bad byte/member count at row %d: %s\n", NR, $4 > "/dev/stderr"; bad=1 }
  $3 == "present" && $5 !~ /^[0-9a-f]{64}$/ { printf "FATAL: present auxiliary row %d has no sha256\n", NR > "/dev/stderr"; bad=1 }
  $3 == "absent"  && ($5 != "-" || $4 != "0") { printf "FATAL: absent auxiliary row %d must be 0/-\n", NR > "/dev/stderr"; bad=1 }
  seen[$1 SUBSEP $2]++ { printf "FATAL: duplicate auxiliary row %d: %s %s\n", NR, $1, $2 > "/dev/stderr"; bad=1 }
  { count++ }
  END { if (count == 0) { print "FATAL: auxiliary inventory has no rows" > "/dev/stderr"; bad=1 } exit bad ? 1 : 0 }
' "${AUX}" || exit 2

# Coverage: every tranche row whose action consumes a sidecar must have its row.
awk -F '\t' -v aux="${AUX}" '
  BEGIN {
    while ((getline line < aux) > 0) {
      if (substr(line, 1, 1) == "#" || line == "") continue
      split(line, f, "\t")
      have[f[1] SUBSEP f[2]] = 1
    }
  }
  $1 ~ /^#/ || NF == 0 { next }
  {
    base = $1; sub(/\.go$/, "", base)
    if ($2 == "run" || $2 == "rundir" || $2 == "runoutput") {
      if (!(("expected_output" SUBSEP base ".out") in have)) {
        printf "FATAL: %s consumes an expected-output sidecar with no auxiliary row\n", $1 > "/dev/stderr"; bad = 1
      }
    }
    if ($2 == "compiledir" || $2 == "rundir") {
      if (!(("dir_manifest" SUBSEP base ".dir") in have)) {
        printf "FATAL: %s compiles a .dir with no auxiliary manifest row\n", $1 > "/dev/stderr"; bad = 1
      }
    }
  }
  END { exit bad ? 1 : 0 }
' "${TRANCHE_FILE}" || exit 2

# ---------------------------------------------------------------------------
# Toolchain identity. `go version` is a string a shell script prints; the pin
# carries distribution checksums instead.
# ---------------------------------------------------------------------------
[ "${toolchain_pin}" = "docs/go-oracle/toolchain.tsv" ] || \
  die "unexpected toolchain pin path: ${toolchain_pin}"
TCPIN="${GO_ORACLE_TOOLCHAIN_PIN:-${ROOT}/${toolchain_pin}}"
[ -f "${TCPIN}" ] || die "missing toolchain pin: ${TCPIN}"

awk -F '\t' -v release="${release}" '
  $1 ~ /^#/ || NF == 0 { next }
  $1 == "goroot_probe" {
    if (NF != 3) { printf "FATAL: malformed goroot_probe row %d\n", NR > "/dev/stderr"; bad=1; next }
    if ($3 !~ /^[0-9a-f]{64}$/) { printf "FATAL: goroot_probe %s has no sha256\n", $2 > "/dev/stderr"; bad=1 }
    probes++
    next
  }
  $1 == "toolchain" {
    if (NF != 10) { printf "FATAL: malformed toolchain row %d\n", NR > "/dev/stderr"; bad=1; next }
    if ($2 != release) { printf "FATAL: toolchain row %d is for %s, pin says %s\n", NR, $2, release > "/dev/stderr"; bad=1 }
    if ($5 !~ /^[0-9a-f]{64}$/) { printf "FATAL: toolchain row %d has no go binary sha256\n", NR > "/dev/stderr"; bad=1 }
    if ($7 !~ /^[0-9a-f]{64}$/) { printf "FATAL: toolchain row %d has no published archive sha256\n", NR > "/dev/stderr"; bad=1 }
    if ($6 !~ /\.tar\.gz$|\.zip$|\.msi$|\.pkg$/) { printf "FATAL: toolchain row %d names no official archive\n", NR > "/dev/stderr"; bad=1 }
    if ($8 != "golang.org/toolchain") { printf "FATAL: toolchain row %d has an unexpected module origin: %s\n", NR, $8 > "/dev/stderr"; bad=1 }
    if ($10 !~ /^h1:/) { printf "FATAL: toolchain row %d has no module ziphash\n", NR > "/dev/stderr"; bad=1 }
    rows++
    next
  }
  { printf "FATAL: unknown toolchain pin record kind at row %d: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
  END {
    if (probes == 0) { print "FATAL: toolchain pin records no GOROOT probes" > "/dev/stderr"; bad=1 }
    if (rows == 0) { print "FATAL: toolchain pin records no distributions" > "/dev/stderr"; bad=1 }
    exit bad ? 1 : 0
  }
' "${TCPIN}" || exit 2

# The runner-semantics digest is one of the GOROOT probes, and it must be the
# same digest the driver gates on: two pins that disagree would let one of them
# pass while the other is stale.
probe_sem="$(awk -F '\t' -v p="${semantics_path}" '$1 == "goroot_probe" && $2 == p { print $3; exit }' "${TCPIN}")"
[ -n "${probe_sem}" ] || die "toolchain pin has no GOROOT probe for ${semantics_path}"
[ "${probe_sem}" = "${semantics_sha256}" ] || \
  die "toolchain pin and oracle pin disagree about ${semantics_path}: ${probe_sem} vs ${semantics_sha256}"

rows="$(awk -F '\t' '$1 !~ /^#/ && NF { count++ } END { print count + 0 }' "${TRANCHE_FILE}")"
[ "${rows}" -eq "${tranche_rows}" ] || \
  die "tranche denominator mismatch: pin says ${tranche_rows}, file has ${rows}"

# The selection rule is executable, so re-derive it instead of trusting the file.
regenerated="$(mktemp)"; current="$(mktemp)"
trap 'rm -f "${regenerated}" "${current}"' EXIT
"${ROOT}/tools/go-oracle/select-tranche.sh" "${per_action}" > "${regenerated}"
awk -F '\t' '$1 !~ /^#/ && NF { print }' "${TRANCHE_FILE}" > "${current}"
if ! diff -u "${regenerated}" "${current}" > /dev/null; then
  echo "FATAL: tranche does not match the mechanical selection rule" >&2
  diff -u "${regenerated}" "${current}" >&2 || true
  exit 2
fi

# Every row must still be the corpus row it claims to be.
awk -F '\t' -v inv="${INV}" -v want="${per_action}" -v actions="${EXPECTED_ACTIONS}" '
  BEGIN {
    while ((getline line < inv) > 0) {
      if (substr(line, 1, 1) == "#" || line == "") continue
      split(line, f, "\t")
      invaction[f[1]] = f[2]
    }
    n = split(actions, a, ",")
  }
  $1 ~ /^#/ || NF == 0 { next }
  {
    if (NF != 2) { printf "FATAL: malformed tranche row %d\n", NR > "/dev/stderr"; bad = 1; next }
    if (!($1 in invaction)) { printf "FATAL: tranche path absent from corpus inventory: %s\n", $1 > "/dev/stderr"; bad = 1; next }
    if (invaction[$1] != $2) {
      printf "FATAL: tranche action drift for %s: inventory says %s, tranche says %s\n", $1, invaction[$1], $2 > "/dev/stderr"
      bad = 1
    }
    if (seen[$1]++) { printf "FATAL: duplicate tranche path: %s\n", $1 > "/dev/stderr"; bad = 1 }
    if (prev != "" && $1 <= prev) { printf "FATAL: tranche path order regression at row %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    prev = $1
    count[$2]++
  }
  END {
    for (i = 1; i <= n; i++) {
      if (count[a[i]] != want) {
        printf "FATAL: action %s has %d rows, expected %d\n", a[i], count[a[i]] + 0, want > "/dev/stderr"
        bad = 1
      }
    }
    exit bad ? 1 : 0
  }
' "${TRANCHE_FILE}" || exit 2

aux_rows="$(awk -F '\t' '$1 !~ /^#/ && NF { c++ } END { print c + 0 }' "${AUX}")"
echo "Go oracle tranche OK: ${release} ${rows}/${tranche_rows} across ${actions}"
echo "  bounded scope: 7 of the upstream runner's 17 actions; NOT run: ${unsupported_actions}"
echo "  auxiliary provenance OK: ${aux_rows} pinned .out/.dir rows"
echo "  toolchain identity pin OK: ${toolchain_pin}"
