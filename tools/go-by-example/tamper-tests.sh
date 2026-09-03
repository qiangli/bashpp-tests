#!/usr/bin/env bash
# Genuine fail-closed mutations. Each case changes a real checked-in input or
# executor and enters the normal production gate; there are no diagnosis hooks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/tools/go-by-example/gate.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/gbe-tamper.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
expect_fail() {
  local name="$1" marker="$2"; shift 2
  if "$@" >"$W/log" 2>&1; then echo "FAIL $name accepted" >&2; exit 1; fi
  grep -qF "$marker" "$W/log" || { echo "FAIL $name wrong diagnosis" >&2; sed -n '1,8p' "$W/log" >&2; exit 1; }
  pass=$((pass+1)); echo "PASS $name"
}

# A private repository copy lets the test mutate the reviewed executor pin
# itself. Merely passing a matching hash in the environment is intentionally
# ineffective.
cp -R "$ROOT" "$W/repo"
FIXTURE_EXEC="$(command -v ruby)"
FIXTURE_SHA="$(shasum -a 256 "$FIXTURE_EXEC" | awk '{print $1}')"
awk -F '\t' -v OFS='\t' -v s="$FIXTURE_SHA" '$1 !~ /^#/ && NF {$3=s} {print}' \
  "$W/repo/docs/go-by-example/executor.tsv" >"$W/executor.tsv"
mv "$W/executor.tsv" "$W/repo/docs/go-by-example/executor.tsv"
SGATE="$W/repo/tools/go-by-example/gate.sh"

# Mutate the actual inventory consumed by the production row loader.
cp "$ROOT/docs/go-by-example/inventory.tsv" "$W/inventory"
awk -F '\t' 'BEGIN{OFS="\t"} $1=="examples/arrays/arrays.go"{next} {print}' "$W/inventory" >"$W/count"
expect_fail missing_real_row "expected exactly 85" env GBE_INVENTORY="$W/count" GBE_SKIP_INTEGRITY=1 BASHY_BIN="$FIXTURE_EXEC" "$SGATE"
awk 'BEGIN{done=0} {if(!done && sub(/9b23202e/,"0b23202e")) done=1; print}' "$W/inventory" >"$W/source-hash"
expect_fail mutated_source_binding "source changed during gate" env GBE_INVENTORY="$W/source-hash" GBE_SKIP_INTEGRITY=1 BASHY_BIN="$FIXTURE_EXEC" "$SGATE"

# Mutate the real schema registry. This exercises the same registration path
# used for every run, rather than asking the runner to pretend it is broken.
cp "$ROOT/docs/go-by-example/behavior-schema.tsv" "$W/schema"
printf 'adapter\tunimplemented_real_adapter\t-\tmutation\n' >>"$W/schema"
expect_fail mutated_adapter_configuration "adapter registry differs from schema" env GBE_SCHEMA="$W/schema" GBE_SKIP_INTEGRITY=1 BASHY_BIN="$FIXTURE_EXEC" "$SGATE"

# Attempt the formerly permissive rewrite through the real integrity gate:
# exact deterministic output may not acquire a volatile-value license.
sed '/examples\/arrays\/arrays.go/s/\tdeterministic\tnone\tnone\t/\tdeterministic\twallclock\tnone\t/' "$ROOT/docs/go-by-example/classification.tsv" > "$W/permissive-classification"
sed '/examples\/arrays\/arrays.go/s/\tdeterministic\tnone\tnone\t/\tdeterministic\twallclock\tnone\t/' "$ROOT/docs/go-by-example/inventory.tsv" > "$W/permissive-inventory"
expect_fail permissive_normalization "deterministic row must compare raw bytes" env GBE_CLASSIFICATION="$W/permissive-classification" GBE_INVENTORY="$W/permissive-inventory" "$ROOT/tools/go-by-example/validate.sh"

