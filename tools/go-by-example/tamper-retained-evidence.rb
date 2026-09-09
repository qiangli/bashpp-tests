#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Mutate a retained REAL execution ledger; never produce an execution verdict.
require 'base64'
require 'digest'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

abort 'usage: tamper-retained-evidence.rb AUTHENTICATED_EVIDENCE' unless ARGV.size == 1
validator = File.join(__dir__, 'validate-evidence.rb')
source = File.expand_path(ARGV.fetch(0))
output, status = Open3.capture2e(RbConfig.ruby, validator, source)
abort "real evidence prerequisite failed:\n#{output}" unless status.success?
original = File.readlines(source).map { |line| JSON.parse(line) }
checks = {
  'duplicate-stream' => ['duplicate retained stage stream path', lambda { |rows|
    stage = rows[1].fetch('stages').find { |s| s['capture'] }
    stage['capture']['stderr'] = stage['capture'].fetch('stdout').dup
  }],
  'raw-stream-substitution' => ['run raw bytes differ from retained capture', lambda { |rows|
    rows[1]['raw_stdout_b64'] = Base64.strict_encode64('unobserved program output')
  }],
  'native-artifact-digest' => ['retained native_file changed', lambda { |rows|
    stage = rows[1].fetch('stages').find { |s| s['native_file'] }
    stage.fetch('native_file')['sha256'] = '0' * 64
  }],
  'telemetry-mode-digest' => ['telemetry mode file changed', lambda { |rows|
    rows[1].fetch('configuration').fetch('mode_file')['sha256'] = '0' * 64
  }],
  'telemetry-configuration-command' => ['invalid telemetry setup commands', lambda { |rows|
    rows[1].fetch('configuration').fetch('stages')[0]['argv'][2] = 'on'
  }]
}
Dir.mktmpdir('gbe-retained-tamper-') do |dir|
  checks.each do |name, (diagnosis, mutate)|
    rows = Marshal.load(Marshal.dump(original))
    mutate.call(rows)
    # Recompute the modified record's integrity hash. Rejection must come from
    # independently retained facts, not the trivial self-hash mismatch.
    rows[1]['evidence_sha256'] = Digest::SHA256.hexdigest(JSON.generate(rows[1].reject { |key, _| key == 'evidence_sha256' }))
    path = File.join(dir, name + '.jsonl.fail')
    File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
    output, status = Open3.capture2e(RbConfig.ruby, validator, path)
    abort "FAIL #{name}: wrong acceptance/diagnosis:\n#{output}" if status.success? || !output.include?(diagnosis)
    puts "PASS #{name}"
  end
end
puts "PASS #{checks.size} retained-evidence mutations against authenticated real execution"
