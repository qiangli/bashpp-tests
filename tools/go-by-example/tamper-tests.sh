#!/usr/bin/env bash
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
#
# Genuine fail-closed mutations. Each case changes a real checked-in input, the
# real gate source, a real candidate manifest, or a real evidence document, and
# then enters the normal production path; there are no diagnosis hooks and
# nothing asserts an outcome into existence.
#
# Phase A mutates provisioning, the candidate binding and the gate itself.
# Phase B mutates a complete evidence document.
#
# Two Sprint 118 / Story #3 changes are visible throughout.
#
# The stand-in executable is gone. Phase B used to GENERATE its input by running
# the gate against tests/go-by-example/fixture-executor.sh, because the product
# implemented neither contract command and no honest document existed. The
# tag-enabled candidate implements both, so Phase B now mutates the REAL
# committed evidence chain -- produced by the real candidate against the real 85
# rows -- and Phase A drives the same real candidate.
#
# The executor pin is gone with it. Authority is now a reviewed candidates.tsv
# row plus a `--candidate` manifest that must equal it, so the negatives below
# cover the whole candidate: manifest bytes, launcher, payload, front-end
# version, build recipe, SDK identity and every runtime repository commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/tools/go-by-example/gate.sh"
CANDIDATE="${GBE_CANDIDATE:?set GBE_CANDIDATE to the authenticated candidate manifest}"
BASHY="${BASHY_BIN:?set BASHY_BIN to the authenticated candidate launcher}"
EVIDENCE_REL="tests/go-by-example/sprint118-story3-candidate001.jsonl.fail"
W="$(mktemp -d "${TMPDIR:-/tmp}/gbe-tamper.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
expect_fail() {
  local name="$1" marker="$2"; shift 2
  if "$@" >"$W/log" 2>&1; then echo "FAIL $name accepted" >&2; sed -n '1,8p' "$W/log" >&2; exit 1; fi
  grep -qF "$marker" "$W/log" || { echo "FAIL $name wrong diagnosis" >&2; sed -n '1,12p' "$W/log" >&2; exit 1; }
  pass=$((pass+1)); echo "PASS $name"
}
expect_ok() {
  local name="$1"; shift
  if ! "$@" >"$W/log" 2>&1; then echo "FAIL $name rejected" >&2; sed -n '1,20p' "$W/log" >&2; exit 1; fi
  pass=$((pass+1)); echo "PASS $name"
}

LEAKER="$ROOT/tests/go-by-example/leak-descendant.sh"
chmod +x "$LEAKER"

# Rewrite one field of a private repository copy's reviewed candidate row. A
# caller-supplied manifest is deliberately powerless on its own: authority is
# the row in the reviewed repository, and the manifest has to equal it.
recandidate() { # <repo> <awk-field-assignment>
  awk -F '\t' -v OFS='\t' "\$1 !~ /^#/ && NF { $2 } { print }" \
    "$1/docs/go-by-example/candidates.tsv" >"$W/recandidate.tsv"
  mv "$W/recandidate.tsv" "$1/docs/go-by-example/candidates.tsv"
}
gate() { ruby "$1/tools/go-by-example/gate.rb" --candidate "${2:-$CANDIDATE}" --bashy "$BASHY"; }

# ---------------------------------------------------------------------------
# Phase A: provisioning, the candidate binding, inputs and the gate source.
# ---------------------------------------------------------------------------
cp -R "$ROOT" "$W/repo"
SGATE="$W/repo/tools/go-by-example/gate.rb"

cp "$ROOT/docs/go-by-example/inventory.tsv" "$W/inventory"
awk -F '\t' 'BEGIN{OFS="\t"} $1=="examples/arrays/arrays.go"{next} {print}' "$W/inventory" >"$W/count"
expect_fail missing_real_row "expected exactly 85" \
  env GBE_INVENTORY="$W/count" GBE_SKIP_INTEGRITY=1 ruby "$SGATE" --candidate "$CANDIDATE" --bashy "$BASHY"

