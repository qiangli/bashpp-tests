#!/usr/bin/env ruby
require "base64"
require "digest"
require "json"
require "rbconfig"
require_relative "normalizer"

abort "usage: validate-evidence.rb EVIDENCE" unless ARGV.size == 1
root = File.expand_path("../..", __dir__)
sha = ->(path) { Digest::SHA256.file(path).hexdigest }
die = ->(message) { abort "FATAL: #{message}" }
rows = File.readlines(ARGV[0], chomp: true).map { |line| JSON.parse(line) rescue die.call("invalid evidence JSON") }
die.call("evidence must contain manifest, 255 attempts, summary") unless rows.size == 257 && rows.first["type"] == "manifest" && rows.last["type"] == "summary"
manifest, attempts, summary = rows.first, rows[1...-1], rows.last

inventory_path = root + "/docs/go-by-example/inventory.tsv"
schema_path = root + "/docs/go-by-example/behavior-schema.tsv"
toolchain_path = root + "/docs/go-by-example/toolchain.tsv"
executor_pin_path = root + "/docs/go-by-example/executor.tsv"
evidence_roots_path = root + "/docs/go-by-example/evidence-roots.tsv"
classification_path = root + "/docs/go-by-example/classification.tsv"
normalizer_path = root + "/tools/go-by-example/normalizer.rb"
inventory = File.readlines(inventory_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }.select { |r| %w[program test_program].include?(r[1]) }
die.call("production inventory no longer has exactly 85 rows") unless inventory.size == 85
schema = File.readlines(schema_path, chomp: true).map { |line| line.split("\t", -1) }
schema_rows = schema.reject { |row| row.empty? || row[0].to_s.start_with?("#") }
registered_normalizations = schema_rows.map { |row| row[1] if row[0] == "normalization" }.compact
registered_adapters = schema_rows.map { |row| row[1] if row[0] == "adapter" }.compact
behaviors = schema_rows.each_with_object({}) { |row, acc| acc[row[1]] = {requires: row[2].to_s, allows: row[3].to_s} if row[0] == "behavior" }
die.call("behavior schema declares no behaviors, adapters or normalizations") if behaviors.empty? || registered_adapters.empty? || registered_normalizations.empty?
die.call("schema vocabularies must be unique") unless registered_adapters.uniq == registered_adapters && registered_normalizations.uniq == registered_normalizations
behaviors.each do |name, spec|
  spec[:requires].split(",").each { |adapter| die.call("behavior #{name} requires undeclared adapter #{adapter}") unless registered_adapters.include?(adapter) }
  spec[:allows].split(",").each { |norm| die.call("behavior #{name} allows undeclared normalization #{norm}") unless registered_normalizations.include?(norm) }
end
die.call("normalizer registry differs from production schema") unless registered_normalizations.sort == GoByExampleNormalizer::NAMES.sort
inventory.each do |row|
  path = root + "/" + row[0]
  die.call("anchored corpus source mismatch: #{row[0]}") unless File.file?(path) && File.size(path).to_s == row[6] && sha.call(path) == row[7]
  row_normalizations = row[3] == "none" ? ["none"] : row[3].split(",")
  die.call("inventory uses an unregistered normalizer: #{row[0]}") unless (row_normalizations - registered_normalizations).empty?
