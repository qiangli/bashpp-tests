#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Two independent layers of authentication, neither of which trusts the
# producer:
#
#  1. STRUCTURAL — every field is re-derived from data the validator itself
#     reads (inventory, accepted baseline, pin files, normalizer) and must
#     match what the ledger claims. This alone cannot detect a ledger whose
#     raw bytes were simply copied between rows: a copy is internally
#     consistent, so every recomputed hash/root/verdict still balances.
#  2. REPLAY (the "process" phase) — the validator re-executes every
#     attempt's command against a freshly materialized module, using the
#     exact pinned Go 1.27 binary and the exact bashy binary named in the
#     manifest, and requires the fresh spawn/state/exit and (for the two
#     Bash++ modes) the fresh normalized output to match what the ledger
#     recorded. This is the external attestation: a forged row's stored
#     bytes did not come from executing ITS OWN bound command, so replaying
#     that command reproduces different bytes and the row is rejected — no
#     matter how consistently the rest of the ledger was recomputed around
#     it. Pinned-Go baseline rows are the one place byte drift is tolerated
#     (official Go programs are not all deterministic), but only once
#     spawn/state/exit already match the pinned toolchain's fresh run.

require_relative 'evidence'

root = File.expand_path('../..', __dir__)
file = ENV.fetch('TOUR_EVIDENCE', File.join(root, 'tests/tour/evidence.jsonl'))
normalizer = ENV.fetch('TOUR_NORMALIZER', File.join(root, 'tools/tour/normalize.rb'))
abort "FATAL: missing evidence #{file}" unless File.file?(file)
records = File.readlines(file, chomp: true).map.with_index do |line, i|
  record = JSON.parse(line)
  abort "FATAL: non-canonical JSON line #{i + 1}" unless line == TourEvidence.canonical(record)
  record
end
manifest, verdict = records.first, records.last
abort 'FATAL: malformed evidence envelope' unless manifest['type'] == 'manifest' && records[-3]['type'] == 'summary' && records[-2]['type'] == 'root' && verdict['type'] == 'verdict'
abort 'FATAL: schema mismatch' unless manifest['schema'] == TourEvidence::SCHEMA
abort 'FATAL: normalizer checksum mismatch' unless manifest.dig('normalizer', 'sha256') == TourEvidence.sha(File.binread(normalizer))

inventory_file = File.join(root, manifest.dig('inventory', 'path'))
inventory_lines = File.readlines(inventory_file, chomp: true).reject { |l| l.start_with?('#') || l.empty? }
inventory = inventory_lines.map do |line|
  f = line.split("\t"); next unless %w[applicable_go_program build_only_go_program].include?(f[3])
  [f[0], { 'path' => f[0], 'applicability' => f[3], 'bytes' => Integer(f[6]), 'sha256' => f[7] }]
end.compact.to_h
data_sha = TourEvidence.sha((inventory_lines.join("\n") + "\n"))
abort 'FATAL: manifest inventory binding mismatch' unless inventory.length == 97 && manifest.dig('inventory', 'executable_programs') == 97 && manifest.dig('inventory', 'data_sha256') == data_sha

base_file = File.join(root, manifest.dig('baseline', 'accepted_results'))
pin_file = File.join(root, manifest.dig('baseline', 'pin'))
abort 'FATAL: accepted baseline file binding mismatch' unless TourEvidence.sha(File.binread(base_file)) == manifest.dig('baseline', 'accepted_results_sha256')
abort 'FATAL: baseline pin binding mismatch' unless TourEvidence.sha(File.binread(pin_file)) == manifest.dig('baseline', 'pin_sha256')
unless system({ 'TOUR_RESULTS' => base_file }, File.join(root, 'tools/tour/validate-results.sh'), out: File::NULL)
  abort 'FATAL: accepted baseline observations fail their independent validator'
end
baseline_ledger = File.readlines(base_file, chomp: true).map { |l| next if l.start_with?('#') || l.empty?; f = l.split("\t"); [f[0], f] }.compact.to_h