awk 'BEGIN{done=0} {if(!done && sub(/9b23202e/,"0b23202e")) done=1; print}' "$W/inventory" >"$W/source-hash"
expect_fail mutated_source_binding "source changed during gate" \
  env GBE_INVENTORY="$W/source-hash" GBE_SKIP_INTEGRITY=1 ruby "$SGATE" --candidate "$CANDIDATE" --bashy "$BASHY"

# An adapter is a claim about a control the gate performs. Registering one the
# gate cannot exercise is the exact `fake_clock`/`seeded_random` defect.
cp "$ROOT/docs/go-by-example/behavior-schema.tsv" "$W/schema"
printf 'adapter\tunimplemented_real_adapter\t-\tmutation\n' >>"$W/schema"
expect_fail mutated_adapter_configuration "adapter registry differs from schema" \
  env GBE_SCHEMA="$W/schema" GBE_SKIP_INTEGRITY=1 ruby "$SGATE" --candidate "$CANDIDATE" --bashy "$BASHY"

# Exact deterministic output may not acquire a volatile-value license.
sed '/examples\/arrays\/arrays.go/s/\tdeterministic\tnone\tnone\t/\tdeterministic\twallclock\tnone\t/' "$ROOT/docs/go-by-example/classification.tsv" > "$W/permissive-classification"
sed '/examples\/arrays\/arrays.go/s/\tdeterministic\tnone\tnone\t/\tdeterministic\twallclock\tnone\t/' "$ROOT/docs/go-by-example/inventory.tsv" > "$W/permissive-inventory"
expect_fail permissive_normalization "deterministic row must compare raw bytes" \
  env GBE_CLASSIFICATION="$W/permissive-classification" GBE_INVENTORY="$W/permissive-inventory" "$ROOT/tools/go-by-example/validate.sh"

# --- candidate binding negatives -------------------------------------------
# There is no default candidate: a gate that ran whatever was on PATH would be
# reporting on an unidentified product.
expect_fail no_default_candidate "there is no default candidate" \
  env -u GBE_CANDIDATE GBE_SKIP_INTEGRITY=1 ruby "$SGATE" --bashy "$BASHY"

# A manifest is a selection, not an introduction. One changed byte and it is no
# longer the manifest the repository reviewed.
sed 's/"frontend_version": "gosource-v1"/"frontend_version": "gosource-v2"/' "$CANDIDATE" >"$W/forged-candidate.json"
cmp -s "$CANDIDATE" "$W/forged-candidate.json" && { echo "FAIL forged manifest is identical" >&2; exit 1; }
expect_fail unreviewed_candidate_manifest "candidate manifest is not the repository-reviewed manifest" \
  env GBE_SKIP_INTEGRITY=1 ruby "$SGATE" --candidate "$W/forged-candidate.json" --bashy "$BASHY"

# The launcher is selected by path and authenticated by digest.
expect_fail mutated_candidate_launcher "digest mismatch" \
  env GBE_SKIP_INTEGRITY=1 ruby "$SGATE" --candidate "$CANDIDATE" --bashy /bin/echo

# A zeroed or self-identical digest is not a reviewed artifact.
cp -R "$ROOT" "$W/zero-repo"
recandidate "$W/zero-repo" '$4 = sprintf("%064d", 0)'
expect_fail unprovisioned_candidate "invalid reviewed candidate launcher_sha256" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/zero-repo/tools/go-by-example/gate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"

cp -R "$ROOT" "$W/same-repo"
recandidate "$W/same-repo" '$5 = $4'
expect_fail launcher_is_not_its_own_payload "launcher and payload digests are identical" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/same-repo/tools/go-by-example/gate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"

# The candidate and the oracle must come from the SAME reviewed Go release.
cp -R "$ROOT" "$W/repo126"
recandidate "$W/repo126" '$7 = "go version go1.26.0 darwin/arm64"'
expect_fail go126_candidate_pin_rejected "is not the reviewed toolchain" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/repo126/tools/go-by-example/gate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"