end
classification = File.readlines(classification_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }
die.call("classification table has malformed rows") unless classification.all? { |row| row.size == 6 }
authored = classification.select { |row| %w[program test_program].include?(row[1]) }
die.call("inventory classification columns do not match the authored classification table") unless authored == inventory.map { |row| row[0, 6] }
authored.each do |path, kind, behavior, normalization, adapter, _requires|
  declared = behavior.split(",")
  die.call("row declares an unregistered behavior: #{path}") unless declared.all? { |name| behaviors.key?(name) }
  die.call("test_harness behavior and test_program kind must agree: #{path}") unless (kind == "test_program") == declared.include?("test_harness")
  die.call("deterministic is exclusive and must compare raw bytes: #{path}") if declared.include?("deterministic") && (declared.size != 1 || normalization != "none" || adapter != "none")
  adapters = adapter == "none" ? [] : adapter.split(",")
  normalizations = normalization == "none" ? [] : normalization.split(",")
  die.call("row uses an unregistered adapter: #{path}") unless (adapters - registered_adapters).empty?
  die.call("row uses an unregistered normalizer: #{path}") unless (normalizations - registered_normalizations).empty?
  required = declared.flat_map { |name| behaviors[name][:requires].split(",") }.reject { |name| name == "none" }
  die.call("declared behavior requires an adapter the row does not carry: #{path}") unless (required - adapters).empty?
  licensed_adapters = declared.flat_map { |name| behaviors[name][:requires].split(",") }
  die.call("row carries an adapter no declared behavior requires: #{path}") unless (adapters - licensed_adapters).empty?
  licensed_normalizations = declared.flat_map { |name| behaviors[name][:allows].split(",") }
  die.call("row carries a normalization no declared behavior licenses: #{path}") unless (normalizations - licensed_normalizations).empty?
end
die.call("standalone corpus integrity revalidation failed") unless system(root + "/tools/go-by-example/validate.sh", out: File::NULL)
corpus_root = Digest::SHA256.hexdigest(inventory.map { |r| "#{r[0]}\0#{r[7]}\n" }.join)

os = RbConfig::CONFIG["host_os"].sub(/darwin.*/, "darwin").sub(/linux.*/, "linux")
arch = RbConfig::CONFIG["host_cpu"].sub("aarch64", "arm64").sub("x86_64", "amd64")
toolpin = File.readlines(toolchain_path, chomp: true).reject { |x| x.empty? || x.start_with?("#") }.map { |x| x.split("\t", -1) }.find { |r| r[0] == os && r[1] == arch }
epin = File.readlines(executor_pin_path, chomp: true).reject { |x| x.empty? || x.start_with?("#") }.map { |x| x.split("\t", -1) }.find { |r| r[0] == os && r[1] == arch }
die.call("no local production anchor row") unless toolpin && epin
die.call("executor pin was not built by the pinned Go toolchain: #{epin[6].inspect} != #{toolpin[3].inspect}") unless epin[6] == toolpin[3]

anchors = {
  "corpus_sha256" => sha.call(inventory_path), "corpus_root_sha256" => corpus_root,
  "behavior_schema_sha256" => sha.call(schema_path), "classification_sha256" => sha.call(classification_path),
  "normalizer_version" => GoByExampleNormalizer::VERSION,
  "normalizer_sha256" => sha.call(normalizer_path), "toolchain_sha256" => sha.call(toolchain_path),
  "go_sha256" => toolpin[4]
}
anchors.each { |key, value| die.call("manifest #{key} is not anchored to production") unless manifest[key] == value }
die.call("unsupported evidence schema") unless manifest["schema"] == 6
die.call("executor pin is not anchored to production") unless manifest.dig("executor", "pin_sha256") == sha.call(executor_pin_path) && manifest.dig("executor", "sha256") == epin[2]
die.call("invalid manifest denominator/modes") unless manifest["denominator"] == {"rows"=>85, "modes_per_row"=>3, "attempts"=>255} && manifest["modes"] == %w[oracle interpreted compiled]
die.call("wrong durable story binding") unless manifest["story"] == "Sprint98/Story198/fa07603b71dc"

binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
expected_pairs = inventory.flat_map { |r| %w[oracle interpreted compiled].map { |mode| [r[0], mode] } }
actual_pairs = attempts.map { |r| [r["path"], r["mode"]] }
die.call("missing, duplicate, reordered, or foreign row/mode evidence") unless actual_pairs == expected_pairs

