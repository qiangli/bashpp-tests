#!/usr/bin/env ruby
# Sprint: #118; Story: #20; Story-ID: 405d0d96bb28
# Sprint: #118; Story: #22; Story-ID: 6fd56605a361
# Sprint: #118; Story: #23; Story-ID: 72ac9344b150
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Authenticate a retained bounded diagnostic. This validator is intentionally
# separate from, and cannot select rows for, the production gate.
#
# It authenticates each reviewed bounded candidate independently, selected by
# the candidate manifest digest recorded in the evidence. Candidate024 (the
# two-row generic-receiver diagnostic) and Candidate025 (the one-row recursion
# diagnostic) are both covered. The shared docs/go-by-example/candidates.tsv is
# an append-only reviewed table, so each run authenticates the exact byte prefix
# ending at its selected manifest row before re-deriving that row through the
# shared primitives. Candidates024-027 are covered, and adding a newer reviewed
# candidate row therefore can never invalidate an older bounded run.
require "base64"
require "digest"
require "json"
require_relative "candidate"

abort "usage: validate-bounded-evidence.rb EVIDENCE INVENTORY" unless ARGV.size == 2

ROOT = File.expand_path("../..", __dir__)
DOCS = ROOT + "/docs/go-by-example"
MODES = %w[oracle interpreted compiled].freeze
# One immutable record per reviewed bounded candidate, keyed by the candidate
# manifest digest the evidence carries. `cases` maps a source path to its bound
# bytes/digest; an `interpreted` entry means that mode is a reviewed mismatch
# with the named diagnostic and exit, and its absence means every mode passes.
CANDIDATES = {
  "2aef622e6c5db1a04b168e1fc508dd125c80ab7ef10eacbeab8183bc37eefd01" => {
    "label" => "Candidate024",
    "rows" => 2,
    "attempts" => 6,
    "evidence_sha256" => "487d225f2ff8fc0d7002dc294e7a2b2ffc7726f803a462f2d1840e86307a6dc2",
    "inventory_sha256" => "e6dd7e665dab8dc3a2d5d86123edaf3e1734fcc4f096bcd7e0f72f7f2d9eba38",
    "recorded_candidates_sha256" => "6fb7829f5456f288f0eb06c7b33499f90ff69ae651e00db0d995f6404acaf02c",
    "ledger" => "sprint118-candidate024-ledger.tsv",
    "ledger_sha256" => "134638c3beff5a0894dc9e99df98a3b0a1c0bfdd06610b5e88ddc3adf5fe8f04",
    "root_digest" => "07858fc7e7dce884e536538d4166de1e6c2670590262cdb3758e243627a011c5",
    "cases" => {
      "examples/generics/generics.go" => {
        "sha256" => "d070bee32f553632b83695063238193edb07d29ba609d12fb478d461dc352563",
        "bytes" => 2236,
        "interpreted" => {
          "diagnostic" => "BASHPP-EGENERIC-CONSTRAINT: []string does not satisfy constraint for S in SlicesIndex",
          "exit" => 1
        }
      },
      "examples/range-over-iterators/range-over-iterators.go" => {
        "sha256" => "7ee6216ba19fe8e06821e1e46391a5040f3ae29c289f477d17c6a5f1b8f60717",
        "bytes" => 2667,
        "interpreted" => {
          "diagnostic" => "BASHPP-ESELECTOR-TYPE: assignment parent is not struct storage",
          "exit" => 2
        }
      }
    }
  },
  "3f74313ced28b23ee6e7bf738915db884ec7edb80015c191ad762241a390d213" => {
    "label" => "Candidate025",
    "rows" => 1,
    "attempts" => 3,
    "evidence_sha256" => "9fc7ce20e0a4152c7af85a5df8bfb59e2a77b2f7b3bcbfd02b954d8d7afb6564",
    "inventory_sha256" => "c8bdcbaccc3977211d339092b887eee84e17da6adfaff407e98e32f21529dd64",
    "recorded_candidates_sha256" => "cc3fc32dc2682209aa76355485b1707926d7fcdfe0e4b9e4d230cdbab4d072e1",
    "ledger" => "sprint118-candidate025-ledger.tsv",
    "ledger_sha256" => "2bd1a8386e516bb2054c63a40e2588d99abff370a8576d11bab99da4679f1232",
    "root_digest" => "af459aa1743b6378c30539b1b28b5e13219ef65dc39b2e0f1f8215e90c89307a",
    "cases" => {
      "examples/recursion/recursion.go" => {
        "sha256" => "3e64a878e9dd7226620ed33e36c74318b0d75bf9d0119ce02094c95b78353ec2",
        "bytes" => 778
      }
    }
  },
  "ba070aae2debb02c231cedb3625ad54e04cc20b71ad99e2125d4c202f7771aa8" => {
    "label" => "Candidate026",
    "rows" => 1,
    "attempts" => 3,
    "evidence_sha256" => "6ac6b399931c17e0eb2b96ec993ac56cfd06d6266ebc8ce57ae7db54e580b2b1",
    "inventory_sha256" => "1b93b5bc0255f5c409f5e1f71c15b0f3d16c68e41bc1250d80ad8e9d3ca57257",
    "recorded_candidates_sha256" => "6a5555ceb2995730eb3ecd16a8282ab91eca85364f46fb613f19be1480bf6470",
    "ledger" => "sprint118-candidate026-ledger.tsv",
    "ledger_sha256" => "0980dc4331f1599e3e6d622aef9c69a534b521d297c438f7c36292be54de142e",
    "root_digest" => "aaa7c16794ea3436252892abc21d17b62802133b9d9ab6efd91306ddd1a929dd",
    "cases" => {
      "examples/generics/generics.go" => {
        "sha256" => "d070bee32f553632b83695063238193edb07d29ba609d12fb478d461dc352563",
        "bytes" => 2236,
        "interpreted" => {
          "diagnostic" => "BASHPP-ESELECTOR-TYPE: assignment parent is not struct storage",
          "exit" => 2
        }
      }
    }
  },
  "f86c94dffe4d734e00be21cf15a622a24072427653f2caeba8bb440fc77ba279" => {
    "label" => "Candidate027",
    "rows" => 1,
    "attempts" => 3,
    "evidence_sha256" => "0424321650327bb8b03ed61abce40626d6cc8d607db319752b772f034fc1363c",
    "inventory_sha256" => "ea0c1d26fefb6693673963029d386c1287db248a7a466252490d7cf547dc6afd",
    "recorded_candidates_sha256" => "bd496738dac24ff1ef721a328640a250afb08ad0cf2749635ce0f2704d7501e0",
    "ledger" => "sprint118-candidate027-ledger.tsv",
    "ledger_sha256" => "527e0827951af30033371665f8625568105a68758382821333c99cd784106459",
    "root_digest" => "1a5c5b733829aa611ad9f2658182f5dcd92a59255deb7f18c43fca727c852ee2",
    "cases" => {
      "examples/range-over-iterators/range-over-iterators.go" => {
        "sha256" => "7ee6216ba19fe8e06821e1e46391a5040f3ae29c289f477d17c6a5f1b8f60717",
        "bytes" => 2667
      }
    }
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

# Authenticate the exact historical table prefix, rather than the mutable
# whole table.  The selected manifest must occur in exactly one complete TSV
# row; its newline is part of the authenticated prefix.
def authenticated_candidate_prefix(table_path, manifest_sha256, recorded_sha256)
  table = File.binread(table_path)
  offset = 0
  matches = []
  table.each_line do |line|
    offset += line.bytesize
    next if line.start_with?("#") || line.strip.empty?

    fields = line.delete_suffix("\n").split("\t", -1)
    matches << offset if fields[2] == manifest_sha256
  end
  die("candidate manifest row is not unique in candidate table") unless matches.size == 1

  prefix = table.byteslice(0, matches.first)
  die("candidate manifest row is not newline-terminated") unless prefix.end_with?("\n")
  die("candidate table binding changed") unless Digest::SHA256.hexdigest(prefix) == recorded_sha256
  die("current candidate table does not begin with authenticated prefix") unless table.start_with?(prefix)
  prefix
end

evidence_path = checked_file(ARGV[0], "bounded evidence")
inventory_path = checked_file(ARGV[1], "bounded inventory")
candidate_table = checked_file(DOCS + "/candidates.tsv", "candidate table")

begin
  records = File.readlines(evidence_path, chomp: true).map { |line| JSON.parse(line) }
rescue JSON::ParserError => error
  die("bounded evidence is not JSONL: #{error.message}")
end
die("evidence shape is not manifest, attempts, summary") unless records.size >= 3 && records.first["type"] == "manifest" && records.last["type"] == "summary"
manifest, attempts, summary = records.first, records[1...-1], records.last
candidate = manifest["candidate"]
die("candidate record missing") unless candidate.is_a?(Hash)
selected = candidate["manifest_sha256"]
entry = CANDIDATES[selected]
die("evidence names an unreviewed bounded candidate: #{selected}") unless entry
cases = entry["cases"]
ledger_path = checked_file(DOCS + "/" + entry["ledger"], "#{entry['attempts']}-row summary")

die("bounded inventory digest changed") unless sha(inventory_path) == entry["inventory_sha256"]
inventory = File.readlines(inventory_path, chomp: true)
                .reject { |line| line.empty? || line.start_with?("#") }
                .map { |line| line.split("\t", -1) }
die("bounded inventory is not exactly the reviewed diagnostic set") unless inventory.map(&:first) == cases.keys
inventory.each do |row|
  path = row[0]
  expected = cases.fetch(path)
  die("malformed bounded inventory row: #{path}") unless row.size == 8 && row[1..5] == %w[program deterministic none none none]
  die("bounded inventory source binding changed: #{path}") unless row[6] == expected["bytes"].to_s && row[7] == expected["sha256"]
  source = checked_file(ROOT + "/" + path, "bounded source #{path}")
  die("bounded source changed: #{path}") unless File.size(source) == expected["bytes"] && sha(source) == expected["sha256"]
end

die("evidence shape is not manifest, #{entry['attempts']} attempts, summary") unless records.size == entry["attempts"] + 2
die("wrong evidence schema or originating corpus story") unless manifest.values_at("schema", "story") == [8, "Sprint118/Story3/fa07603b71dc"]
die("bounded denominator is not exactly #{entry['rows']} x 3") unless manifest["denominator"] == {"rows" => entry["rows"], "modes_per_row" => 3, "attempts" => entry["attempts"]} && manifest["modes"] == MODES
die("manifest inventory binding changed") unless manifest["corpus_sha256"] == entry["inventory_sha256"]
corpus_root = Digest::SHA256.hexdigest(inventory.map { |row| "#{row[0]}\0#{row[7]}\n" }.join)
die("manifest inventory root changed") unless manifest["corpus_root_sha256"] == corpus_root

die("candidate table digest recorded by this run changed") unless candidate["candidates_sha256"] == entry["recorded_candidates_sha256"]
die("candidate manifest binding changed") unless candidate["manifest_sha256"] == selected
authenticated_candidate_prefix(candidate_table, selected, entry["recorded_candidates_sha256"])
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
die("authenticated candidate provenance changed") unless provenance.dig("manifest", "sha256") == selected

expected_pairs = cases.keys.flat_map { |path| MODES.map { |mode| [path, mode] } }
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
      die("retained stream escaped the #{entry['label']} root") unless path.start_with?(retained_root)
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

cases.each do |path, expected|
  oracle, interpreted, compiled = MODES.map { |mode| attempts.find { |attempt| attempt.values_at("path", "mode") == [path, mode] } }
  [oracle, compiled].each do |attempt|
    die("expected successful observation changed: #{path}:#{attempt['mode']}") unless attempt.values_at("exit", "verdict") == [0, "pass"]
    die("compiled observation differs from oracle: #{path}") if attempt["mode"] == "compiled" && %w[normalized_stdout_b64 normalized_stderr_b64 effects_sha256].any? { |key| attempt[key] != oracle[key] }
  end
  if (mismatch = expected["interpreted"])
    diagnostic = Base64.strict_decode64(interpreted.fetch("raw_stderr_b64"))
    die("interpreted diagnostic changed: #{path}") unless interpreted.values_at("exit", "verdict") == [mismatch["exit"], "fail_mismatch"] && diagnostic.include?(mismatch["diagnostic"])
  else
    die("expected passing interpreted observation changed: #{path}") unless interpreted.values_at("exit", "verdict") == [0, "pass"]
    die("interpreted observation differs from oracle: #{path}") if %w[normalized_stdout_b64 normalized_stderr_b64 effects_sha256].any? { |key| interpreted[key] != oracle[key] }
  end
end

failures = attempts.reject { |attempt| attempt["verdict"] == "pass" }.map { |attempt| "#{attempt['path']}:#{attempt['mode']}:#{attempt['verdict']}" }
verdict = failures.empty? ? "pass" : "fail"
derived_summary = {"verdict" => verdict, "denominator" => entry["attempts"], "attempt_records" => entry["attempts"], "executed" => entry["attempts"], "missing_or_unspawned" => 0, "failures" => failures}
die("summary counts or failures changed") unless summary.slice(*derived_summary.keys) == derived_summary
summary_body = summary.reject { |key, _| key == "root_digest" }
calculated_root = Digest::SHA256.hexdigest(([binding] + attempts.map { |attempt| attempt["evidence_sha256"] } + [Digest::SHA256.hexdigest(JSON.generate(summary_body))]).join("\n"))
die("summary-bound root digest changed") unless summary["root_digest"] == calculated_root
die("bounded root is not the reviewed #{entry['label']} root") unless calculated_root == entry["root_digest"]

ledger = File.readlines(ledger_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }
die("#{entry['attempts']}-row summary digest changed") unless sha(ledger_path) == entry["ledger_sha256"]
expected_ledger = attempts.map do |attempt|
  fields = [attempt["path"], attempt["mode"], attempt["verdict"], attempt["state"], attempt["exit"].to_s]
  mismatch = cases.fetch(attempt["path"])["interpreted"]
  fields << mismatch["diagnostic"] if attempt["mode"] == "interpreted" && mismatch
  fields
end
die("#{entry['attempts']}-row summary differs from retained attempts") unless ledger == expected_ledger
die("bounded evidence bytes are not the reviewed #{entry['label']} ledger") unless sha(evidence_path) == entry["evidence_sha256"]

passes = attempts.count { |attempt| attempt["verdict"] == "pass" }
tail = failures.empty? ? "no parity claim" : "#{failures.size} interpreted fail, no parity claim"
rows_word = entry["rows"] == 1 ? "row" : "rows"
puts "PASS: bounded #{entry['label']} evidence: #{entry['rows']} #{rows_word}, #{entry['attempts']} attempts, #{passes} pass, #{tail}, root #{calculated_root}"