# A default build is permitted when reviewed, but changing the reviewed recipe
# without changing its authenticated manifest remains a mismatch.
cp -R "$ROOT" "$W/default-cli-repo"
recandidate "$W/default-cli-repo" '$8 = "GOTOOLCHAIN=go1.27.0 make build"'
expect_fail mismatched_default_cli_build_recipe "candidate manifest build_recipe differs from the reviewed table" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/default-cli-repo/tools/go-by-example/gate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"

# Every replaced runtime dependency is bound, filebrowser included. Dropping one
# from the reviewed row makes the real manifest stop matching it.
cp -R "$ROOT" "$W/partial-repo"
recandidate "$W/partial-repo" '$9 = "bashy=92985238a12547b28de74dfcc9bbd5d96abec464;coreutils=ec91ea4560a556c8217117bf7cb24e79f53e54f0;readline=b958823bd7075ed8b9a3aedd351422356a95fe79;sh=9c14f863b1352242a6abfaf2a30cd6ced06751d9"'
expect_fail incomplete_runtime_dependencies "repository set differs from the reviewed runtime dependencies" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/partial-repo/tools/go-by-example/gate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"

# A runtime dependency pinned to a different commit is refused by the shared
# corpus revision check, not by a second implementation of it here.
cp -R "$ROOT" "$W/wrong-commit-repo"
ruby - "$W/wrong-commit-repo" "$CANDIDATE" "$W/wrong-commit.json" <<'RUBY'
require "json"
require "digest"
repo, source, dest = ARGV
manifest = JSON.parse(File.read(source))
manifest["repositories"].each { |r| r["commit"] = "0" * 39 + "1" if File.basename(r["path"]) == "filebrowser" }
File.write(dest, JSON.pretty_generate(manifest) + "\n")
table = repo + "/docs/go-by-example/candidates.tsv"
rows = File.readlines(table).map do |line|
  next line if line.start_with?("#") || line.strip.empty?
  fields = line.chomp.split("\t", -1)
  fields[2] = Digest::SHA256.file(dest).hexdigest
  fields[8] = fields[8].sub(/filebrowser=[0-9a-f]{40}/, "filebrowser=" + "0" * 39 + "1")
  fields.join("\t") + "\n"
end
File.write(table, rows.join)
RUBY
expect_fail candidate_revision_mismatch "candidate revision mismatch" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/wrong-commit-repo/tools/go-by-example/gate.rb" --candidate "$W/wrong-commit.json" --bashy "$BASHY"

# The compiled mode needs the lowering runtime the candidate was built from. It
# is no longer provisioned out of band through GBE_SH_MODULE -- an unauthenticated
# environment path -- so its absence is a candidate defect, never a silently
# skipped third mode.
cp -R "$ROOT" "$W/no-sh-repo"
ruby - "$W/no-sh-repo" "$CANDIDATE" "$W/no-sh.json" <<'RUBY'
require "json"
require "digest"
repo, source, dest = ARGV
manifest = JSON.parse(File.read(source))
manifest["repositories"].reject! { |r| File.basename(r["path"]) == "sh" }
File.write(dest, JSON.pretty_generate(manifest) + "\n")
table = repo + "/docs/go-by-example/candidates.tsv"
rows = File.readlines(table).map do |line|
  next line if line.start_with?("#") || line.strip.empty?
  fields = line.chomp.split("\t", -1)
  fields[2] = Digest::SHA256.file(dest).hexdigest
  fields[8] = fields[8].split(";").reject { |p| p.start_with?("sh=") }.join(";")
  fields.join("\t") + "\n"
end
File.write(table, rows.join)
RUBY
expect_fail missing_sh_module "declares no mvdan.cc/sh/v3 lowering runtime" \
  env GBE_SKIP_INTEGRITY=1 ruby "$W/no-sh-repo/tools/go-by-example/gate.rb" --candidate "$W/no-sh.json" --bashy "$BASHY"

