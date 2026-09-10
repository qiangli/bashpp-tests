#!/usr/bin/env ruby
# Sprint: #118; Story: #20; Story-ID: 405d0d96bb28
# Authenticate the retained Candidate024 two-row diagnostic. This validator is
# intentionally separate from, and cannot select rows for, the production gate.
require "base64"
require "digest"
require "json"
require_relative "candidate"

abort "usage: validate-bounded-evidence.rb EVIDENCE INVENTORY" unless ARGV.size == 2

ROOT = File.expand_path("../..", __dir__)
DOCS = ROOT + "/docs/go-by-example"
MODES = %w[oracle interpreted compiled].freeze
EXPECTED = {
  "evidence_sha256" => "487d225f2ff8fc0d7002dc294e7a2b2ffc7726f803a462f2d1840e86307a6dc2",
  "inventory_sha256" => "e6dd7e665dab8dc3a2d5d86123edaf3e1734fcc4f096bcd7e0f72f7f2d9eba38",
  "candidates_sha256" => "6fb7829f5456f288f0eb06c7b33499f90ff69ae651e00db0d995f6404acaf02c",
  "candidate_manifest_sha256" => "2aef622e6c5db1a04b168e1fc508dd125c80ab7ef10eacbeab8183bc37eefd01",
  "ledger_sha256" => "134638c3beff5a0894dc9e99df98a3b0a1c0bfdd06610b5e88ddc3adf5fe8f04",
  "root_digest" => "07858fc7e7dce884e536538d4166de1e6c2670590262cdb3758e243627a011c5"
}.freeze
CASES = {
  "examples/generics/generics.go" => {
    "sha256" => "d070bee32f553632b83695063238193edb07d29ba609d12fb478d461dc352563",
    "bytes" => 2236,
    "diagnostic" => "BASHPP-EGENERIC-CONSTRAINT: []string does not satisfy constraint for S in SlicesIndex",
    "exit" => 1
  },
  "examples/range-over-iterators/range-over-iterators.go" => {
    "sha256" => "7ee6216ba19fe8e06821e1e46391a5040f3ae29c289f477d17c6a5f1b8f60717",
    "bytes" => 2667,
    "diagnostic" => "BASHPP-ESELECTOR-TYPE: assignment parent is not struct storage",
    "exit" => 2
  }
}.freeze

def die(message)
  abort "FATAL: #{message}"
end

def sha(path)
  Digest::SHA256.file(path).hexdigest
end

def checked_file(path, description)
  die("#{description} missing") unless File.file?(path)
  File.realpath(path)
rescue SystemCallError => error
  die("#{description} unavailable: #{error.message}")
end

evidence_path = checked_file(ARGV[0], "bounded evidence")
inventory_path = checked_file(ARGV[1], "bounded inventory")
candidate_table = checked_file(DOCS + "/candidates.tsv", "candidate table")
ledger_path = checked_file(DOCS + "/sprint118-candidate024-ledger.tsv", "six-row summary")

die("bounded inventory digest changed") unless sha(inventory_path) == EXPECTED["inventory_sha256"]
inventory = File.readlines(inventory_path, chomp: true)
                .reject { |line| line.empty? || line.start_with?("#") }
                .map { |line| line.split("\t", -1) }
die("bounded inventory is not exactly the reviewed diagnostic pair") unless inventory.map(&:first) == CASES.keys
inventory.each do |row|
  path = row[0]
  expected = CASES.fetch(path)
  die("malformed bounded inventory row: #{path}") unless row.size == 8 && row[1..5] == %w[program deterministic none none none]
  die("bounded inventory source binding changed: #{path}") unless row[6] == expected["bytes"].to_s && row[7] == expected["sha256"]
  source = checked_file(ROOT + "/" + path, "bounded source #{path}")
  die("bounded source changed: #{path}") unless File.size(source) == expected["bytes"] && sha(source) == expected["sha256"]
end

