#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story: #20; Story-ID: 405d0d96bb28
# Tamper the retained Candidate024 evidence chain and its bindings; every
# mutation must be rejected by the real validate-bounded-evidence.rb, never
# asserted from here.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
VALIDATOR = File.join(ROOT, 'tools/go-by-example/validate-bounded-evidence.rb')
EVIDENCE = File.expand_path(ARGV[0] || '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-024/gbe-subset.jsonl.fail')
INVENTORY = File.expand_path(ARGV[1] || '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-024/subset-inventory.tsv')

def expect_fail(name, marker, validator, evidence, inventory)
  output, status = Open3.capture2e(RbConfig.ruby, validator, evidence, inventory)
  abort "FAIL #{name} accepted" if status.success?
  abort "FAIL #{name} produced the wrong diagnostic:\n#{output}" unless output.include?(marker)
  puts "PASS #{name}"
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

pass = 0

Dir.mktmpdir('gbe-bounded-tamper-') do |work|
  # 1. An inventory cannot change either a row or its source binding.
  inventory_text = File.binread(INVENTORY)
  abort 'inventory mutation target missing' unless inventory_text.sub!('d070bee32f', '0070bee32f')
  tampered_inventory = File.join(work, 'inventory.tsv')
  File.binwrite(tampered_inventory, inventory_text)
  expect_fail('inventory_binding_tamper', 'bounded inventory digest changed', VALIDATOR, EVIDENCE, tampered_inventory)
  pass += 1

  # 2. The separately supplied inventory is still checked against repository bytes.
  repo = File.join(work, 'repo')
  FileUtils.cp_r(ROOT, repo)
  tampered_validator = File.join(repo, 'tools/go-by-example/validate-bounded-evidence.rb')
  source_path = File.join(repo, 'examples/generics/generics.go')
  File.open(source_path, 'ab') { |file| file.write("\n") }
  expect_fail('source_tamper', 'bounded source changed: examples/generics/generics.go', tampered_validator, EVIDENCE, INVENTORY)
  pass += 1
  FileUtils.cp(File.join(ROOT, 'examples/generics/generics.go'), source_path)

  # 3. The evidence's candidate-table hash is not authority for a changed table.
  candidates_path = File.join(repo, 'docs/go-by-example/candidates.tsv')
  candidates_text = File.binread(candidates_path)
  abort 'candidate mutation target missing' unless candidates_text.sub!('f7dbbff0fdff337e', '07dbbff0fdff337e')
  File.binwrite(candidates_path, candidates_text)
  expect_fail('candidate_binding_tamper', 'candidate table binding changed', tampered_validator, EVIDENCE, INVENTORY)
  pass += 1

  # 4. Recompute every attacker-controlled JSON hash around a forged
  #    retained-stream digest. The actual retained bytes remain an
  #    independent witness.
  rows = File.readlines(EVIDENCE, chomp: true).map { |line| JSON.parse(line) }
  manifest, attempts, summary = rows.first, rows[1...-1], rows.last
  attempt = attempts.find { |row| row['mode'] == 'oracle' }
  attempt.fetch('stages').last.fetch('capture').fetch('stdout')['sha256'] = '0' * 64
  recompute_root!(manifest, attempts, summary)
  stream_evidence = File.join(work, 'stream.fail')
  File.write(stream_evidence, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
  expect_fail('retained_stream_tamper', 'retained stdout changed', VALIDATOR, stream_evidence, INVENTORY)
  pass += 1

  # 5. A self-consistent replacement root is still not the independently
  #    reviewed Candidate024 root. This also prevents a bounded run from
  #    inventing parity.
  rows = File.readlines(EVIDENCE, chomp: true).map { |line| JSON.parse(line) }
  manifest, attempts, summary = rows.first, rows[1...-1], rows.last
  summary['parity_claim'] = true
  recompute_root!(manifest, attempts, summary)
  root_evidence = File.join(work, 'root.fail')
  File.write(root_evidence, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
  expect_fail('root_tamper', 'bounded root is not the reviewed Candidate024 root', VALIDATOR, root_evidence, INVENTORY)
  pass += 1
end

puts "PASS: #{pass} bounded-evidence tamper selftests"
