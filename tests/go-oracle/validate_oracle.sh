#!/usr/bin/env bash
# Self-tests for the Go oracle.
#
# Two layers, because the oracle has two ways to lie.
#
#   1. The offline gate can pass while the denominator has quietly moved. Those
#      cases mutate the pin and the tranche and demand a rejection.
#   2. The driver can report results it never earned. Those cases live in
#      tools/go-oracle/oracle_test.go, which sabotages sources, expectations and
#      the toolchain itself; they are run from here so one command covers both.
#
# When a refreshed corpus is present, the real tranche is executed and its
# machine-readable output is checked for the fields this slice promises.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/go-oracle/pin.tsv"
TRANCHE="${ROOT}/docs/go-oracle/tranche-001.tsv"
AUX="${ROOT}/docs/go-oracle/aux-inventory.tsv"
TCPIN="${ROOT}/docs/go-oracle/toolchain.tsv"
VALIDATE="${ROOT}/tools/go-oracle/validate-tranche.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() { echo "$*" >&2; exit 1; }

# reject <name> — the validator must refuse whatever is staged in ${tmp}.
reject() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    fail "expected the oracle gate to reject: ${name}"
  fi
}

"${VALIDATE}" >/dev/null || fail "the oracle gate rejects the reviewed pin and tranche"

# --- tranche mutations ------------------------------------------------------

awk 'BEGIN { done=0 } /^#/ { print; next } !done { done=1; next } { print }' \
  "${TRANCHE}" > "${tmp}/missing-row.tsv"
reject "a dropped tranche row" env GO_ORACLE_TRANCHE="${tmp}/missing-row.tsv" "${VALIDATE}"

awk 'BEGIN { done=0 } /^#/ { print; next } !done { print; print; done=1; next } { print }' \
  "${TRANCHE}" > "${tmp}/duplicate.tsv"
reject "a duplicated tranche row" env GO_ORACLE_TRANCHE="${tmp}/duplicate.tsv" "${VALIDATE}"

awk '/^#/ { print; next } n == 0 { held = $0; n = 1; next } n == 1 { print; print held; n = 2; next } { print }' \
  "${TRANCHE}" > "${tmp}/unsorted.tsv"
reject "tranche order drift" env GO_ORACLE_TRANCHE="${tmp}/unsorted.tsv" "${VALIDATE}"

# Same row count, wrong action: the selection still "looks" 35 rows long.
awk -F '\t' 'BEGIN { OFS="\t"; done=0 } /^#/ { print; next } !done && $2 == "run" { $2 = "compile"; done=1 } { print }' \
  "${TRANCHE}" > "${tmp}/action-drift.tsv"
reject "a tranche action that contradicts the inventory" \
  env GO_ORACLE_TRANCHE="${tmp}/action-drift.tsv" "${VALIDATE}"

# Substituting a path keeps the count and the quotas but breaks the rule.
awk -F '\t' 'BEGIN { OFS="\t"; done=0 } /^#/ { print; next } !done && $2 == "compile" { $1 = "test/zzz_not_selected.go"; done=1 } { print }' \
  "${TRANCHE}" > "${tmp}/substituted.tsv"
reject "a substituted tranche path" env GO_ORACLE_TRANCHE="${tmp}/substituted.tsv" "${VALIDATE}"

# --- pin mutations ----------------------------------------------------------

sed 's/\tdocs\/go-oracle\/tranche-001.tsv\t5\t35\t/\tdocs\/go-oracle\/tranche-001.tsv\t5\t34\t/' \
  "${PIN}" > "${tmp}/pin-count.tsv"
reject "a pin whose denominator no longer matches the tranche" \
  env GO_ORACLE_PIN="${tmp}/pin-count.tsv" "${VALIDATE}"

sed 's/run,build,errorcheck,compile,compiledir,rundir,runoutput/run,build,errorcheck,compile/' \
  "${PIN}" > "${tmp}/pin-actions.tsv"
reject "a pin that narrows the committed action set" \
  env GO_ORACLE_PIN="${tmp}/pin-actions.tsv" "${VALIDATE}"

sed 's/^go1\.27\.0\t/go1.27.99\t/' "${PIN}" > "${tmp}/pin-release.tsv"
reject "an oracle release that disagrees with the corpus pin" \
  env GO_ORACLE_PIN="${tmp}/pin-release.tsv" "${VALIDATE}"

