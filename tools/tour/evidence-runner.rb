#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'evidence'
require 'tempfile'

root = File.expand_path('../..', __dir__)
inventory_file = ENV.fetch('TOUR_INVENTORY', File.join(root, 'tests/tour/inventory.tsv'))
baseline_file = ENV.fetch('TOUR_BASE_RESULTS', File.join(root, 'tests/tour/results.tsv'))
output = ENV.fetch('TOUR_EVIDENCE', File.join(root, 'tests/tour/evidence.jsonl'))
normalizer = ENV.fetch('TOUR_NORMALIZER', File.join(root, 'tools/tour/normalize.rb'))
timeout = Integer(ENV.fetch('TOUR_STEP_TIMEOUT', '30'))
bashy = ENV.fetch('BASHPP_BIN') { abort 'FATAL: BASHPP_BIN must name a clean, published bashy release binary (e.g. the output of `bashy self fetch`); a workspace dev build cannot produce evidence' }

pin = File.readlines(File.join(root, 'docs/tour/pin.tsv'), chomp: true).find { |line| !line.start_with?('#') && !line.empty? }.split("\t")
version, commit, inventory_sha = pin[1], pin[2], pin[7]
tour_root = ENV.fetch('TOUR_ROOT', File.join(`go env GOMODCACHE`.strip, "golang.org/x/website@#{version}"))
tc = File.readlines(File.join(root, 'docs/tour/toolchain.tsv'), chomp: true).find { |line| !line.start_with?('#') && !line.empty? }.split("\t")
go_bin = File.join(`GOTOOLCHAIN=#{tc[2]} go env GOROOT`.strip, 'bin/go')

inventory = File.readlines(inventory_file, chomp: true).map do |line|
  next if line.start_with?('#') || line.empty?
  f = line.split("\t")
  next unless %w[applicable_go_program build_only_go_program].include?(f[3])
  { 'path' => f[0], 'applicability' => f[3], 'bytes' => Integer(f[6]), 'sha256' => f[7] }
end.compact
abort "FATAL: executable inventory must contain exactly 97 programs" unless inventory.length == 97

baseline_rows = File.readlines(baseline_file, chomp: true).map do |line|
  next if line.start_with?('#') || line.empty?
  f = line.split("\t"); [f[0], f]
end.compact.to_h

def command_info(path, version_args: ['--version'])
  return { 'path' => path, 'present' => false, 'sha256' => nil, 'version' => nil } unless File.executable?(path)
  version, = Open3.capture2e(path, *version_args)
  { 'path' => File.realpath(path), 'present' => true, 'sha256' => TourEvidence.sha(File.binread(path)), 'version' => version.lines.first.to_s.strip }
end

go_info = command_info(go_bin, version_args: ['version']).merge('identity' => tc[3], 'pinned_sha256' => tc[4])
abort "FATAL: exact Go 1.27 binary unavailable at #{go_bin}" unless go_info['present']
abort "FATAL: Go binary is not the pinned toolchain (identity #{go_info['version']}, expected #{tc[3]})" unless go_info['version'] == tc[3]
abort "FATAL: Go binary checksum does not match docs/tour/toolchain.tsv pin" unless go_info['sha256'] == tc[4]

bashy_info_raw = command_info(bashy)
abort "FATAL: bashy binary unavailable at #{bashy}" unless bashy_info_raw['present']
identity = TourEvidence.bashy_identity(bashy_info_raw['version'])
abort "FATAL: bashy build is dirty or unpublished (#{bashy_info_raw['version'].inspect}) — evidence requires a clean published release, e.g. \`bashy self fetch\`" unless identity['published'] && !identity['dirty']
bashy_info = bashy_info_raw.merge(
  'source_revision' => identity['revision'],
  'published' => identity['published'],
  'reproducible' => identity['published'] && !identity['dirty'],
  'build_recipe' => 'bashy self fetch --version ' + identity['revision']
)

manifest = {
  'type' => 'manifest', 'schema' => TourEvidence::SCHEMA,
  'inventory' => { 'path' => 'tests/tour/inventory.tsv', 'executable_programs' => 97, 'data_sha256' => inventory_sha },
  'baseline' => { 'accepted_results' => 'tests/tour/results.tsv', 'accepted_results_sha256' => TourEvidence.sha(File.binread(baseline_file)),
                  'pin' => 'docs/tour/baseline-pin.tsv', 'pin_sha256' => TourEvidence.sha(File.binread(File.join(root, 'docs/tour/baseline-pin.tsv'))) },
  'go' => go_info,
  'bashy' => bashy_info,
  'normalizer' => { 'path' => 'tools/tour/normalize.rb', 'version' => `#{RbConfig.ruby} #{normalizer} --version`.strip,
                    'sha256' => TourEvidence.sha(File.binread(normalizer)) },
  'attempts' => 291
}

