#!/usr/bin/env bash
# Tamper self-tests for the tour-executor ledger and its offline gate.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# tools/tour/executor-selftests.rb proves the gate on a SYNTHETIC fixture that
# passes. This suite proves it on the REAL evidence: it takes the committed
# tests/tour/executor-results.jsonl, mutates exactly one recorded fact, reseals
# the ledger so nothing else is inconsistent, and requires the REAL gate to
# emit the expected finding.
#
# The real ledger legitimately FAILS (the candidate does not yet implement
# every Bash++ selector), so "the gate exited nonzero" proves nothing here.
# Each probe is therefore DIFFERENTIAL: the expected finding must be ABSENT
# from the gate's report on the pristine ledger and PRESENT after the mutation.
# A probe whose mutation leaves the report unchanged is a failure of this suite.
#
# Usage: tools/tour/executor-tamper-tests.sh [ledger]
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LEDGER="${1:-${ROOT}/tests/tour/executor-results.jsonl}"
GATE="${ROOT}/tools/tour/executor-gate.rb"

[ -f "${LEDGER}" ] || { echo "FATAL: missing ledger ${LEDGER}" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tour-executor-tamper.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

# Applies the Ruby mutation in $MUTATION to $LEDGER, writing $OUT, and reseals
# root + verdict so the mutated ledger stays internally consistent everywhere
# except the mutated fact.
mutate() {
  ruby -r json -r digest -e '
    require "base64"
    $LOAD_PATH.unshift(File.join(ENV["ROOT"], "tools/tour"))
    require "executor"
    records = TourExecutor.read_ledger(ENV["LEDGER"])
    body = records.reject { |r| %w[root verdict].include?(r["type"]) }
    eval(ENV["MUTATION"])
    observations = body.select { |r| r["type"] == "observation" }
    summary = body.find { |r| r["type"] == "summary" }
    if summary
      summary["outcomes"] = observations.group_by { |r| r["status"] }.transform_values(&:length).sort.to_h
      summary["observations"] = observations.length
      summary["semantic_rows"] = body.count { |r| r["type"] == "oracle" }
    end
    root = { "type" => "root", "algorithm" => "sha256-canonical-jsonl", "sha256" => TourExecutor.ledger_root(body) }
    pass = observations.length == TourExecutor::OBSERVATIONS &&
           summary && summary["outcomes"] == { "PASS" => TourExecutor::OBSERVATIONS }
    TourExecutor.write_ledger(ENV["OUT"], body + [root, { "type" => "verdict", "value" => pass ? "PASS" : "FAIL", "root_sha256" => root["sha256"] }])
  ' 2>"${WORK}/mutate.err"
  local rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "    mutation failed:"; sed 's/^/      /' "${WORK}/mutate.err"
    return 1
  fi
  [ -s "${OUT}" ]
}

gate_report() {
  ROOT="${ROOT}" TOUR_EXECUTOR_RESULTS="$1" ruby "${GATE}" 2>&1
}

# The gate's report on the untouched ledger. Every expected finding below must
# be absent from it, otherwise the probe proves nothing.
BASE_REPORT="${WORK}/base.report"
TOUR_EXECUTOR_RESULTS="${LEDGER}" ruby "${GATE}" >"${BASE_REPORT}" 2>&1
BASE_RC=$?
echo "pristine ledger: gate exit ${BASE_RC} ($(grep -c . "${BASE_REPORT}") report lines)"

probe() {
  local name="$1" expected="$2" mutation="$3"
  local out="${WORK}/ledger.jsonl" report="${WORK}/probe.report"
  rm -f "${out}"
  if grep -qF -- "${expected}" "${BASE_REPORT}"; then
    echo "  FAIL ${name}: finding ${expected} is ALREADY present without any mutation"
    FAIL=$((FAIL + 1))
    return
  fi
  export ROOT LEDGER MUTATION
  export OUT="${out}"
  MUTATION="${mutation}"
  if ! mutate; then
    echo "  FAIL ${name}: could not build the mutated ledger"
    FAIL=$((FAIL + 1))
    return
  fi
  gate_report "${out}" >"${report}" 2>&1
  if grep -qF -- "${expected}" "${report}"; then
    PASS=$((PASS + 1))
    echo "  ok   ${name}"
  else
    echo "  FAIL ${name}: expected finding ${expected}, gate said:"
    head -20 "${report}" | sed 's/^/       /'
    FAIL=$((FAIL + 1))
  fi
}

M='manifest = body.first'
O='observation = body.find { |r| r["type"] == "observation" }'
ORACLE='oracle = body.find { |r| r["type"] == "oracle" }'
VOL='volatile = body.find { |r| r["type"] == "oracle" }["path"]; observation = body.find { |r| r["type"] == "observation" && r["path"] == volatile && r["mode"] == "baseline" }'

echo "candidate provenance"
probe 'a rebound launcher digest is rejected' 'candidate:unbound_launcher_digest' \
  "${M}; manifest[\"candidate\"][\"binaries\"][\"launcher\"][\"sha256\"] = \"deadbeef\"; manifest[\"candidate_failures\"] = TourExecutor.candidate_failures(manifest[\"candidate\"])"
probe 'an unbound replaced dependency (filebrowser) is rejected' 'candidate:unbound:filebrowser' \
  "${M}; c = manifest[\"candidate\"][\"components\"].find { |x| x[\"component\"] == \"filebrowser\" }; c[\"bound\"] = false; c[\"commit\"] = nil; manifest[\"candidate_failures\"] = TourExecutor.candidate_failures(manifest[\"candidate\"])"
probe 'dropping a manifest repository is rejected' 'candidate:repository_set' \
  "${M}; manifest[\"candidate\"][\"repositories\"].reject! { |r| r[\"name\"] == \"filebrowser\" }; manifest[\"candidate_failures\"] = TourExecutor.candidate_failures(manifest[\"candidate\"])"
probe 'a candidate hiding its own failures is rejected' 'candidate:runner_hid_failures' \
  "${M}; manifest[\"candidate\"][\"binaries\"][\"payload\"][\"present\"] = false"

echo "shared capture provenance"
probe 'a privately captured ledger is rejected' 'capture:implementation' \
  "${M}; manifest[\"capture_implementation\"] = \"tools/tour/executor.rb\""
probe 'a rebound shared capture library digest is rejected' 'capture:library_sha256' \
  "${M}; manifest[\"capture_library_sha256\"] = \"0\" * 64"

echo "semantic comparators and the native oracle"
probe 'a forged semantic verdict is rejected' 'semantic_forged:' \
  "${VOL}; observation[\"semantic\"][\"findings\"] = []; observation[\"semantic\"][\"evidence\"][\"oracle_runs\"] = 99"
probe 'a semantic verdict on an undeclared row is rejected' 'semantic_undeclared:' \
  "o = body.find { |r| r[\"type\"] == \"observation\" && r[\"semantic\"].nil? }; o[\"semantic\"] = { \"comparator\" => \"line_set\", \"version\" => TourSemantics::VERSION, \"ok\" => true, \"findings\" => [], \"evidence\" => {} }"
probe 'a missing oracle record is rejected' 'oracle:row_set' \
  "body.delete_at(body.index { |r| r[\"type\"] == \"oracle\" })"
probe 'an oracle thinner than the declared minimum is rejected' 'oracle:repeats' \
  "${ORACLE}; oracle[\"runs\"] = oracle[\"runs\"].first(3); oracle[\"repeats\"] = 3"
probe 'an oracle that is not the built artifact is rejected' 'oracle_binary_mismatch:' \
  "${ORACLE}; oracle[\"binary\"][\"sha256\"] = \"7\" * 64"
probe 'an oracle bound to another source digest is rejected' 'oracle:source_binding:' \
  "${ORACLE}; oracle[\"source_sha256\"] = \"8\" * 64"
probe 'a widened comparison window is rejected' 'semantic_window_forged:' \
  "${VOL}; observation[\"window\"][\"to\"] += 100000.0"
probe 'a semantics table demoted to advisory is rejected' 'semantics:gate_effect' \
  "${M}; manifest[\"semantics\"][\"gate_effect\"] = \"advisory\""
probe 'a volatility table promoted to a waiver is rejected' 'volatility:claims_gate_effect' \
  "${M}; manifest[\"volatility\"][\"gate_effect\"] = \"waives-mismatch\""

echo "phase contract"
probe 'a rewritten historical phase token is rejected' 'historical_phase_drift:' \
  "o = body.find { |r| r[\"type\"] == \"observation\" && r[\"applicability\"] == \"build_only_go_program\" }; o[\"historical_phase_token\"] = \"transpile-build-no-run\""
probe 'a rebound phase-migration table is rejected' 'binding:phase_migration:sha256' \
  "${M}; manifest[\"phase_migration\"][\"sha256\"] = \"0\" * 64"

echo "isolation claims"
probe 'an OS-sandbox claim is rejected' 'input_absence:os_sandbox_claimed' \
  "${M}; manifest[\"environment\"][\"os_sandbox\"] = true"
probe 'a weakened input-absence scope is rejected' 'input_absence:scope' \
  "${M}; manifest[\"environment\"][\"input_absence_scope\"] = \"fully sandboxed\""

echo "artifacts and streams"
probe 'a source map that does not describe its own artifact is rejected' 'source_map_generation_digest' \
  "o = body.find { |r| r[\"type\"] == \"observation\" && r[\"mode\"] == \"compiled\" && r[\"stages\"][0][\"exit\"] == 0 }; o[\"stages\"][0][\"artifacts\"][\"map\"][\"source_map\"][\"go_digest\"] = \"sha256:\" + \"9\" * 64"
probe 'rewritten raw bytes without renormalizing are rejected' 'normalizer_drift:' \
  "o = body.find { |r| r[\"type\"] == \"observation\" && r[\"mode\"] == \"baseline\" }; s = o[\"stages\"].last; s[\"raw\"][\"stdout_base64\"] = Base64.strict_encode64(\"tampered\\n\"); s[\"raw\"][\"stdout_bytes\"] = 9"

echo "ledger shape"
probe 'a deleted observation is rejected' 'missing:' \
  "body.delete_at(body.index { |r| r[\"type\"] == \"observation\" && r[\"mode\"] == \"compiled\" })"
probe 'a duplicated observation is rejected' 'duplicate:' \
  "${O}; body.insert(1, JSON.parse(JSON.generate(observation)))"
probe 'a PLANNED placeholder status is rejected' 'placeholder_status:' \
  "${O}; observation[\"status\"] = \"PLANNED\""
probe 'an observation-level waiver is rejected' 'unexpected_na:' \
  "${O}; observation[\"expected_failure\"] = \"unimplemented\""
probe 'a hand-written PASS over a failed stage is rejected' 'status_forged:' \
  "o = body.find { |r| r[\"type\"] == \"observation\" && r[\"status\"] != \"PASS\" }; o[\"status\"] = \"PASS\""

# The root check is the one probe that must NOT be resealed.
echo "sealing"
ROOT="${ROOT}" LEDGER="${LEDGER}" OUT="${WORK}/root.jsonl" ruby -r json -e '
  $LOAD_PATH.unshift(File.join(ENV["ROOT"], "tools/tour"))
  require "executor"
  records = TourExecutor.read_ledger(ENV["LEDGER"])
  records[-2]["sha256"] = "1" * 64
  records[-1]["root_sha256"] = "1" * 64
  TourExecutor.write_ledger(ENV["OUT"], records)
'
if gate_report "${WORK}/root.jsonl" | grep -qF 'root:tampered'; then
  PASS=$((PASS + 1)); echo "  ok   a tampered root hash is rejected"
else
  FAIL=$((FAIL + 1)); echo "  FAIL a tampered root hash is rejected"
fi

echo
echo "tour executor tamper tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