sed 's/\t54900709[0-9a-f]*\t/\tnot-a-digest\t/' "${PIN}" > "${tmp}/pin-digest.tsv"
reject "a malformed upstream-runner digest" \
  env GO_ORACLE_PIN="${tmp}/pin-digest.tsv" "${VALIDATE}"

sed 's/\t5\t35\t/\t4\t35\t/' "${PIN}" > "${tmp}/pin-quota.tsv"
reject "a per-action quota that no longer produces the tranche" \
  env GO_ORACLE_PIN="${tmp}/pin-quota.tsv" "${VALIDATE}"

# --- the bounded scope must stay stated --------------------------------------
#
# Seven of upstream's seventeen actions are executed. If the other ten stop
# being enumerated, or start overlapping the seven, the pin is quietly claiming
# a full run.go.

sed 's/asmcheck,builddir/builddir/' "${PIN}" > "${tmp}/pin-drop-unsupported.tsv"
reject "a pin that stops enumerating an unsupported upstream action" \
  env GO_ORACLE_PIN="${tmp}/pin-drop-unsupported.tsv" "${VALIDATE}"

sed 's/asmcheck,builddir/run,builddir/' "${PIN}" > "${tmp}/pin-overlap.tsv"
reject "an action listed as both executed and unsupported" \
  env GO_ORACLE_PIN="${tmp}/pin-overlap.tsv" "${VALIDATE}"

# --- auxiliary provenance mutations ------------------------------------------
#
# The corpus inventory covers *.go only. These rows are the .out sidecars and
# the .dir manifests, and a .out file IS an expected result — so the gate has to
# refuse a malformed or self-contradicting auxiliary inventory as loudly as a
# malformed tranche.

awk 'BEGIN { done=0 } /^#/ { print; next } !done && $1 == "expected_output" { done=1; next } { print }' \
  "${AUX}" > "${tmp}/aux-missing.tsv"
reject "an auxiliary inventory missing a consumed sidecar row" \
  env GO_ORACLE_AUX_INVENTORY="${tmp}/aux-missing.tsv" "${VALIDATE}"

awk 'BEGIN { done=0 } /^#/ { print; next } !done && $1 == "dir_manifest" { done=1; next } { print }' \
  "${AUX}" > "${tmp}/aux-no-manifest.tsv"
reject "an auxiliary inventory missing a compiled .dir manifest" \
  env GO_ORACLE_AUX_INVENTORY="${tmp}/aux-no-manifest.tsv" "${VALIDATE}"

awk -F '\t' 'BEGIN { OFS="\t"; done=0 } /^#/ { print; next } !done && $3 == "absent" { $3 = "present"; done=1 } { print }' \
  "${AUX}" > "${tmp}/aux-absent-flip.tsv"
reject "an absent sidecar row rewritten as present without a digest" \
  env GO_ORACLE_AUX_INVENTORY="${tmp}/aux-absent-flip.tsv" "${VALIDATE}"

awk -F '\t' 'BEGIN { OFS="\t"; done=0 } /^#/ { print; next } !done && $3 == "present" { $5 = "not-a-digest"; done=1 } { print }' \
  "${AUX}" > "${tmp}/aux-bad-digest.tsv"
reject "a malformed auxiliary digest" \
  env GO_ORACLE_AUX_INVENTORY="${tmp}/aux-bad-digest.tsv" "${VALIDATE}"

awk 'BEGIN { done=0 } /^#/ { print; next } !done { print; print; done=1; next } { print }' \
  "${AUX}" > "${tmp}/aux-duplicate.tsv"
reject "a duplicated auxiliary row" \
  env GO_ORACLE_AUX_INVENTORY="${tmp}/aux-duplicate.tsv" "${VALIDATE}"

# --- toolchain identity pin mutations ----------------------------------------
#
# `go version` is forgeable, so these rows are what actually identify the
# toolchain. A pin that lost its checksums would demote the gate back to the
# forgeable string without saying so.

awk '$1 != "toolchain"' "${TCPIN}" > "${tmp}/tc-no-dist.tsv"
reject "a toolchain pin with no reviewed distribution" \
  env GO_ORACLE_TOOLCHAIN_PIN="${tmp}/tc-no-dist.tsv" "${VALIDATE}"