# Executor authority is repository-owned. Mutate the real repository pin to
# the old zero sentinel; a caller-provided matching hash cannot rescue it.
cp "$W/repo/docs/go-by-example/executor.tsv" "$W/executor.good"
awk -F '\t' -v OFS='\t' '$1 !~ /^#/ && NF {$3=sprintf("%064d",0)} {print}' "$W/executor.good" > "$W/repo/docs/go-by-example/executor.tsv"
expect_fail unprovisioned_executor "invalid repository-reviewed Bash++ executor checksum" env GBE_SKIP_INTEGRITY=1 BASHY_BIN=/usr/bin/false BASHY_SHA256="$(shasum -a 256 /usr/bin/false | awk '{print $1}')" "$SGATE"
cp "$W/executor.good" "$W/repo/docs/go-by-example/executor.tsv"

expect_fail mutated_executor_artifact "Bash++ executor differs from repository-reviewed artifact" \
  env GBE_SKIP_INTEGRITY=1 BASHY_BIN=/bin/echo "$SGATE"

# Produce an anchored, structurally valid evidence chain, then mutate the real
# JSONL consumed by the production validator. The mutation helper recomputes
# every attacker-controlled self-hash and the root, proving those hashes alone
# cannot bless invented execution.
ruby -rjson -rdigest -rbase64 - "$ROOT" "$W/evidence.pass" <<'RUBY'
root,out=ARGV; sha=->p{Digest::SHA256.file(root+"/"+p).hexdigest}; inv=File.readlines(root+"/docs/go-by-example/inventory.tsv",chomp:true).reject{|x|x.empty?||x.start_with?("#")}.map{|x|x.split("\t",-1)}.select{|r|%w[program test_program].include?(r[1])};ep=File.readlines(root+"/docs/go-by-example/executor.tsv",chomp:true).reject{|x|x.empty?||x.start_with?("#")}.first.split("\t",-1);tp=File.readlines(root+"/docs/go-by-example/toolchain.tsv",chomp:true).reject{|x|x.empty?||x.start_with?("#")}.first.split("\t",-1);cr=Digest::SHA256.hexdigest(inv.map{|r|"#{r[0]}\0#{r[7]}\n"}.join)
m={"type"=>"manifest","schema"=>6,"story"=>"Sprint98/Story198/fa07603b71dc","corpus_sha256"=>sha.call("docs/go-by-example/inventory.tsv"),"corpus_root_sha256"=>cr,"behavior_schema_sha256"=>sha.call("docs/go-by-example/behavior-schema.tsv"),"classification_sha256"=>sha.call("docs/go-by-example/classification.tsv"),"normalizer_version"=>1,"normalizer_sha256"=>sha.call("tools/go-by-example/normalizer.rb"),"toolchain_sha256"=>sha.call("docs/go-by-example/toolchain.tsv"),"go_sha256"=>tp[4],"executor"=>{"sha256"=>ep[2],"pin_sha256"=>sha.call("docs/go-by-example/executor.tsv")},"denominator"=>{"rows"=>85,"modes_per_row"=>3,"attempts"=>255},"modes"=>%w[oracle interpreted compiled]};bind=Digest::SHA256.hexdigest(JSON.generate(m));production=File.readlines(root+"/tests/go-by-example/story198-current.jsonl.fail",chomp:true).map{|line|JSON.parse(line)};oracles=production.select{|r|r["type"]=="attempt"&&r["mode"]=="oracle"}.to_h{|r|[r["path"],r]};a=inv.flat_map{|row|o=oracles.fetch(row[0]);%w[oracle interpreted compiled].map{|mode|r={"type"=>"attempt","path"=>row[0],"mode"=>mode,"spawned"=>true,"state"=>"complete","exit"=>o["exit"],"raw_stdout_b64"=>o["raw_stdout_b64"],"raw_stderr_b64"=>o["raw_stderr_b64"],"normalized_stdout_b64"=>o["normalized_stdout_b64"],"normalized_stderr_b64"=>o["normalized_stderr_b64"],"verdict"=>"pass","binding_sha256"=>bind}.compact;r["evidence_sha256"]=Digest::SHA256.hexdigest(JSON.generate(r));r}}
s={"type"=>"summary","verdict"=>"pass","denominator"=>255,"attempt_records"=>255,"executed"=>255,"missing_or_unspawned"=>0,"failures"=>[],"corpus_sha256"=>m["corpus_sha256"],"corpus_root_sha256"=>cr,"behavior_schema_sha256"=>m["behavior_schema_sha256"],"classification_sha256"=>m["classification_sha256"],"normalizer_version"=>m["normalizer_version"],"normalizer_sha256"=>m["normalizer_sha256"],"toolchain_sha256"=>m["toolchain_sha256"],"go_sha256"=>m["go_sha256"],"executor_pin_sha256"=>m["executor"]["pin_sha256"],"executor_sha256"=>ep[2]};sh=Digest::SHA256.hexdigest(JSON.generate(s));s["root_digest"]=Digest::SHA256.hexdigest(([bind]+a.map{|r|r["evidence_sha256"]}+[sh]).join("\n"));File.write(out,([m]+a+[s]).map{|r|JSON.generate(r)}.join("\n")+"\n")
RUBY
# A completely invented green run can satisfy all structural invariants and
# recompute all its own hashes.  It still has no reviewed production root.
expect_fail self_hashes_are_not_authentication "evidence root is not anchored" \
  "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/evidence.pass"

