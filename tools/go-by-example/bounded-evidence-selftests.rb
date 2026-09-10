#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story: #20; Story-ID: 405d0d96bb28
# Sprint: #118; Story: #22; Story-ID: 6fd56605a361
# Sprint: #118; Story: #23; Story-ID: 72ac9344b150
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Tamper the retained bounded evidence chains and their bindings; every mutation
# must be rejected by the real validate-bounded-evidence.rb, never asserted from
# here. Candidates024-027 are exercised through the same generalized validator.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
VALIDATOR = File.join(ROOT, 'tools/go-by-example/validate-bounded-evidence.rb')
STATE = '/Users/qiangli/.local/state/bashy/sprint118-evidence'

# Each suite is one reviewed bounded diagnostic. `source` is a bound program the
# inventory pins, `inventory_target`/`candidate_target` are byte substrings that
# exist only inside the respective reviewed files, and `label` is the reviewed
# candidate whose root can never be re-minted.
SUITES = [
  {
    'label' => 'Candidate024',
    'evidence' => "#{STATE}/runtime-integration-024/gbe-subset.jsonl.fail",
    'inventory' => "#{STATE}/runtime-integration-024/subset-inventory.tsv",
    'source' => 'examples/generics/generics.go',
    'inventory_target' => 'd070bee32f',
    'candidate_target' => 'f7dbbff0fdff337e'
  },
  {
    'label' => 'Candidate025',
    'evidence' => "#{STATE}/runtime-integration-025/gbe-subset.jsonl.pass",
    'inventory' => "#{STATE}/runtime-integration-025/subset-inventory.tsv",
    'source' => 'examples/recursion/recursion.go',
    'inventory_target' => '3e64a878e9',
    'candidate_target' => '57a8b7680573866b'
  },
  {
    'label' => 'Candidate026',
    'evidence' => "#{STATE}/runtime-integration-026/gbe-subset.jsonl.fail",
    'inventory' => "#{STATE}/runtime-integration-026/subset-inventory.tsv",
    'source' => 'examples/generics/generics.go',
    'inventory_target' => 'd070bee32f',
    'candidate_target' => '304bc25216736f83'
  },
  {
    'label' => 'Candidate027',
    'evidence' => "#{STATE}/runtime-integration-027/gbe-subset.jsonl.pass",
    'inventory' => "#{STATE}/runtime-integration-027/subset-inventory.tsv",
    'source' => 'examples/range-over-iterators/range-over-iterators.go',
    'inventory_target' => '7ee6216ba1',
    'candidate_target' => 'd2da6d9cf2e36906'
  }
].freeze

def expect_fail(name, marker, validator, evidence, inventory)
  output, status = Open3.capture2e(RbConfig.ruby, validator, evidence, inventory)
  abort "FAIL #{name} accepted" if status.success?
  abort "FAIL #{name} produced the wrong diagnostic:\n#{output}" unless output.include?(marker)
  puts "PASS #{name}"
end

def expect_pass(name, validator, evidence, inventory)
  output, status = Open3.capture2e(RbConfig.ruby, validator, evidence, inventory)
  abort "FAIL #{name} rejected:\n#{output}" unless status.success?
  puts "PASS #{name}"
end

def mutate_candidate_table!(path, target, action)
  lines = File.binread(path).lines
  index = lines.index { |line| line.include?(target) }
  abort "candidate #{action} target missing" unless index

  case action
  when :mutate
    lines[index] = lines[index].sub(target, target.sub(/\A./, '0'))
  when :delete
    lines.delete_at(index)
  when :reorder
    prior = (index - 1).downto(0).find { |i| !lines[i].start_with?('#') && !lines[i].strip.empty? }
    abort 'candidate reorder predecessor missing' unless prior
    lines[index], lines[prior] = lines[prior], lines[index]
  else
    abort "unknown candidate table action: #{action}"
  end
  File.binwrite(path, lines.join)
end

def recompute_root!(manifest, attempts, summary)
  binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
  attempts.each do |row|
    row['binding_sha256'] = binding
    row.delete('evidence_sha256')
    row['evidence_sha256'] = Digest::SHA256.hexdigest(JSON.generate(row))
  end
  body = summary.reject { |key, _| key == 'root_digest' }
  summary['root_digest'] = Digest::SHA256.hexdigest(([binding] + attempts.map { |row| row['evidence_sha256'] } +
    [Digest::SHA256.hexdigest(JSON.generate(body))]).join("\n"))
end