awk '$1 != "goroot_probe"' "${TCPIN}" > "${tmp}/tc-no-probes.tsv"
reject "a toolchain pin with no GOROOT source probes" \
  env GO_ORACLE_TOOLCHAIN_PIN="${tmp}/tc-no-probes.tsv" "${VALIDATE}"

awk -F '\t' 'BEGIN { OFS="\t" } $1 == "toolchain" { $5 = "not-a-digest" } { print }' \
  "${TCPIN}" > "${tmp}/tc-bad-go-digest.tsv"
reject "a toolchain pin whose go binary digest is malformed" \
  env GO_ORACLE_TOOLCHAIN_PIN="${tmp}/tc-bad-go-digest.tsv" "${VALIDATE}"

awk -F '\t' 'BEGIN { OFS="\t" } $1 == "toolchain" { $7 = "" } { print }' \
  "${TCPIN}" > "${tmp}/tc-no-origin.tsv"
reject "a toolchain pin with no published archive checksum" \
  env GO_ORACLE_TOOLCHAIN_PIN="${tmp}/tc-no-origin.tsv" "${VALIDATE}"

awk -F '\t' 'BEGIN { OFS="\t" } $1 == "goroot_probe" && $2 ~ /testdir_test\.go$/ { $3 = "0000000000000000000000000000000000000000000000000000000000000000" } { print }' \
  "${TCPIN}" > "${tmp}/tc-sem-drift.tsv"
reject "a toolchain pin that disagrees with the oracle pin about the runner digest" \
  env GO_ORACLE_TOOLCHAIN_PIN="${tmp}/tc-sem-drift.tsv" "${VALIDATE}"

echo "go-oracle gate self-tests OK"

# --- driver mutation tests --------------------------------------------------

if [ "${GO_ORACLE_SKIP_DRIVER_TESTS:-0}" = 1 ]; then
  echo "go-oracle driver mutation tests SKIPPED by request"
  exit 0
fi

GOTOOL="$("${ROOT}/tools/go-oracle/gotool.sh")" \
  || fail "cannot resolve the pinned Go toolchain; see tools/go-oracle/gotool.sh"
GO_ORACLE_GOTOOL="${GOTOOL}" "${GOTOOL}" -C "${ROOT}/tools/go-oracle" test -count=1 ./... \
  || fail "go-oracle driver mutation tests failed"

# --- end-to-end on the real corpus -----------------------------------------

release="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1; exit }' "${PIN}")"
CORPUS="${GO_CORPUS_ROOT:-${ROOT}/.cache/go-corpus/${release}}"
if [ ! -d "${CORPUS}/test" ]; then
  echo "NOTE: no refreshed corpus at ${CORPUS}; skipping the end-to-end tranche run." >&2
  echo "      Run tools/go-corpus/refresh.sh to enable it." >&2
  exit 0
fi

# The auxiliary inventory is mechanically derived, so re-derive it and diff
# rather than trusting the committed copy.
"${ROOT}/tools/go-oracle/select-aux.sh" "${CORPUS}" > "${tmp}/aux-regenerated.tsv" \
  || fail "cannot re-derive the auxiliary inventory"
if ! diff -u "${tmp}/aux-regenerated.tsv" "${AUX}" > "${tmp}/aux.diff"; then
  cat "${tmp}/aux.diff" >&2
  fail "the auxiliary inventory does not match the mechanical rule"
fi

# And the reviewed GOROOT probes must be the bytes of the officially checksummed
# source release that tools/go-corpus/refresh.sh verified.
while IFS=$'\t' read -r kind probe digest; do
  [ "${kind}" = goroot_probe ] || continue
  actual="$(shasum -a 256 "${CORPUS}/${probe}" | awk '{print $1}')" \
    || fail "the pinned source release has no ${probe}"
  [ "${actual}" = "${digest}" ] || \
    fail "toolchain GOROOT probe ${probe} does not match the verified source release"
done < <(awk -F '\t' '$1 !~ /^#/ && NF' "${TCPIN}")

out="${tmp}/out"
GO_ORACLE_OUT_DIR="${out}" "${ROOT}/tools/go-oracle/run.sh" >/dev/null \
  || fail "the oracle failed on the reviewed tranche"