begin
  records = File.readlines(evidence_path, chomp: true).map { |line| JSON.parse(line) }
rescue JSON::ParserError => error
  die("bounded evidence is not JSONL: #{error.message}")
end
die("evidence shape is not manifest, six attempts, summary") unless records.size == 8 && records.first["type"] == "manifest" && records.last["type"] == "summary"
manifest, attempts, summary = records.first, records[1...-1], records.last
die("wrong evidence schema or originating corpus story") unless manifest.values_at("schema", "story") == [8, "Sprint118/Story3/fa07603b71dc"]
die("bounded denominator is not exactly 2 x 3") unless manifest["denominator"] == {"rows" => 2, "modes_per_row" => 3, "attempts" => 6} && manifest["modes"] == MODES
die("manifest inventory binding changed") unless manifest["corpus_sha256"] == EXPECTED["inventory_sha256"]
corpus_root = Digest::SHA256.hexdigest(inventory.map { |row| "#{row[0]}\0#{row[7]}\n" }.join)
die("manifest inventory root changed") unless manifest["corpus_root_sha256"] == corpus_root

candidate = manifest["candidate"]
die("candidate record missing") unless candidate.is_a?(Hash)
die("candidate table binding changed") unless sha(candidate_table) == EXPECTED["candidates_sha256"] && candidate["candidates_sha256"] == EXPECTED["candidates_sha256"]
die("candidate manifest binding changed") unless candidate["manifest_sha256"] == EXPECTED["candidate_manifest_sha256"]
begin
  candidate_path = GoByExampleCandidate.manifest_path(candidate["manifest_path"])
  reviewed = GoByExampleCandidate.reviewed(manifest_sha256: candidate["manifest_sha256"])
  provenance = GoByExampleCandidate.authenticate(candidate_path, candidate["launcher_path"], reviewed, GoByExampleCandidate.toolchain)
rescue GoByExampleCandidate::Error, Corpus::ContractError, JSON::ParserError, SystemCallError => error
  die("candidate authentication failed: #{error.message}")
end
%w[manifest_sha256 launcher_sha256 payload_sha256 frontend_version build_recipe go_identity].each do |key|
  die("candidate #{key} differs from reviewed row") unless candidate[key] == reviewed[key]
end
reviewed_repositories = reviewed["repositories"].map { |name, commit| {"name" => name, "commit" => commit} }
die("candidate repositories differ from reviewed row") unless candidate["repositories"] == reviewed_repositories
die("authenticated candidate provenance changed") unless provenance.dig("manifest", "sha256") == EXPECTED["candidate_manifest_sha256"]

expected_pairs = CASES.keys.flat_map { |path| MODES.map { |mode| [path, mode] } }
die("attempt scope or order changed") unless attempts.map { |attempt| [attempt["path"], attempt["mode"]] } == expected_pairs
binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
retained_root = File.dirname(candidate_path) + "/"
seen_streams = {}
attempts.each do |attempt|
  body = attempt.reject { |key, _| key == "evidence_sha256" }
  die("attempt binding changed: #{attempt['path']}:#{attempt['mode']}") unless attempt["binding_sha256"] == binding
  die("attempt self-hash changed: #{attempt['path']}:#{attempt['mode']}") unless attempt["evidence_sha256"] == Digest::SHA256.hexdigest(JSON.generate(body))
  die("attempt was not executed completely: #{attempt['path']}:#{attempt['mode']}") unless attempt.values_at("spawned", "state") == [true, "complete"]
  die("stored normalized output differs from deterministic raw bytes: #{attempt['path']}:#{attempt['mode']}") unless %w[stdout stderr].all? { |stream| attempt["normalized_#{stream}_b64"] == attempt["raw_#{stream}_b64"] }
  die("stored effect digest differs from recorded delta") unless attempt["effects_sha256"] == Digest::SHA256.hexdigest(attempt.fetch("effects_delta"))
  stages = attempt["stages"]
  die("missing run stage: #{attempt['path']}:#{attempt['mode']}") unless stages.is_a?(Array) && stages.last["stage"] == "run"
  stages.each do |stage|
    capture = stage["capture"]
    next unless capture
    %w[stdout stderr].each do |stream|
      artifact = capture[stream]
      die("missing retained #{stream} record") unless artifact.is_a?(Hash)
      path = checked_file(artifact["path"], "retained #{stream}")
      die("retained stream escaped Candidate024 root") unless path.start_with?(retained_root)
      die("duplicate retained stream path") if seen_streams[path]
      seen_streams[path] = true
      actual = {"sha256" => sha(path), "bytes" => File.size(path)}
      die("retained #{stream} changed") unless artifact.values_at("sha256", "bytes") == actual.values_at("sha256", "bytes") && stage["#{stream}_sha256"] == actual["sha256"]
      if stage["stage"] == "run"
        die("run #{stream} differs from retained raw bytes") unless File.binread(path) == Base64.strict_decode64(attempt.fetch("raw_#{stream}_b64"))
      end
    end
  end
  run = stages.last
  die("run-stage result differs from attempt") unless run.values_at("spawned", "state", "exit") == attempt.values_at("spawned", "state", "exit")