# All remaining mutations start from evidence emitted by the real production
# gate, not from the synthetic green document above.
PRODUCTION="$ROOT/tests/go-by-example/story198-current.jsonl.fail"
"$ROOT/tools/go-by-example/validate-evidence.rb" "$PRODUCTION" >/dev/null
cp "$PRODUCTION" "$W/missing-mode.fail"
ruby -rjson - "$W/missing-mode.fail" <<'RUBY'
p=ARGV[0]; rows=File.readlines(p,chomp:true).map{|x|JSON.parse(x)}
# Preserve 255 records while replacing arrays:oracle with a duplicate
# arrays:interpreted. This reaches the real pair-set check, not only line count.
rows[1]=rows[2].dup
File.write(p,rows.map{|x|JSON.generate(x)}.join("\n")+"\n")
RUBY
expect_fail missing_mode_evidence "missing, duplicate, reordered, or foreign row/mode evidence" "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/missing-mode.fail"
cp "$PRODUCTION" "$W/missing-row.fail"
ruby -rjson - "$W/missing-row.fail" <<'RUBY'
p=ARGV[0]; rows=File.readlines(p,chomp:true).map{|x|JSON.parse(x)}
# Preserve all modes and the record count, but replace the first row's triple
# with the second row's triple.
rows[1,3]=rows[4,3].map(&:dup)
File.write(p,rows.map{|x|JSON.generate(x)}.join("\n")+"\n")
RUBY
expect_fail missing_row_evidence "missing, duplicate, reordered, or foreign row/mode evidence" "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/missing-row.fail"
cp "$PRODUCTION" "$W/tampered.fail"
sed '2s/"spawned":true/"spawned":false/' "$W/tampered.fail" > "$W/x" && mv "$W/x" "$W/tampered.fail"
expect_fail result_tampering "result tampering detected" "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/tampered.fail"

# Change the raw bytes for the deterministic arrays oracle while deliberately
# retaining its formerly valid normalized bytes. Recompute the attempt hash and
# public root so only independent raw-output normalization can catch the stale
# comparator input.
cp "$PRODUCTION" "$W/arrays-stale-normalized.fail"
ruby -rjson -rdigest -rbase64 - "$W/arrays-stale-normalized.fail" <<'RUBY'
p=ARGV[0];rows=File.readlines(p,chomp:true).map{|x|JSON.parse(x)}
r=rows.find{|x|x["path"]=="examples/arrays/arrays.go"&&x["mode"]=="oracle"} or abort "arrays oracle absent"
r["raw_stdout_b64"]=Base64.strict_encode64("attacker-controlled arrays output\n")
body=r.reject{|k,_|k=="evidence_sha256"};r["evidence_sha256"]=Digest::SHA256.hexdigest(JSON.generate(body))
s=rows[-1];sb=s.reject{|k,_|k=="root_digest"};binding=Digest::SHA256.hexdigest(JSON.generate(rows[0]))
s["root_digest"]=Digest::SHA256.hexdigest(([binding]+rows[1...-1].map{|x|x["evidence_sha256"]}+[Digest::SHA256.hexdigest(JSON.generate(sb))]).join("\n"))
File.write(p,rows.map{|x|JSON.generate(x)}.join("\n")+"\n")
RUBY
expect_fail arrays_raw_stale_normalized "stored normalized output differs from independently recomputed bytes: examples/arrays/arrays.go:oracle" \
  "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/arrays-stale-normalized.fail"