# --- exact Go 1.27 builder: cross-checked against the pin file, not just
# self-consistency inside the manifest (a manifest could pair a fabricated
# identity with a matching fabricated checksum for some OTHER real binary,
# e.g. a Go 1.26 toolchain, and self-consistency alone would not catch it).
pin_row = File.readlines(File.join(root, 'docs/tour/pin.tsv'), chomp: true).find { |l| !l.start_with?('#') && !l.empty? }.split("\t")
tour_version = pin_row[1]
helper_row = File.readlines(File.join(root, 'docs/tour/helpers.tsv'), chomp: true).find { |l| !l.start_with?('#') && !l.empty? }.split("\t")
goos = `uname -s`.strip.downcase
goarch = `uname -m`.strip
tc_row = File.readlines(File.join(root, 'docs/tour/toolchain.tsv'), chomp: true)
  .reject { |l| l.start_with?('#') || l.empty? }
  .map { |l| l.split("\t") }
  .find { |f| f[0] == goos && f[1] == goarch }
abort "FATAL: no pinned Go toolchain row for #{goos}/#{goarch} in docs/tour/toolchain.tsv" unless tc_row
tc_version, tc_identity, tc_sha = tc_row[2], tc_row[3], tc_row[4]

go = manifest['go']
abort 'FATAL: exact Go binary unavailable' unless go['present'] && File.executable?(go['path'])
abort 'FATAL: exact Go binary checksum mismatch' unless TourEvidence.sha(File.binread(go['path'])) == go['sha256']
abort 'FATAL: exact Go identity mismatch' unless `#{go['path']} version`.strip == go['identity']
abort "FATAL: Go builder is not the pinned Go 1.27 toolchain (manifest identity #{go['identity']}, pinned #{tc_identity})" unless go['identity'] == tc_identity
abort "FATAL: Go builder checksum is not the pinned Go 1.27 toolchain (manifest #{go['sha256']}, pinned #{tc_sha})" unless go['sha256'] == tc_sha && go['pinned_sha256'] == tc_sha

# --- clean published reproducible bashy: the version string is re-derived
# from the LIVE binary (exactly like the Go identity above) and the published/
# clean/dirty verdict is parsed out of that live string — never taken on the
# manifest's say-so. Otherwise a ledger could pair a dev/dirty binary's true
# checksum with a fabricated published version string: every self-consistency
# check would balance while the evidence claims a release that was never built.
bashy = manifest['bashy']
abort 'FATAL: bashy binary unavailable' unless bashy['present'] && File.executable?(bashy['path'])
abort 'FATAL: exact bashy executable checksum mismatch' unless TourEvidence.sha(File.binread(bashy['path'])) == bashy['sha256']
live_bashy_version = `#{bashy['path']} --version 2>/dev/null`.lines.first.to_s.strip
abort "FATAL: exact bashy version mismatch — manifest claims #{bashy['version'].inspect}, live binary reports #{live_bashy_version.inspect}" unless live_bashy_version == bashy['version']
identity = TourEvidence.bashy_identity(live_bashy_version)
abort "FATAL: bashy build is dirty or unpublished (#{bashy['version'].inspect}) — a workspace/dirty build is not clean published reproducible evidence" unless identity['published'] && !identity['dirty']
abort 'FATAL: bashy source_revision does not match its own version string' unless bashy['source_revision'] == identity['revision']
abort 'FATAL: bashy published flag does not match its own version string' unless bashy['published'] == true
abort 'FATAL: bashy reproducible flag does not match its own version string' unless bashy['reproducible'] == true