end

CASES.each do |path, expected|
  oracle, interpreted, compiled = MODES.map { |mode| attempts.find { |attempt| attempt.values_at("path", "mode") == [path, mode] } }
  [oracle, compiled].each do |attempt|
    die("expected successful observation changed: #{path}:#{attempt['mode']}") unless attempt.values_at("exit", "verdict") == [0, "pass"]
    die("compiled observation differs from oracle: #{path}") if attempt["mode"] == "compiled" && %w[normalized_stdout_b64 normalized_stderr_b64 effects_sha256].any? { |key| attempt[key] != oracle[key] }
  end
  diagnostic = Base64.strict_decode64(interpreted.fetch("raw_stderr_b64"))
  die("interpreted diagnostic changed: #{path}") unless interpreted.values_at("exit", "verdict") == [expected["exit"], "fail_mismatch"] && diagnostic.include?(expected["diagnostic"])
end

failures = attempts.reject { |attempt| attempt["verdict"] == "pass" }.map { |attempt| "#{attempt['path']}:#{attempt['mode']}:#{attempt['verdict']}" }
derived_summary = {"verdict" => "fail", "denominator" => 6, "attempt_records" => 6, "executed" => 6, "missing_or_unspawned" => 0, "failures" => failures}
die("summary counts or failures changed") unless summary.slice(*derived_summary.keys) == derived_summary
summary_body = summary.reject { |key, _| key == "root_digest" }
calculated_root = Digest::SHA256.hexdigest(([binding] + attempts.map { |attempt| attempt["evidence_sha256"] } + [Digest::SHA256.hexdigest(JSON.generate(summary_body))]).join("\n"))
die("summary-bound root digest changed") unless summary["root_digest"] == calculated_root
die("bounded root is not the reviewed Candidate024 root") unless calculated_root == EXPECTED["root_digest"]

ledger = File.readlines(ledger_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }
die("six-row summary digest changed") unless sha(ledger_path) == EXPECTED["ledger_sha256"]
expected_ledger = attempts.map do |attempt|
  fields = [attempt["path"], attempt["mode"], attempt["verdict"], attempt["state"], attempt["exit"].to_s]
  fields << CASES.fetch(attempt["path"])["diagnostic"] if attempt["mode"] == "interpreted"
  fields
end
die("six-row summary differs from retained attempts") unless ledger == expected_ledger
die("bounded evidence bytes are not the reviewed Candidate024 ledger") unless sha(evidence_path) == EXPECTED["evidence_sha256"]

puts "PASS: bounded Candidate024 evidence: 2 rows, 6 attempts, 4 pass, 2 interpreted fail, no parity claim, root #{calculated_root}"