records = [manifest]
Dir.mktmpdir('tour-evidence') do |work|
  mod = File.join(work, 'module')
  helper = File.readlines(File.join(root, 'docs/tour/helpers.tsv'), chomp: true).find { |l| !l.start_with?('#') && !l.empty? }.split("\t")
  TourEvidence.materialize_module(mod, tour_root: tour_root, inventory: inventory, go_version: tc[2], helper: helper)

  inventory.each do |item|
    local = File.join(mod, item['path'])
    compiled_dir = File.join(work, 'compiled', item['path'].gsub(%r{[^\w./]}, '_'))
    FileUtils.mkdir_p(compiled_dir)
    baseline_attempt = nil
    TourEvidence::MODES.each do |mode|
      env = { 'GOTOOLCHAIN' => 'local', 'BASHY_HINTS' => 'off' }
      if mode == 'compiled'
        pipeline = TourEvidence.compiled_pipeline(bashy: bashy, go_bin: go_bin, source: local, module_dir: mod, workdir: compiled_dir, timeout: timeout, env: env)
        command, stage, raw = pipeline['command'], pipeline['stage'], pipeline['raw']
      else
        command = TourEvidence.command_for(mode, item, bashy: bashy, go_bin: go_bin, local: local)
        stage = 'run'
        raw = TourEvidence.capture(command, chdir: mod, timeout: timeout, env: env)
      end
      abort "FATAL: agent-specific Bashy advertisement entered #{item['path']} #{mode} evidence" if TourEvidence.agent_banner?(raw)
      attempt = {
        'type' => 'attempt', 'path' => item['path'], 'applicability' => item['applicability'], 'mode' => mode,
        'source' => { 'bytes' => item['bytes'], 'sha256' => item['sha256'] }, 'command' => command, 'stage' => stage,
        'spawned' => raw['spawned'], 'state' => raw['state'], 'exit' => raw['exit'],
        'raw' => { 'stdout_base64' => Base64.strict_encode64(raw['stdout']), 'stderr_base64' => Base64.strict_encode64(raw['stderr']) },
        'normalized' => TourEvidence.derived(raw, normalizer)
      }
      attempt['outcome'] = TourEvidence.outcome(attempt, mode == 'baseline' ? nil : baseline_attempt)
      if mode == 'baseline'
        accepted = baseline_rows.fetch(item['path'])
        expected_exit = item['applicability'] == 'build_only_go_program' ? Integer(accepted[6]) : Integer(accepted[7])
        build_only = item['applicability'] == 'build_only_go_program'
        expected = { 'exit' => expected_exit,
          'stdout_bytes' => build_only ? nil : Integer(accepted[8]), 'stdout_sha256' => build_only ? nil : accepted[9],
          'stderr_bytes' => build_only ? nil : Integer(accepted[10]), 'stderr_sha256' => build_only ? nil : accepted[11] }
        attempt['accepted_observation'] = expected
        authentic = attempt['exit'] == expected_exit && (build_only ? raw['stdout'].empty? && raw['stderr'].empty? :
          attempt.dig('normalized', 'stdout', 'bytes') == expected['stdout_bytes'] && attempt.dig('normalized', 'stdout', 'sha256') == expected['stdout_sha256'] &&
          attempt.dig('normalized', 'stderr', 'bytes') == expected['stderr_bytes'] && attempt.dig('normalized', 'stderr', 'sha256') == expected['stderr_sha256'])
        attempt['accepted_observation_matches'] = authentic
        baseline_attempt = attempt
      end
      records << attempt
    end
  end
end

counts = records.drop(1).group_by { |r| r['outcome'] }.transform_values(&:length)
summary = { 'type' => 'summary', 'attempts' => 291, 'programs' => 97, 'modes' => TourEvidence::MODES, 'outcomes' => counts.sort.to_h }
records << summary
root_record = { 'type' => 'root', 'algorithm' => 'sha256-canonical-jsonl', 'sha256' => TourEvidence.root(records) }
records << root_record
verdict = { 'type' => 'verdict', 'value' => counts == { 'PASS' => 291 } ? 'PASS' : 'FAIL', 'root_sha256' => root_record['sha256'] }
records << verdict
FileUtils.mkdir_p(File.dirname(output)); File.open(output, 'wb') { |io| records.each { |r| io.puts(TourEvidence.canonical(r)) } }
puts "Tour evidence #{verdict['value']}: 97 programs x 3 modes = 291 attempts; root #{root_record['sha256']}"