attempts = records[1...-3]
abort "FATAL: coverage must be exactly 97 x 3 = 291" unless attempts.length == 291 && manifest['attempts'] == 291
seen = {}; baselines = {}; recomputed_counts = Hash.new(0)
attempts.each do |attempt|
  path, mode = attempt.values_at('path', 'mode'); key = [path, mode]
  abort "FATAL: unexpected or duplicate attempt #{path} #{mode}" unless inventory.key?(path) && TourEvidence::MODES.include?(mode) && !seen[key]
  seen[key] = true; item = inventory.fetch(path)
  expected_source = { 'bytes' => item['bytes'], 'sha256' => item['sha256'] }
  abort "FATAL: inventory/source mismatch #{path} #{mode}" unless attempt['applicability'] == item['applicability'] && attempt['source'] == expected_source
  abort "FATAL: unknown pipeline stage #{path} #{mode}" unless TourEvidence::STAGES.include?(attempt['stage'])
  command = attempt['command']
  if mode != 'baseline' && baselines[path] && command == baselines[path]['command']
    abort "FATAL: synthetic mutual-equality artifact #{path} #{mode}"
  end
  case mode
  when 'baseline'
    abort "FATAL: unbound command #{path} #{mode}" unless command.is_a?(Array) && !command.empty?
    abort "FATAL: baseline did not use exact Go #{path}" unless File.expand_path(command[0]) == File.expand_path(go['path'])
    abort "FATAL: baseline stage must be run #{path}" unless attempt['stage'] == 'run'
  when 'interpreted'
    abort "FATAL: unbound command #{path} #{mode}" unless command.is_a?(Array) && !command.empty?
    abort "FATAL: interpreted command binding #{path}" unless command[0] == bashy['path'] && command.include?('--bashpp')
    abort "FATAL: interpreted stage must be run #{path}" unless attempt['stage'] == 'run'
  when 'compiled'
    abort "FATAL: unbound compiled pipeline #{path}" unless command.is_a?(Hash) && command.keys.sort == %w[build run transpile]
    abort "FATAL: compiled transpile binding #{path}" unless command['transpile'][0] == bashy['path'] && command['transpile'].include?('transpile')
    abort "FATAL: compiled build binding #{path}" unless command['build'][0] == go['path'] && command['build'].include?('build')
    abort "FATAL: compiled run binding #{path}" unless command['run'].is_a?(Array) && command['run'].length == 1
  end
  raw = { 'stdout' => Base64.strict_decode64(attempt.dig('raw', 'stdout_base64')), 'stderr' => Base64.strict_decode64(attempt.dig('raw', 'stderr_base64')) }
  abort "FATAL: agent-specific Bashy advertisement in evidence #{path} #{mode}" if TourEvidence.agent_banner?(raw)
  derived = TourEvidence.derived(raw, normalizer)
  abort "FATAL: normalized fields not derived from raw streams #{path} #{mode}" unless attempt['normalized'] == derived
  if mode == 'baseline'
    row = baseline_ledger.fetch(path); build_only = item['applicability'] == 'build_only_go_program'
    expected = { 'exit' => build_only ? Integer(row[6]) : Integer(row[7]),
      'stdout_bytes' => build_only ? nil : Integer(row[8]), 'stdout_sha256' => build_only ? nil : row[9],
      'stderr_bytes' => build_only ? nil : Integer(row[10]), 'stderr_sha256' => build_only ? nil : row[11] }
    abort "FATAL: baseline accepted observation copied or altered #{path}" unless attempt['accepted_observation'] == expected
    authentic = attempt['exit'] == expected['exit'] && (build_only ? raw['stdout'].empty? && raw['stderr'].empty? :
      derived['stdout']['bytes'] == expected['stdout_bytes'] && derived['stdout']['sha256'] == expected['stdout_sha256'] &&
      derived['stderr']['bytes'] == expected['stderr_bytes'] && derived['stderr']['sha256'] == expected['stderr_sha256'])
    abort "FATAL: accepted baseline match flag is not derived #{path}" unless attempt['accepted_observation_matches'] == authentic
    # Volatile official examples need not reproduce a prior stream byte for
    # byte. Authenticity comes from the validated accepted ledger, exact Go
    # binary, pinned source, bound command, captured process facts, AND (see
    # the replay phase below) an independent live re-execution; this flag
    # only records whether the fresh observation also equals the PRIOR one.
    calculated = TourEvidence.outcome(attempt)
    baselines[path] = attempt
  else
    abort "FATAL: mode precedes its baseline #{path}" unless baselines[path]
    calculated = TourEvidence.outcome(attempt, baselines[path])
    # Equality is accepted only when it came through a distinct, correctly
    # bound execution record. This rejects fabricated baseline clones.
  end
  abort "FATAL: derived outcome mismatch #{path} #{mode}" unless attempt['outcome'] == calculated
  recomputed_counts[calculated] += 1