# The independent candidate validator reaches the same refusals from the table
# alone, with no gate run behind it.
expect_ok candidate_validator_authenticates \
  ruby "$ROOT/tools/go-by-example/validate-candidate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"
expect_fail candidate_validator_rejects_forgery "candidate manifest is not the repository-reviewed manifest" \
  ruby "$ROOT/tools/go-by-example/validate-candidate.rb" --candidate "$W/forged-candidate.json" --bashy "$BASHY"
expect_fail go126_candidate_validator_rejected "is not the reviewed toolchain" \
  ruby "$W/repo126/tools/go-by-example/validate-candidate.rb" --candidate "$CANDIDATE" --bashy "$BASHY"

# --- gate source mutations -------------------------------------------------
# These narrow a private copy to one genuine inventory row and change exactly
# one production behaviour. Authentication still runs first; nothing in the
# cleanup, record or publication path is weakened and no line asserts a state.
MROOT="$W/production-mutations"
cp -R "$ROOT" "$MROOT"

mutated_gate() { # <name> <mutation> <row-substring>
  local name="$1" mutation="$2" row="$3"
  local repo="$W/gate-$name" result="$W/result-$name.jsonl"
  cp -R "$MROOT" "$repo"
  ruby - "$repo/tools/go-by-example/gate.rb" "$mutation" "$row" "$LEAKER" <<'RUBY'
path, mutation, row, leaker = ARGV
s = File.read(path)
def replace!(s, old, new)
  abort "mutation target absent: #{old[0, 60]}" unless s.include?(old)
  s.sub!(old, new)
end
replace!(s, 'DENOMINATOR = rows.size * MODES.size',
         "rows = rows.select { |r| r[0].include?(#{row.dump}) }\nabort('mutation selected no row') if rows.empty?\nDENOMINATOR = rows.size * MODES.size")
replace!(s, 'fatal("expected exactly 85 program rows, got #{rows.size}") unless rows.size == 85', '')
compiled = '        when "compiled" then binaries["compiled"] && [binaries["compiled"], *args]'
interpreted = '        else [BASHY, "--bashpp", "--source=go", *source_args, *args]'
case mutation
when 'spawn_error'
  replace!(s, compiled, '        when "compiled" then [ROOT + "/definitely-missing-executable", *args]')
when 'timeout'
  replace!(s, compiled, '        when "compiled" then ["/bin/sleep", "5"]')
when 'leak'
  # A genuine survivor, not a forced state: the command exits 0 after putting a
  # descendant in its own session, so the process-group TERM/KILL Corpus.capture
  # performs provably cannot reach it and kill(0, -pgid) cannot see it. Only the
  # inherited liveness descriptor still observes it.
  replace!(s, compiled, '        when "compiled" then [' + leaker.dump + ']')
when 'flattened_assets'
  # The pre-Sprint-118 defect: copy required assets by basename. `//go:embed
  # folder/single_file.txt` then has nothing to embed and the oracle build
  # fails, which is the whole reason relative paths must be preserved.
  replace!(s, 'target = File.join(dir, asset[(example_dir.size + 1)..])',
           'target = File.join(dir, File.basename(asset))')
when 'effect_blind'
  # stdout, stderr and status all agree with the oracle; only the filesystem
  # effect differs. Without a compared effect channel this is invisible.
  replace!(s, interpreted,
           '        else ["/bin/sh", "-c", "\"$0\" \"$@\"; : > gate-mutation-residue", binaries["oracle"].to_s, *args]')
else abort "unknown mutation"
end
File.write(path, s)
RUBY
  if env GBE_SKIP_INTEGRITY=1 GBE_ROW_TIMEOUT="${GBE_ROW_TIMEOUT:-240}" \
      GBE_RUN_TIMEOUT="${MUT_RUN_TIMEOUT:-20}" GBE_CLEANUP_TIMEOUT="${MUT_CLEANUP_TIMEOUT:-2}" \
      ruby "$repo/tools/go-by-example/gate.rb" --candidate "$CANDIDATE" --bashy "$BASHY" \
      --evidence "$result" >"$W/$name.log" 2>&1; then
    echo "FAIL $name production mutation passed" >&2; exit 1
  fi
  if [[ ! -f "$result.fail" ]]; then
    echo "FAIL $name produced no FAIL evidence" >&2; sed -n '1,12p' "$W/$name.log" >&2; exit 1
  fi
  echo "$result.fail"
}