# Run a source-mutated private copy of the production gate. These cases exercise
# Open3 spawning, child deadlines, bounded cleanup, record construction, and
# atomic FAIL publication. They are not source-text assertions or JSON forgeries.
MROOT="$W/production-mutations"
cp -R "$ROOT" "$MROOT"
MFIXTURE="$ROOT/tests/go-by-example/fixture-executor.sh"
LEAKER="$ROOT/tests/go-by-example/leak-descendant.sh"
chmod +x "$LEAKER"
chmod +x "$MFIXTURE"
MSHA="$(shasum -a 256 "$MFIXTURE" | awk '{print $1}')"
awk -F '\t' -v OFS='\t' -v s="$MSHA" '$1 !~ /^#/ && NF {$3=s} {print}' \
  "$MROOT/docs/go-by-example/executor.tsv" >"$W/mutation-executor.tsv"
mv "$W/mutation-executor.tsv" "$MROOT/docs/go-by-example/executor.tsv"

mutated_gate() {
  # Bounds are per-case: the timeout mutation needs a tight child budget,
  # while the leak mutation needs enough of one for a real descendant to
  # detach before the gate's cleanup runs.
  local name="$1" mutation="$2" expected_state="$3"
  local row="${4:-.12}" compile="${5:-.05}" run="${6:-.04}" cleanup="${7:-.01}"
  local repo="$W/gate-$name" result="$W/result-$name.jsonl"
  cp -R "$MROOT" "$repo"
  ruby - "$repo/tools/go-by-example/gate.rb" "$MFIXTURE" "$mutation" "$LEAKER" <<'RUBY'
p,fixture,mutation,leaker=ARGV; s=File.read(p)
def replace!(s, old, new)
  abort "mutation target absent" unless s.include?(old)
  s.sub!(old,new)
end
# Authentication still runs first. Only the execution phase in this private
# copy is narrowed to one genuine inventory row and redirected to the fixture.
replace!(s,'def sig(s,p)','rows=rows.first(1);go='+fixture.dump+"\ndef sig(s,p)")
case mutation
when 'spawn_error'
  replace!(s,'"compiled"=>[artifact,*args]','"compiled"=>[ROOT+"/definitely-missing-executable",*args]')
when 'timeout'
  replace!(s,'"compiled"=>[artifact,*args]','"compiled"=>["/bin/sleep","5"]')
when 'leak'
  # A genuine survivor, not a forced state. Only the compiled command changes:
  # it exits 0 after putting a descendant in its own session, so the gate's
  # unmodified process-group TERM/KILL provably cannot reach it and
  # kill(0, -pgid) cannot even see it. Nothing in the cleanup, record or
  # publication path is weakened, and no line asserts state=="leak".
  replace!(s,'"compiled"=>[artifact,*args]','"compiled"=>['+leaker.dump+']')
else abort "unknown mutation"
end
File.write(p,s)
RUBY
  if env GBE_SKIP_INTEGRITY=1 BASHY_BIN="$MFIXTURE" GBE_RESULTS="$result" \
      GBE_ROW_TIMEOUT="$row" GBE_COMPILE_TIMEOUT="$compile" GBE_RUN_TIMEOUT="$run" GBE_CLEANUP_TIMEOUT="$cleanup" \
      ruby "$repo/tools/go-by-example/gate.rb" >"$W/$name.log" 2>&1; then
    echo "FAIL $name production mutation passed" >&2; exit 1
  fi
  if [[ ! -f "$result.fail" ]]; then
    echo "FAIL $name produced no FAIL evidence" >&2
    sed -n '1,12p' "$W/$name.log" >&2
    exit 1
  fi
  ruby -rjson - "$result.fail" "$expected_state" <<'RUBY'
rows=File.readlines(ARGV[0],chomp:true).map{|x|JSON.parse(x)}
a=rows.find{|r|r["type"]=="attempt" && r["mode"]=="compiled"}
abort "compiled state #{a&&a['state']}, want #{ARGV[1]}" unless a&&a["state"]==ARGV[1]
s=rows.last
abort "mutation did not publish honest red summary" unless s["type"]=="summary"&&s["verdict"]=="fail"&&s["executed"]<255&&s["missing_or_unspawned"]>0
RUBY
  pass=$((pass+1)); echo "PASS $name"
}
mutated_gate spawn_error spawn_error unspawned
mutated_gate timeout timeout timeout
mutated_gate leak leak leak 20 5 8 .25