summary="${out}/tranche-001.summary.json"
results="${out}/tranche-001.results.jsonl"
[ -f "${summary}" ] || fail "no summary was written"
[ -f "${results}" ] || fail "no per-file results were written"

field() { awk -F '[:,]' -v k="\"$1\"" '$1 ~ k { gsub(/[ "]/, "", $2); print $2; exit }' "${summary}"; }

rows="$(awk -F '\t' '$1 !~ /^#/ && NF { count++ } END { print count + 0 }' "${TRANCHE}")"
lines="$(wc -l < "${results}" | tr -d ' ')"

[ "$(field selected)" = "${rows}" ] || fail "summary selected != tranche rows"
[ "$(field reported)" = "${rows}" ] || fail "summary reported != tranche rows"
[ "$(field executed)" = "${rows}" ] || fail "summary executed != tranche rows"
[ "${lines}" = "${rows}" ]         || fail "results have ${lines} records for ${rows} tranche rows"
[ "$(field verdict)" = "pass" ]    || fail "the oracle did not pass the reviewed tranche"
[ "$(field commands)" -ge "${rows}" ] || fail "fewer commands than files; something did not execute"

# Every action in the committed set must have really executed, and every record
# must carry the promised fields.
for action in run build errorcheck compile compiledir rundir runoutput; do
  grep -q "\"action\":\"${action}\"" "${results}" || fail "no executed result for action ${action}"
done
for key in '"command":\[' '"exit":' '"duration_ms":' '"action":' '"artifact":' '"artifact_kind":' '"steps":\['; do
  missing="$(grep -cv -- "${key}" "${results}" || true)"
  [ "${missing}" = 0 ] || fail "${missing} result records are missing ${key}"
done

# The bounded scope has to travel with the machine-readable result, not only in
# prose: a summary that says "35/35 pass" and nothing else is exactly what gets
# quoted as if upstream's whole runner were green.
grep -q '"scope"' "${summary}" || fail "the summary does not state its scope"
grep -q "NOT upstream's full runner" "${summary}" || fail "the summary does not deny being upstream's runner"
for unsupported in asmcheck builddir buildrun buildrundir errorcheckandrundir \
                   errorcheckdir errorcheckoutput errorcheckwithauto runindir skip; do
  grep -q "\"${unsupported}\":" "${summary}" || fail "the summary does not disclaim the ${unsupported} action"
done

# Toolchain identity, and the fact that it is stronger than `go version`.
grep -q '"go_sha256"' "${summary}"   || fail "the summary records no toolchain binary digest"
grep -q '"dist_sha256"' "${summary}" || fail "the summary records no published distribution checksum"
grep -q '"module_ziphash"' "${summary}" || fail "the summary records no module-proxy origin"
grep -q '"goroot_probes"' "${summary}" || fail "the summary records no GOROOT source probes"
grep -q '"go_env"' "${summary}" || fail "the summary records no go env for the tranche"
for k in GOOS GOARCH GOEXPERIMENT GODEBUG GO_TEST_TIMEOUT_SCALE; do
  grep -q "\"${k}\"" "${summary}" || fail "the summary does not record ${k}"
done

# Artifacts were asserted, not merely measured: the tranche must have produced
# at least one of each kind the driver knows how to check.
for kind in goarchive executable gosource; do
  grep -q "\"artifact_kind\":\"${kind}\"" "${results}" || fail "no ${kind} artifact was produced anywhere in the tranche"
done

# The point of this slice is that the TARGET COMMANDS ran. Assert the recorded
# argv, not just the counts: a driver that reported from the action header would
# have no compiler invocation to show.
require_command() { # <label> <literal fragment of a recorded argv>
  grep -qF -- "$2" "${results}" || fail "no recorded command matching ${1}: $2"
}
require_command "go tool compile" '["$GOTOOL","tool","compile"'
require_command "go tool link"    '["$GOTOOL","tool","link"'
require_command "go build"        '["$GOTOOL","build"'
require_command "go run"          '["$GOTOOL","run"'
# runoutput must have compiled the GENERATED program, not the generator.
require_command "the generated runoutput program" 'tmp__.go'
# compiledir/rundir must have compiled the sibling directory as packages.
require_command "a .dir package compile" '.dir/'

echo "go-oracle end-to-end OK: ${rows}/${rows} executed, $(field commands) commands"