attempts.each do |attempt|
  body = attempt.reject { |key, _| key == "evidence_sha256" }
  die.call("result tampering detected") unless attempt["binding_sha256"] == binding && attempt["evidence_sha256"] == Digest::SHA256.hexdigest(JSON.generate(body))
  inventory_row = inventory.find { |row| row[0] == attempt["path"] }
  normalizations = inventory_row[3] == "none" ? [] : inventory_row[3].split(",")
  begin
    raw_stdout = Base64.strict_decode64(attempt.fetch("raw_stdout_b64"))
    raw_stderr = Base64.strict_decode64(attempt.fetch("raw_stderr_b64"))
    expected_stdout = Base64.strict_encode64(GoByExampleNormalizer.normalize(raw_stdout, normalizations, :stdout))
    expected_stderr = Base64.strict_encode64(GoByExampleNormalizer.normalize(raw_stderr, normalizations, :stderr))
    attempt["_recomputed_normalized"] = [expected_stdout, expected_stderr]
  rescue KeyError, ArgumentError
    die.call("invalid raw output encoding: #{attempt['path']}:#{attempt['mode']}")
  rescue StandardError
    attempt["_recomputed_normalized"] = nil
  end
end

attempts.each_slice(3) do |triple|
  oracle = triple[0]
  oracle_recomputed = oracle["_recomputed_normalized"]
  triple.each do |attempt|
    recomputed = attempt.delete("_recomputed_normalized")
    stored = [attempt["normalized_stdout_b64"], attempt["normalized_stderr_b64"]]
    if stored != (recomputed || [nil, nil])
      die.call("stored normalized output differs from independently recomputed bytes: #{attempt['path']}:#{attempt['mode']}")
    end
    expected = if !attempt["spawned"] || attempt["state"] != "complete"
      "fail_incomplete"
    elsif recomputed.nil? || oracle_recomputed.nil?
      "fail_normalization"
    elsif attempt["mode"] == "oracle" || (attempt["exit"] == oracle["exit"] && recomputed == oracle_recomputed)
      "pass"
    else
      "fail_mismatch"
    end
    die.call("per-attempt verdict is not derived from production evidence: #{attempt['path']}:#{attempt['mode']}") unless attempt["verdict"] == expected
  end
end

executed = attempts.count { |r| r["spawned"] }
failures = attempts.reject { |r| r["verdict"] == "pass" }.map { |r| "#{r['path']}:#{r['mode']}:#{r['verdict']}" }
complete_pass = attempts.all? { |r| r["spawned"] && r["state"] == "complete" && r["verdict"] == "pass" }
expected_summary = {"type"=>"summary", "verdict"=>(complete_pass && executed == 255 && failures.empty? ? "pass" : "fail"), "denominator"=>255, "attempt_records"=>255, "executed"=>executed, "missing_or_unspawned"=>255-executed, "failures"=>failures}.merge(anchors).merge("executor_pin_sha256"=>sha.call(executor_pin_path), "executor_sha256"=>epin[2])
summary_without_root = summary.reject { |key, _| key == "root_digest" }
die.call("summary is not independently derived from anchored evidence") unless summary_without_root == expected_summary
summary_hash = Digest::SHA256.hexdigest(JSON.generate(summary_without_root))
evidence_root = Digest::SHA256.hexdigest(([binding] + attempts.map { |r| r["evidence_sha256"] } + [summary_hash]).join("\n"))
die.call("summary-bound root digest mismatch") unless summary["root_digest"] == evidence_root
die.call("verdict/path mismatch") unless ARGV[0].end_with?(".#{summary['verdict']}")
# SHA-256 links fields together but cannot say who produced them: an attacker
# can invent output and recompute every hash.  Authentication comes from a
# separately reviewed, committed root.  Keep this check after the independent
# derivations above so mutations receive the most precise fail-closed diagnosis.
root_anchors = File.readlines(evidence_roots_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }
anchor = root_anchors.find { |row| row == [manifest["story"], "tests/go-by-example/story198-current.jsonl.#{summary['verdict']}", summary["verdict"], evidence_root] }
die.call("evidence root is not anchored to reviewed production evidence") unless anchor
if summary["verdict"] == "pass"
  die.call("PASS requires denominator=executed=255, missing=0, every attempt complete/pass, and no failures") unless summary["denominator"] == 255 && summary["executed"] == 255 && summary["missing_or_unspawned"] == 0 && failures.empty? && complete_pass
end
puts "PASS: authenticated #{summary['verdict']} evidence, denominator=255 executed=#{executed} missing=#{255-executed} root_digest=#{evidence_root}"