check_attempt() { # <evidence> <mode> <field> <want>
  ruby -rjson - "$@" <<'RUBY'
rows = File.readlines(ARGV[0], chomp: true).map { |l| JSON.parse(l) }
a = rows.find { |r| r["type"] == "attempt" && r["mode"] == ARGV[1] }
abort "no #{ARGV[1]} attempt" unless a
abort "#{ARGV[2]} is #{a[ARGV[2]].inspect}, want #{ARGV[3].inspect}" unless a[ARGV[2]].to_s == ARGV[3]
s = rows.last
abort "mutation did not publish an honest red summary" unless s["type"] == "summary" && s["verdict"] == "fail"
RUBY
}

for case_spec in "spawn_error:unspawned" "timeout:timeout"; do
  name="${case_spec%%:*}"; want="${case_spec##*:}"
  ev="$(MUT_RUN_TIMEOUT=1 mutated_gate "$name" "$name" hello-world)"
  check_attempt "$ev" compiled state "$want" || { echo "FAIL $name" >&2; exit 1; }
  pass=$((pass+1)); echo "PASS $name"
done
# The leak fixture is an ordinary shell script, so it is run on the one row
# whose declared behavior provisions a PATH; every other row runs with an empty
# PATH by design.
ev="$(MUT_RUN_TIMEOUT=8 MUT_CLEANUP_TIMEOUT=.25 mutated_gate leak leak spawning-processes)"
check_attempt "$ev" compiled state leak || { echo "FAIL leak" >&2; exit 1; }
pass=$((pass+1)); echo "PASS leak"

ev="$(mutated_gate flattened_assets flattened_assets embed-directive)"
check_attempt "$ev" oracle state unspawned || { echo "FAIL flattened_assets" >&2; exit 1; }
pass=$((pass+1)); echo "PASS flattened_assets"

ev="$(mutated_gate effect_blind effect_blind hello-world)"
check_attempt "$ev" interpreted verdict fail_effects || { echo "FAIL effect_blind" >&2; exit 1; }
pass=$((pass+1)); echo "PASS effect_blind"

# ---------------------------------------------------------------------------
# Phase B: the REAL committed evidence document, produced by the real candidate.
# ---------------------------------------------------------------------------
PROD="$W/prod"
cp -R "$ROOT" "$PROD"
PRODUCTION="$PROD/$EVIDENCE_REL"
[ -f "$PRODUCTION" ] || { echo "FAIL committed evidence chain is missing: $EVIDENCE_REL" >&2; exit 1; }
expect_ok committed_evidence_is_authenticated "$PROD/tools/go-by-example/validate-evidence.rb" "$PRODUCTION"

# A fully self-consistent GREEN document with every hash recomputed still has
# no reviewed production root behind it.
ruby -rjson -rdigest - "$PRODUCTION" "$W/invented.jsonl.pass" <<'RUBY'
src, out = ARGV
rows = File.readlines(src, chomp: true).map { |l| JSON.parse(l) }
manifest, attempts, summary = rows.first, rows[1...-1], rows.last
attempts.each_slice(3) do |triple|
  oracle = triple[0]
  triple[1..].each do |a|
    %w[raw_stdout_b64 raw_stderr_b64 normalized_stdout_b64 normalized_stderr_b64 exit effects_sha256 effects_delta].each { |k| a[k] = oracle[k] }
    a["spawned"] = true; a["state"] = "complete"; a["verdict"] = "pass"
    a["stages"].last.merge!("spawned" => true, "state" => "complete", "exit" => oracle["exit"])
  end