def run_suite(suite)
  label = suite['label']
  evidence = File.expand_path(suite['evidence'])
  inventory = File.expand_path(suite['inventory'])
  pass = 0

  Dir.mktmpdir("gbe-bounded-tamper-#{label}-") do |work|
    # 1. An inventory cannot change either a row or its source binding.
    inventory_text = File.binread(inventory)
    abort "#{label} inventory mutation target missing" unless inventory_text.sub!(suite['inventory_target'], suite['inventory_target'].sub(/\A./, '0'))
    tampered_inventory = File.join(work, 'inventory.tsv')
    File.binwrite(tampered_inventory, inventory_text)
    expect_fail("#{label} inventory_binding_tamper", 'bounded inventory digest changed', VALIDATOR, evidence, tampered_inventory)
    pass += 1

    # 2. The separately supplied inventory is still checked against repository bytes.
    repo = File.join(work, 'repo')
    FileUtils.cp_r(ROOT, repo)
    tampered_validator = File.join(repo, 'tools/go-by-example/validate-bounded-evidence.rb')
    source_path = File.join(repo, suite['source'])
    File.open(source_path, 'ab') { |file| file.write("\n") }
    expect_fail("#{label} source_tamper", "bounded source changed: #{suite['source']}", tampered_validator, evidence, inventory)
    pass += 1
    FileUtils.cp(File.join(ROOT, suite['source']), source_path)

    # 3. A syntactically valid future suffix leaves each historical prefix valid.
    candidates_path = File.join(repo, 'docs/go-by-example/candidates.tsv')
    File.open(candidates_path, 'ab') do |file|
      file.write("darwin\tarm64\t#{'0' * 64}\t#{'1' * 64}\t#{'2' * 64}\tgosource-v1\tdummy\tdummy\tdummy=0000000000000000000000000000000000000000\n")
    end
    expect_pass("#{label} candidate_suffix_append", tampered_validator, evidence, inventory)
    FileUtils.cp(File.join(ROOT, 'docs/go-by-example/candidates.tsv'), candidates_path)

    # 4. Mutation, deletion, and reordering within the selected authenticated
    # prefix all fail, even though the table remains otherwise parseable.
    %i[mutate delete reorder].each do |action|
      mutate_candidate_table!(candidates_path, suite['candidate_target'], action)
      marker = action == :delete ? 'candidate manifest row is not unique' : 'candidate table binding changed'
      expect_fail("#{label} candidate_#{action}_tamper", marker, tampered_validator, evidence, inventory)
      FileUtils.cp(File.join(ROOT, 'docs/go-by-example/candidates.tsv'), candidates_path)
      pass += 1
    end
    # 5. The evidence's recorded whole-table digest is not authority for a
    # changed authenticated prefix.
    mutate_candidate_table!(candidates_path, suite['candidate_target'], :mutate)
    expect_fail("#{label} candidate_binding_tamper", 'candidate table binding changed', tampered_validator, evidence, inventory)
    pass += 1

    # 6. Recompute every attacker-controlled JSON hash around a forged
    #    retained-stream digest. The actual retained bytes remain an
    #    independent witness.
    rows = File.readlines(evidence, chomp: true).map { |line| JSON.parse(line) }
    manifest, attempts, summary = rows.first, rows[1...-1], rows.last
    attempt = attempts.find { |row| row['mode'] == 'oracle' }
    attempt.fetch('stages').last.fetch('capture').fetch('stdout')['sha256'] = '0' * 64
    recompute_root!(manifest, attempts, summary)
    stream_evidence = File.join(work, 'stream.jsonl')
    File.write(stream_evidence, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
    expect_fail("#{label} retained_stream_tamper", 'retained stdout changed', VALIDATOR, stream_evidence, inventory)
    pass += 1

    # 7. A self-consistent replacement root is still not the independently
    #    reviewed root. This also prevents a bounded run from inventing parity.
    rows = File.readlines(evidence, chomp: true).map { |line| JSON.parse(line) }
    manifest, attempts, summary = rows.first, rows[1...-1], rows.last
    summary['parity_claim'] = true
    recompute_root!(manifest, attempts, summary)
    root_evidence = File.join(work, 'root.jsonl')
    File.write(root_evidence, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
    expect_fail("#{label} root_tamper", "bounded root is not the reviewed #{label} root", VALIDATOR, root_evidence, inventory)
    pass += 1
  end
  pass
end

total = SUITES.sum { |suite| run_suite(suite) }
puts "PASS: #{total} bounded-evidence tamper selftests across #{SUITES.size} reviewed candidates"