# Change a production attempt, then recompute all self-hashes and the root.
# Independent verdict/summary derivation and the reviewed production root must
# still reject attacker-controlled changes.
mutate_evidence() {
  local source="$1" dest="$2" field="$3" value="$4"
  ruby -rjson -rdigest - "$source" "$dest" "$field" "$value" <<'RUBY'
rows=File.readlines(ARGV[0],chomp:true).map{|x|JSON.parse(x)};r=rows[2];v=ARGV[3]=="true" ? true:ARGV[3]=="false" ? false:ARGV[3];r[ARGV[2]]=v;body=r.reject{|k,_|k=="evidence_sha256"};r["evidence_sha256"]=Digest::SHA256.hexdigest(JSON.generate(body));s=rows[-1];sb=s.reject{|k,_|k=="root_digest"};s["root_digest"]=Digest::SHA256.hexdigest(([Digest::SHA256.hexdigest(JSON.generate(rows[0]))]+rows[1...-1].map{|x|x["evidence_sha256"]}+[Digest::SHA256.hexdigest(JSON.generate(sb))]).join("\n"));File.write(ARGV[1],rows.map{|x|JSON.generate(x)}.join("\n")+"\n")
RUBY
}
# A comparator may not wave a real mismatch through merely by rewriting the
# per-attempt verdict and all attacker-controlled hashes.
mutate_evidence "$PRODUCTION" "$W/permissive-comparator.fail" verdict pass
expect_fail permissive_comparator "per-attempt verdict is not derived" "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/permissive-comparator.fail"
cp "$PRODUCTION" "$W/tampered-summary.fail"; ruby -rjson -rdigest - "$W/tampered-summary.fail" <<'RUBY'
p=ARGV[0];rows=File.readlines(p,chomp:true).map{|x|JSON.parse(x)};s=rows[-1];s["failures"]=["invented"];sb=s.reject{|k,_|k=="root_digest"};s["root_digest"]=Digest::SHA256.hexdigest(([Digest::SHA256.hexdigest(JSON.generate(rows[0]))]+rows[1...-1].map{|x|x["evidence_sha256"]}+[Digest::SHA256.hexdigest(JSON.generate(sb))]).join("\n"));File.write(p,rows.map{|x|JSON.generate(x)}.join("\n")+"\n")
RUBY
expect_fail tampered_summary "summary is not independently derived" "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/tampered-summary.fail"
cp "$PRODUCTION" "$W/tampered-root.fail"; sed '257s/"root_digest":"[0-9a-f]*"/"root_digest":"0000000000000000000000000000000000000000000000000000000000000000"/' "$W/tampered-root.fail" >"$W/x"; mv "$W/x" "$W/tampered-root.fail"
expect_fail tampered_root "summary-bound root digest mismatch" "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/tampered-root.fail"
# The executor and the oracle must come from the SAME reviewed Go release. A
# Go 1.26 provenance record on the executor pin is refused by the production
# gate and by the reproducer, before any artifact is trusted.
cp -R "$ROOT" "$W/repo126"
awk -F '\t' -v OFS='\t' -v s="$FIXTURE_SHA" '$1 !~ /^#/ && NF {$3=s; $7="go version go1.26.0 darwin/arm64"} {print}' \
  "$W/repo126/docs/go-by-example/executor.tsv" >"$W/executor126.tsv"