end
attempts.each { |a| a.delete("evidence_sha256"); a["evidence_sha256"] = Digest::SHA256.hexdigest(JSON.generate(a)) }
summary.merge!("verdict" => "pass", "executed" => attempts.size, "missing_or_unspawned" => 0, "failures" => [])
body = summary.reject { |k, _| k == "root_digest" }
summary["root_digest"] = Digest::SHA256.hexdigest(([Digest::SHA256.hexdigest(JSON.generate(manifest))] +
  attempts.map { |a| a["evidence_sha256"] } + [Digest::SHA256.hexdigest(JSON.generate(body))]).join("\n"))
File.write(out, ([manifest] + attempts + [summary]).map { |r| JSON.generate(r) }.join("\n") + "\n")
RUBY
expect_fail self_hashes_are_not_authentication "evidence root is not anchored" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$W/invented.jsonl.pass"

# Mutations of the committed document. Each helper recomputes every
# attacker-controlled self-hash and the public root, so only independent
# derivation from raw bytes and reviewed tables can reject them.
rebind() { # rewrite every self-hash and the root after an edit
  cat <<'RUBY'
def rebind!(rows)
  manifest, attempts, summary = rows.first, rows[1...-1], rows.last
  binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
  attempts.each do |a|
    a["binding_sha256"] = binding if a.key?("binding_sha256")
    a.delete("evidence_sha256")
    a["evidence_sha256"] = Digest::SHA256.hexdigest(JSON.generate(a))
  end
  body = summary.reject { |k, _| k == "root_digest" }
  summary["root_digest"] = Digest::SHA256.hexdigest(([binding] + attempts.map { |a| a["evidence_sha256"] } +
    [Digest::SHA256.hexdigest(JSON.generate(body))]).join("\n"))
end
RUBY
}
mutate() { # <name> <ruby-body-operating-on-`rows`>
  local dest="$W/$1.fail"
  cp "$PRODUCTION" "$dest"
  ruby -rjson -rdigest -rbase64 -e "$(rebind)
rows = File.readlines(ARGV[0], chomp: true).map { |l| JSON.parse(l) }
$2
File.write(ARGV[0], rows.map { |r| JSON.generate(r) }.join(\"\n\") + \"\n\")" "$dest"
  printf '%s' "$dest"
}

# Structural: same record count, but a mode/row pairing that never happened.
d="$(mutate missing-mode 'rows[1] = rows[2].dup; rebind!(rows)')"
expect_fail missing_mode_evidence "missing, duplicate, reordered, or foreign row/mode evidence" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate missing-row 'rows[1, 3] = rows[4, 3].map(&:dup); rebind!(rows)')"
expect_fail missing_row_evidence "missing, duplicate, reordered, or foreign row/mode evidence" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# Self-hash left stale: the cheapest forgery of all.
cp "$PRODUCTION" "$W/tampered.fail"
sed '2s/"spawned":true/"spawned":false/' "$W/tampered.fail" >"$W/x" && mv "$W/x" "$W/tampered.fail"
expect_fail result_tampering "result tampering detected" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$W/tampered.fail"

# Raw bytes changed, stale normalized bytes retained (and the reverse).
d="$(mutate arrays-stale-normalized 'r = rows.find { |x| x["path"] == "examples/arrays/arrays.go" && x["mode"] == "oracle" } or abort "arrays oracle absent"
r["raw_stdout_b64"] = Base64.strict_encode64("attacker-controlled arrays output\n"); rebind!(rows)')"
expect_fail arrays_raw_stale_normalized "stored normalized output differs from independently recomputed bytes: examples/arrays/arrays.go:oracle" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate arrays-stale-raw 'r = rows.find { |x| x["path"] == "examples/arrays/arrays.go" && x["mode"] == "oracle" } or abort "arrays oracle absent"
r["normalized_stdout_b64"] = Base64.strict_encode64("attacker-preferred comparator input\n"); rebind!(rows)')"
expect_fail arrays_stale_raw_for_normalized "stored normalized output differs from independently recomputed bytes: examples/arrays/arrays.go:oracle" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# A comparator may not wave a mismatch through by rewriting its own verdict.
d="$(mutate permissive-comparator 'r = rows.find { |x| x["type"] == "attempt" && x["verdict"] != "pass" } or abort "no failing attempt"
r["verdict"] = "pass"; rebind!(rows)')"
expect_fail permissive_comparator "per-attempt verdict is not derived" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate tampered-summary 'rows[-1]["failures"] = ["invented"]; rebind!(rows)')"
expect_fail tampered_summary "summary is not independently derived" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate tampered-root 'rows[-1]["root_digest"] = "0" * 64')"
expect_fail tampered_root "summary-bound root digest mismatch" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# Effects: a forged digest, and a listing quietly rewritten by a normalization
# no row licenses.
d="$(mutate forged-effects 'r = rows.find { |x| x["type"] == "attempt" && x.key?("effects_delta") }
r["effects_delta"] = "+tmp/undeclared-residue\tfile:" + ("0" * 64); rebind!(rows)')"
expect_fail forged_effect_digest "stored effect digest differs from the recorded delta" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# A compiled run may not be recorded without the stages that could have
# produced an artifact: a successful transpile is not a successful build, and a
# transpile without a validated source map is not a successful transpile.
d="$(mutate stage-masquerade 'r = rows.find { |x| x["type"] == "attempt" && x["mode"] == "compiled" && x["spawned"] }
abort "no spawned compiled attempt" unless r
r["stages"] = r["stages"].reject { |s| s["stage"] == "build" }; rebind!(rows)')"
expect_fail stage_masquerade "compiled run was recorded without a successful build stage" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate map-masquerade 'r = rows.find { |x| x["type"] == "attempt" && x["mode"] == "compiled" && x["spawned"] }
abort "no spawned compiled attempt" unless r
r["stages"].each { |s| s.delete("source_map_sha256") }; rebind!(rows)')"
expect_fail source_map_masquerade "without a successful transpile stage" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# The recorded recipe is part of what is reviewed: reverting the oracle to
# `go run`, granting one mode extra environment, dropping the --go-file
# multi-file contract, renaming the shared process primitives away, or
# overstating the isolation the harness actually builds is refused even when
# every hash in the document has been recomputed around the change.
d="$(mutate go-run-oracle 'rows.first["recipe"]["oracle"] = "go run the pinned source"; rebind!(rows)')"
expect_fail go_run_oracle_recipe "oracle recipe must build and run a native binary" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate env-divergence 'rows.first["recipe"]["declared_env_divergence"] = ["GOROOT"]; rebind!(rows)')"
expect_fail declared_env_divergence "evidence declares an environment divergence between modes" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate hidden-env-grant 'rows.first["recipe"]["common_runtime_go_env"] = []; rebind!(rows)')"
expect_fail hidden_runtime_env_grant "does not record the common runtime Go environment" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate operand-recipe 'rows.first["recipe"]["multi_file_input"] = "operand"; rebind!(rows)')"
expect_fail operand_multifile_recipe "does not record the --go-file multi-file input contract" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
# ... and where it is actually observable: the recorded argv of the multi-file
# row. Rewriting it to the operand spelling is refused even though the recipe
# prose still claims --go-file.
d="$(mutate operand-argv 'r = rows.find { |x| x["type"] == "attempt" && x["kind"] == "test_program" && x["mode"] == "interpreted" } or abort "no multi-file product attempt"
r["stages"].each { |st| st["argv"] = Array(st["argv"]).reject { |a| a == "--go-file" } }; rebind!(rows)')"
expect_fail operand_multifile_argv "did not use the --go-file contract" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate foreign-primitives 'rows.first["recipe"]["process_primitives"] = "a private spawn/timeout/leak implementation"; rebind!(rows)')"
expect_fail foreign_process_primitives "does not record the shared corpus process primitives" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate stale-corpus-primitives 'rows.first["recipe"]["corpus_executor_sha256"] = "0" * 64; rebind!(rows)')"
expect_fail unanchored_corpus_primitives "corpus executor is not anchored to production" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate overstated-isolation 'rows.first["recipe"]["source_absence"] = "the program cannot reach its source or the Go SDK"; rebind!(rows)')"
expect_fail overstated_isolation "evidence overstates isolation" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# Candidate binding inside the document: evidence produced against some other
# launcher, payload, build recipe or runtime dependency set is not evidence
# about the reviewed candidate.
d="$(mutate other-launcher 'rows.first["candidate"]["launcher_sha256"] = "a" * 64; rebind!(rows)')"
expect_fail evidence_bound_to_other_launcher "candidate launcher_sha256 is not the repository-reviewed value" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate other-payload 'rows.first["candidate"]["payload_sha256"] = "b" * 64; rebind!(rows)')"
expect_fail evidence_bound_to_other_payload "candidate payload_sha256 is not the repository-reviewed value" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate default-cli-evidence 'rows.first["candidate"]["build_recipe"] = "GOTOOLCHAIN=go1.27.0 make build"; rebind!(rows)')"
expect_fail evidence_bound_to_default_cli "candidate build_recipe is not the repository-reviewed value" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"
d="$(mutate dropped-dependency 'rows.first["candidate"]["repositories"] = rows.first["candidate"]["repositories"].reject { |r| r["name"] == "filebrowser" }; rebind!(rows)')"
expect_fail evidence_drops_runtime_dependency "candidate runtime dependencies differ from the reviewed set" \
  "$PROD/tools/go-by-example/validate-evidence.rb" "$d"

