#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Diagnostic grouping only. This never changes a verdict or certifies a run.
require 'base64'
require 'digest'
require 'json'
require 'fileutils'

abort 'usage: summarize-evidence.rb EVIDENCE_JSONL OUTPUT_DIRECTORY' unless ARGV.size == 2
input, output = ARGV
bytes = File.binread(input)
lines = bytes.lines
lines.pop if !bytes.end_with?("\n") && input.end_with?('.progress.jsonl')
records = lines.map { |line| JSON.parse(line) }
manifest = records.first
abort 'missing manifest' unless manifest && manifest['type'] == 'manifest'
binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
attempts = records.select { |record| record['type'] == 'attempt' }
attempts.each do |attempt|
  body = attempt.reject { |key, _| key == 'evidence_sha256' }
  abort 'invalid attempt integrity' unless attempt['binding_sha256'] == binding && Digest::SHA256.hexdigest(JSON.generate(body)) == attempt['evidence_sha256']
end

def diagnostics(attempt)
  stderr = Base64.strict_decode64(attempt.fetch('raw_stderr_b64'))
  failed = attempt.fetch('stages').find { |stage| stage['stage'] != 'run' && (stage['state'] != 'complete' || stage['exit'] != 0) }
  if failed
    path = failed.dig('capture', 'stderr', 'path')
    stderr = path && File.file?(path) ? File.binread(path) : failed.fetch('stderr_head', '')
  end
  [failed ? failed.fetch('stage') : 'run', stderr]
end

def family(attempt, diagnostic)
  return 'pass' if attempt['verdict'] == 'pass'
  return 'phase-input-mutation' if attempt['state'] == 'input_mutation'
  return 'deadline-or-descendant' if %w[timeout leak cleanup_error adapter_error].include?(attempt['state'])
  return 'source-conversion-array-type' if diagnostic.include?('unsupported expression *ast.ArrayType')
  return 'source-conversion-function-type' if diagnostic.include?('unsupported expression *ast.FuncType')
  return 'generic-type-index' if diagnostic.include?('unsupported type *ast.IndexExpr')
  return 'generic-method-receiver' if diagnostic.include?('invalid receiver type')
  return 'recover-lowering' if diagnostic.include?('__bpp0_popPanic')
  return 'addressable-aggregate-lowering' if diagnostic.include?('cannot take address of')
  return 'native-generic-tuple-lowering' if diagnostic.include?('MustValue')
  return 'local-named-bridge-type' if diagnostic.include?('unregistered bridge type')
  return 'native-process-exit-propagation' if diagnostic.include?('dependency process exited: exit status')
  return 'imported-structured-type' if diagnostic.include?('undefined type: __gosource_import')
  return 'imported-aggregate-selector' if diagnostic.match?(/BASHPP-ESELECTOR-(?:ROOT|TYPE)/)
  return 'channel-receive-expression' if diagnostic.include?('unsupported unary operator ILLEGAL')
  return 'aggregate-composite-expression' if diagnostic.include?('unsupported scalar expression *syntax.BashPPCompositeLit')
  return 'address-argument' if diagnostic.include?('unsupported scalar expression *syntax.BashPPAddressExpr')
  return 'local-struct-field' if diagnostic.include?('BASHPP-ESTRUCT-UNKNOWN')
  return 'multiple-assignment-or-tuple' if diagnostic.include?('assignment mismatch:')
  return 'native-argument-type-identity' if diagnostic.include?('not assignable to')
  return 'callback-or-callable-value' if diagnostic.include?('BASHPP-EEXPR-UNDEFINED') || diagnostic.include?('function literal')
  return 'offline-build-dependency' if diagnostic.include?('GOPROXY=off') || diagnostic.include?('updates to go.mod needed')
  return 'source-map-contract' if attempt.fetch('stages').any? { |stage| stage['state'] == 'invalid_source_map' }
  return 'runtime-filesystem-effects' if attempt['verdict'] == 'fail_effects'
  return 'comparator-shape-or-prior-error' if attempt['verdict'] == 'fail_normalization'
  return 'stage-unavailable' if attempt['state'] == 'unspawned'
  return 'program-diagnostic' unless diagnostic.empty?
  'output-or-status-mismatch'
end

rows = attempts.map do |attempt|
  phase, diagnostic = diagnostics(attempt)
  captures = attempt.fetch('stages').map { |stage| stage['capture'] }.compact
  {
    'path' => attempt.fetch('path'), 'mode' => attempt.fetch('mode'),
    'verdict' => attempt.fetch('verdict'), 'state' => attempt.fetch('state'), 'exit' => attempt['exit'],
    'phase' => phase, 'family' => family(attempt, diagnostic),
    'diagnostic' => diagnostic, 'stdout' => Base64.strict_decode64(attempt.fetch('raw_stdout_b64')),
    'effects_delta' => attempt['effects_delta'],
    'captures' => captures.map { |capture| capture.slice('argv', 'cwd', 'environment', 'stdout', 'stderr', 'timeout_seconds') }
  }
end
summary = records.find { |record| record['type'] == 'summary' }
report = {
  'purpose' => 'failure taxonomy; original execution verdicts preserved',
  'input' => File.expand_path(input), 'input_sha256' => Digest::SHA256.hexdigest(bytes),
  'candidate_manifest_sha256' => manifest.dig('candidate', 'manifest_sha256'),
  'complete_ledger' => !summary.nil?, 'expected_attempts' => manifest.dig('denominator', 'attempts'),
  'recorded_attempts' => attempts.size, 'recorded_rows' => attempts.map { |a| a['path'] }.uniq.size,
  'summary' => summary,
  'modes' => attempts.group_by { |a| a['mode'] }.transform_values { |items| items.group_by { |a| a['verdict'] }.transform_values(&:size) },
  'families' => rows.group_by { |row| [row['mode'], row['family']] }.sort.map { |(mode, name), items| {'mode' => mode, 'family' => name, 'count' => items.size, 'paths' => items.map { |item| item['path'] }} }
}
FileUtils.mkdir_p(output)
File.write(File.join(output, 'taxonomy.json'), JSON.pretty_generate(report) + "\n")
File.write(File.join(output, 'failures.jsonl'), rows.reject { |row| row['verdict'] == 'pass' }.map { |row| JSON.generate(row) }.join("\n") + "\n")
File.write(File.join(output, 'ledger.tsv'), ([%w[path mode verdict state exit phase family].join("\t")] + rows.map { |row| row.values_at('path', 'mode', 'verdict', 'state', 'exit', 'phase', 'family').join("\t") }).join("\n") + "\n")
puts JSON.generate(report.slice('complete_ledger', 'recorded_rows', 'recorded_attempts', 'modes'))