end
inventory.each_key { |path| TourEvidence::MODES.each { |mode| abort "FATAL: missing attempt #{path} #{mode}" unless seen[[path, mode]] } }
summary = records[-3]
expected_summary = { 'type' => 'summary', 'attempts' => 291, 'programs' => 97, 'modes' => TourEvidence::MODES, 'outcomes' => recomputed_counts.sort.to_h }
abort 'FATAL: summary mismatch' unless summary == expected_summary
calculated_root = TourEvidence.root(records[0...-2])
abort 'FATAL: evidence root mismatch' unless records[-2] == { 'type' => 'root', 'algorithm' => 'sha256-canonical-jsonl', 'sha256' => calculated_root }
expected_verdict = recomputed_counts == { 'PASS' => 291 } ? 'PASS' : 'FAIL'
abort 'FATAL: verdict mismatch' unless verdict == { 'type' => 'verdict', 'value' => expected_verdict, 'root_sha256' => calculated_root }

# ---------------------------------------------------------------------------
# PROCESS PHASE — replay authentication.
#
# Everything above is self-consistency: it proves the ledger agrees with
# itself and with the files it cites. None of it proves the raw bytes in any
# given row actually came from executing THAT row's own bound command — a
# row whose raw/normalized/spawn/state/exit fields were copied from a
# DIFFERENT row (e.g. its sibling baseline attempt) while keeping its own
# correct command is internally perfect and would sail through every check
# above. Replay closes that gap by re-executing every attempt for real,
# right now, against a freshly materialized module, and requiring the fresh
# observation to match the recorded one.
# ---------------------------------------------------------------------------
timeout = Integer(ENV.fetch('TOUR_STEP_TIMEOUT', '30'))
tour_root = ENV.fetch('TOUR_ROOT', File.join(`go env GOMODCACHE`.strip, "golang.org/x/website@#{tour_version}"))
Dir.mktmpdir('tour-evidence-replay') do |work|
  mod = File.join(work, 'module')
  begin
    TourEvidence.materialize_module(mod, tour_root: tour_root, inventory: inventory.values, go_version: tc_version, helper: helper_row)
  rescue StandardError => e
    abort "FATAL: cannot materialize replay module: #{e.message}"
  end

  attempts.each do |attempt|
    path, mode = attempt.values_at('path', 'mode')
    item = inventory.fetch(path)
    local = File.join(mod, path)
    env = { 'GOTOOLCHAIN' => 'local', 'BASHY_HINTS' => 'off' }
    fresh =
      if mode == 'compiled'
        compiled_dir = File.join(work, 'compiled', path.gsub(%r{[^\w./]}, '_'))
        FileUtils.mkdir_p(compiled_dir)
        pipeline = TourEvidence.compiled_pipeline(bashy: bashy['path'], go_bin: go['path'], source: local, module_dir: mod, workdir: compiled_dir, timeout: timeout, env: env)
        abort "FATAL: replay pipeline stage mismatch #{path} #{mode} (recorded #{attempt['stage']}, replay #{pipeline['stage']})" unless pipeline['stage'] == attempt['stage']
        pipeline['raw']
      else
        command = TourEvidence.command_for(mode, item, bashy: bashy['path'], go_bin: go['path'], local: local)
        TourEvidence.capture(command, chdir: mod, timeout: timeout, env: env)
      end

    fresh_normalized = TourEvidence.derived(fresh, normalizer)
    control_match = fresh['spawned'] == attempt['spawned'] && fresh['state'] == attempt['state'] && fresh['exit'] == attempt['exit']
    abort "FATAL: replay spawn/state/exit not reproduced #{path} #{mode} (recorded exit=#{attempt['exit']} state=#{attempt['state']}, replay exit=#{fresh['exit']} state=#{fresh['state']})" unless control_match

    bytes_match = %w[stdout stderr].all? { |stream| fresh_normalized[stream]['sha256'] == attempt.dig('normalized', stream, 'sha256') }
    next if bytes_match
    # Pinned-Go baseline rows are the one place byte drift is tolerated: not
    # every official Go program is deterministic, and this project's own
    # accepted-baseline design already accounts for that (see
    # accepted_observation_matches). The two Bash++ modes are held to exact
    # replay equality: their whole purpose is to be the authoritative record
    # of what bashy did, and a mismatch there means the recorded bytes did
    # not come from this row's own bound command.
    next if mode == 'baseline'
    abort "FATAL: replay raw-output mismatch #{path} #{mode} — recorded observation was not reproduced by executing its own bound command"
  end
end

puts "Tour evidence VALID #{expected_verdict}: 97 programs x 3 modes = 291; root #{calculated_root}; replay-authenticated"