cp "$W/executor126.tsv" "$W/repo126/docs/go-by-example/executor.tsv"
expect_fail go126_executor_pin_rejected "executor pin was not built by the pinned Go toolchain" \
  env GBE_SKIP_INTEGRITY=1 BASHY_BIN="$FIXTURE_EXEC" "$W/repo126/tools/go-by-example/gate.sh"
expect_fail go126_executor_build_rejected "but the reviewed toolchain is 'go version go1.27.0" \
  env GBE_EXECUTOR_PIN="$W/executor126.tsv" "$ROOT/tools/go-by-example/build-executor.sh" "$W/unused-executor"
expect_fail go126_evidence_pin_rejected "executor pin was not built by the pinned Go toolchain" \
  "$W/repo126/tools/go-by-example/validate-evidence.rb" "$PRODUCTION"

# Mirror of arrays_raw_stale_normalized: keep the real raw bytes and rewrite the
# stored normalized bytes instead. Recompute the attempt hash and the public
# root so only independent recomputation from raw output can catch it.
cp "$PRODUCTION" "$W/arrays-stale-raw.fail"
ruby -rjson -rdigest -rbase64 - "$W/arrays-stale-raw.fail" <<'RB'
p=ARGV[0];rows=File.readlines(p,chomp:true).map{|x|JSON.parse(x)}
r=rows.find{|x|x["path"]=="examples/arrays/arrays.go"&&x["mode"]=="oracle"} or abort "arrays oracle absent"
r["normalized_stdout_b64"]=Base64.strict_encode64("attacker-preferred comparator input\n")
body=r.reject{|k,_|k=="evidence_sha256"};r["evidence_sha256"]=Digest::SHA256.hexdigest(JSON.generate(body))
s=rows[-1];sb=s.reject{|k,_|k=="root_digest"};binding=Digest::SHA256.hexdigest(JSON.generate(rows[0]))
s["root_digest"]=Digest::SHA256.hexdigest(([binding]+rows[1...-1].map{|x|x["evidence_sha256"]}+[Digest::SHA256.hexdigest(JSON.generate(sb))]).join("\n"))
File.write(p,rows.map{|x|JSON.generate(x)}.join("\n")+"\n")
RB
expect_fail arrays_stale_raw_for_normalized "stored normalized output differs from independently recomputed bytes: examples/arrays/arrays.go:oracle" \
  "$ROOT/tools/go-by-example/validate-evidence.rb" "$W/arrays-stale-raw.fail"

# The evidence validator revalidates the authored classification table, the
# behavior schema and their adapter/normalization coupling on its own. These
# three cases mutate a private repository copy and run only the validator.
CROW='examples/atomic-counters/atomic-counters.go'
cp -R "$ROOT" "$W/cls-repo"
sed "s|^\(${CROW}\tprogram\tconcurrency\tnone\t\)bounded_wait\t|\1bounded_wait,tmpdir\t|" \
  "$ROOT/docs/go-by-example/classification.tsv" >"$W/cls-repo/docs/go-by-example/classification.tsv"
expect_fail classification_not_bound_to_inventory "inventory classification columns do not match the authored classification table" \
  "$W/cls-repo/tools/go-by-example/validate-evidence.rb" "$PRODUCTION"
sed "s|^\(${CROW}\tprogram\tconcurrency\tnone\t\)bounded_wait\t|\1bounded_wait,tmpdir\t|" \
  "$ROOT/docs/go-by-example/inventory.tsv" >"$W/cls-repo/docs/go-by-example/inventory.tsv"
expect_fail unlicensed_adapter_coupling "row carries an adapter no declared behavior requires: ${CROW}" \
  "$W/cls-repo/tools/go-by-example/validate-evidence.rb" "$PRODUCTION"

# An uninventoried file in the corpus tree is invisible to per-row digest
# checks; the validator's own standalone corpus revalidation still sees it.
cp -R "$ROOT" "$W/stray-repo"
printf 'not reviewed\n' >"$W/stray-repo/examples/stray.txt"
expect_fail unanchored_corpus_file "standalone corpus integrity revalidation failed" \
  "$W/stray-repo/tools/go-by-example/validate-evidence.rb" "$PRODUCTION"

echo "PASS: $pass genuine mutations/invariants checked"