# Repository mutations checked by the validator's own standalone revalidation.
CROW='examples/atomic-counters/atomic-counters.go'
copy_prod() { cp -R "$PROD" "$1"; }
copy_prod "$W/cls-repo"
sed "s|^\(${CROW}\tprogram\tconcurrency\tnone\t\)bounded_wait\t|\1bounded_wait,tmpdir\t|" \
  "$ROOT/docs/go-by-example/classification.tsv" >"$W/cls-repo/docs/go-by-example/classification.tsv"
expect_fail classification_not_bound_to_inventory "inventory classification columns do not match the authored classification table" \
  "$W/cls-repo/tools/go-by-example/validate-evidence.rb" "$W/cls-repo/$EVIDENCE_REL"
sed "s|^\(${CROW}\tprogram\tconcurrency\tnone\t\)bounded_wait\t|\1bounded_wait,tmpdir\t|" \
  "$ROOT/docs/go-by-example/inventory.tsv" >"$W/cls-repo/docs/go-by-example/inventory.tsv"
expect_fail unlicensed_adapter_coupling "row carries an adapter no declared behavior requires: ${CROW}" \
  "$W/cls-repo/tools/go-by-example/validate-evidence.rb" "$W/cls-repo/$EVIDENCE_REL"

copy_prod "$W/schema-repo"
printf 'adapter\tnamed_but_unimplemented\t-\tclaims a control nothing performs\n' >>"$W/schema-repo/docs/go-by-example/behavior-schema.tsv"
expect_fail schema_adapter_without_implementation "schema declares an adapter the gate does not implement" \
  "$W/schema-repo/tools/go-by-example/validate-evidence.rb" "$W/schema-repo/$EVIDENCE_REL"

copy_prod "$W/stray-repo"
printf 'not reviewed\n' >"$W/stray-repo/examples/stray.txt"
expect_fail unanchored_corpus_file "standalone corpus integrity revalidation failed" \
  "$W/stray-repo/tools/go-by-example/validate-evidence.rb" "$W/stray-repo/$EVIDENCE_REL"

echo "PASS: $pass genuine mutations/invariants checked"
