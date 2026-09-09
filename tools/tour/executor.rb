#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Deterministic three-mode executor for the pinned go.dev/tour denominator.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# This library is shared by four consumers so none of them can drift:
#
#   tools/tour/executor-runner.rb    produces tests/tour/executor-results.jsonl
#   tools/tour/executor-gate.rb      re-derives and audits that ledger offline
#   tools/tour/executor-selftests.rb drives the pure functions and the real
#                                    gate with synthetic and forged ledgers
#   tools/tour/executor-tamper-tests.sh mutates the REAL ledger and requires
#                                    the real gate to reject each mutation
#
# It supersedes the tour-evidence/v2 runner (tools/tour/evidence.rb +
# evidence-runner.rb). That runner and its ledger, tests/tour/evidence.jsonl,
# are HISTORICAL FAILURE EVIDENCE for story #4 and are deliberately left
# untouched. The new ledger is a separate artifact.
#
# PROCESS MACHINERY IS NOT OURS. Every subprocess in this corpus goes through
# `Corpus.capture` in tools/corpus/executor.rb (W2, Story-ID e29305614139):
# argv with no shell, an explicit environment with `unsetenv_others`, file-backed
# raw streams, a monotonic deadline, its own process group, a swept group and a
# surviving-descendant check. This file does NOT reimplement any of that; it
# converts the file-backed stream records that primitive returns into the
# normalized, digest-bound data the tour ledger needs. If the shared library is
# missing, this corpus fails closed rather than falling back to a private copy:
# a ledger produced by an unreviewed capture path is not evidence.
#
# WHAT THIS CORPUS OWNS ON TOP OF THAT: the command table
# (docs/tour/executor-contract.tsv), the tour inventory join, the pinned
# normalizer audit, the phase-migration contract, the semantic comparators for
# the declared-volatile rows (tools/tour/semantics.rb) and the scoring rules
# below. The shared library explicitly declines to decide those.

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

require_relative 'semantics'

SHARED_CAPTURE = File.expand_path('../corpus/executor.rb', __dir__)
unless File.file?(SHARED_CAPTURE)
  abort "FATAL: the shared capture library #{SHARED_CAPTURE} is missing; " \
        'this corpus does not run subprocesses through a private copy.'
end
require_relative '../corpus/executor'
unless defined?(Corpus) && Corpus.respond_to?(:capture) && Corpus.respond_to?(:authenticate_candidate)
  abort 'FATAL: tools/corpus/executor.rb does not expose the required Corpus.capture / ' \
        'Corpus.authenticate_candidate module functions.'
end

module TourExecutor
  SCHEMA = 'tour-executor/v2'
  MODES = %w[baseline interpreted compiled].freeze
  EXECUTABLE_APPLICABILITIES = %w[applicable_go_program build_only_go_program].freeze
  DENOMINATOR = 97
  APPLICABLE_ROWS = 93
  BUILD_ONLY_ROWS = 4
  OBSERVATIONS = DENOMINATOR * MODES.length # 291

  # The shared capture primitive's own provenance, bound into every ledger so
  # an audit can tell which reviewed implementation produced the streams.
  CAPTURE_IMPLEMENTATION = 'tools/corpus/executor.rb:Corpus.capture'

  # A ledger may only ever carry these statuses. Placeholder vocabulary that a
  # partially-written or forged ledger might use is listed so the gate can
  # reject it by name instead of silently treating it as "not a failure".
  FORBIDDEN_STATUSES = %w[PLANNED TODO SKIP SKIPPED N/A NA NOT_APPLICABLE NOTAPPLICABLE PENDING UNKNOWN].freeze

  # The ONLY approved not-applicable reason in the tour inventory
  # (docs/tour/standing-exceptions.tsv). It applies exclusively to
  # excluded_fragment rows, which are outside the executable denominator
  # entirely — no executable row may cite it.
  APPROVED_EXCEPTIONS = %w[none fragment].freeze

  # The honest scope of the input-absence control, recorded on every stage that
  # executes a tested body. It is a cwd and command-lookup restriction, not an
  # OS-level denial: Ruby does not stop a program from opening an absolute path.
  # Claiming more than this would be the gaming vector the story warns about.
  INPUT_ABSENCE_SCOPE = 'compilation cwd emptied before native execution; body PATH empty; ' \
                        'interpreted mode necessarily retains its own source/module context; no OS sandbox'

  module_function

  # ---------------------------------------------------------------- utilities

  def canonical(object)
    JSON.generate(deep_sort(object))
  end

  def deep_sort(object)
    case object
    when Hash then object.keys.sort.to_h { |key| [key, deep_sort(object[key])] }
    when Array then object.map { |value| deep_sort(value) }
    else object
    end
  end

  def sha(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def tsv_rows(path)
    File.readlines(path, chomp: true).reject { |line| line.start_with?('#') || line.empty? }.map { |line| line.split("\t", -1) }
  end

  def slug(path)
    path.gsub(%r{[^\w.-]}, '_')
  end

  # ---------------------------------------------------------------- contract

  # docs/tour/executor-contract.tsv -> { [applicability, mode] => recipe }.
  # A recipe is { 'phase' => token, 'stages' => [ordered stage specs] }.
  def load_contract(path)
    recipes = {}
    tsv_rows(path).each do |applicability, mode, phase, stage_index, stage, argv, produces, execute_body|
      raise "contract: unknown applicability #{applicability}" unless EXECUTABLE_APPLICABILITIES.include?(applicability)
      raise "contract: unknown mode #{mode}" unless MODES.include?(mode)
      raise "contract: execute_body must be yes/no, got #{execute_body}" unless %w[yes no].include?(execute_body)
      recipe = (recipes[[applicability, mode]] ||= { 'phase' => phase, 'stages' => [] })
      raise "contract: phase disagrees within #{applicability}/#{mode}" unless recipe['phase'] == phase
      raise "contract: stage_index out of order in #{applicability}/#{mode}" unless Integer(stage_index) == recipe['stages'].length
      recipe['stages'] << {
        'index' => Integer(stage_index), 'stage' => stage,
        'argv_template' => argv.split('|'),
        'produces' => produces == '-' ? [] : produces.split(','),
        'execute_body' => execute_body == 'yes'
      }
    end
    missing = EXECUTABLE_APPLICABILITIES.product(MODES).reject { |key| recipes.key?(key) }
    raise "contract: missing recipes for #{missing.inspect}" unless missing.empty?
    recipes.freeze
  end

  # docs/tour/phase-migration.tsv -> { [applicability, mode] => row }.
  #
  # The pinned inventory (tests/tour/inventory.tsv, frozen by docs/tour/pin.tsv)
  # spells build-only compiled mode `bpp_compiled:transpile-build-run`. The `run`
  # token contradicts the master plan's no-body-execution rule for a `norun` row.
  # The current master plan outranks the stale pinned string: the executor
  # implements no body execution, the historical inventory schema stays
  # byte-for-byte as pinned, and THIS TABLE is the checked bridge between them —
  # every (applicability, mode) states its historical token, its current phase
  # and whether a body is executed, and the gate enforces both ends.
  def load_phase_migration(path)
    rows = {}
    tsv_rows(path).each do |applicability, mode, field, historical, current, executes_body, rationale|
      raise "phase-migration: unknown applicability #{applicability}" unless EXECUTABLE_APPLICABILITIES.include?(applicability)
      raise "phase-migration: unknown mode #{mode}" unless MODES.include?(mode)
      raise "phase-migration: executes_body must be yes/no" unless %w[yes no].include?(executes_body)
      rows[[applicability, mode]] = { 'applicability' => applicability, 'mode' => mode, 'schema_field' => field,
                                      'historical_token' => historical, 'current_phase' => current,
                                      'executes_body' => executes_body == 'yes', 'rationale' => rationale }
    end
    missing = EXECUTABLE_APPLICABILITIES.product(MODES).reject { |key| rows.key?(key) }
    raise "phase-migration: missing rows for #{missing.inspect}" unless missing.empty?
    rows.freeze
  end

  # Checks the migration table against BOTH ends it bridges: the pinned
  # historical schema string on each inventory row, and the current contract.
  # A silent rewrite of either side is a finding, not a convenience.
  def phase_migration_failures(migration, contract, items)
    findings = []
    migration.each do |(applicability, mode), row|
      recipe = contract[[applicability, mode]]
      if recipe.nil?
        findings << "phase_migration:no_contract:#{applicability}/#{mode}"
        next
      end
      findings << "phase_migration:current_phase:#{applicability}/#{mode}" unless recipe['phase'] == row['current_phase']
      executes = recipe['stages'].any? { |stage| stage['execute_body'] }
      findings << "phase_migration:body_policy:#{applicability}/#{mode}" unless executes == row['executes_body']
    end
    items.each do |item|
      declared = item['differential_schema'].to_s.split(';').to_h { |pair| pair.split(':', 2) }
      MODES.each do |mode|
        row = migration[[item['applicability'], mode]]
        next unless row
        got = declared[row['schema_field']]
        findings << "phase_migration:historical_drift:#{item['path']}/#{mode}" unless got == row['historical_token']
      end
    end
    findings.uniq
  end

  # Substitutes the contract placeholders. Unknown placeholders are a hard
  # error: a silently unsubstituted `{BIN}` would otherwise become a literal
  # argument and quietly change what ran.
  def render_argv(template, subs)
    template.map do |token|
      token.gsub(/\{(\w+)\}/) do
        key = Regexp.last_match(1)
        raise "contract: no substitution for {#{key}}" unless subs.key?(key)
        subs.fetch(key)
      end
    end
  end

  # The concrete substitution map for one (row, mode). `artifact_dir` is the
  # per-(row, mode) artifact directory; `module_dir` is the per-mode
  # materialized module and is the cwd of every non-body stage.
  def substitutions(item, bashy:, go_bin:, artifact_dir:)
    base = File.basename(item['path'], '.go')
    {
      'GO' => go_bin, 'BASHY' => bashy, 'SRC' => item['path'],
      'OUT_GO' => File.join(artifact_dir, "#{base}.transpiled.go"),
      'OUT_MAP' => File.join(artifact_dir, "#{base}.transpiled.go.map"),
      'BIN' => File.join(artifact_dir, "#{base}.bin")
    }
  end

  # ---------------------------------------------------------------- inventory

  def load_inventory(path)
    rows = tsv_rows(path)
    items = rows.select { |f| EXECUTABLE_APPLICABILITIES.include?(f[3]) }.map do |f|
      { 'path' => f[0], 'kind' => f[1], 'applicability' => f[3], 'exception' => f[4].sub(/\Aexception:/, ''),
        'differential_schema' => f[5], 'bytes' => Integer(f[6]), 'sha256' => f[7] }
    end
    items.each do |item|
      raise "inventory: executable row #{item['path']} cites exception #{item['exception']}" unless item['exception'] == 'none'
    end
    { 'items' => items, 'data_sha256' => sha(rows.map { |f| f.join("\t") }.join("\n") + "\n"), 'rows' => rows.length }
  end

  def load_accepted(path)
    tsv_rows(path).to_h do |f|
      [f[0], { 'applicability' => f[1], 'bytes' => Integer(f[2]), 'sha256' => f[3], 'baseline' => f[5],
               'build_exit' => Integer(f[6]),
               'run_exit' => f[7] == '-' ? nil : Integer(f[7]),
               'stdout_bytes' => f[8] == '-' ? nil : Integer(f[8]), 'stdout_sha256' => f[9] == '-' ? nil : f[9],
               'stderr_bytes' => f[10] == '-' ? nil : Integer(f[10]), 'stderr_sha256' => f[11] == '-' ? nil : f[11],
               'outcome' => f[13] }]
    end
  end

  # ---------------------------------------------------------------- normalize

  # Runs the PINNED normalizer (tools/tour/normalize.rb) as a subprocess. Its
  # SHA-256 is bound into the manifest, so changing the rules requires
  # re-pinning.
  def normalize(bytes, normalizer)
    out, err, status = Open3.capture3(RbConfig.ruby, normalizer, stdin_data: bytes, binmode: true)
    raise "normalizer wrote stderr: #{err}" unless err.empty?
    return { 'valid_utf8' => false, 'bytes' => nil, 'sha256' => nil } unless status.success?
    { 'valid_utf8' => true, 'bytes' => out.bytesize, 'sha256' => sha(out) }
  end

  # INDEPENDENT reimplementation of the declared tour-normalizer/v1 rules, used
  # by the gate to audit the recorded normalization. Aggressive normalization
  # is itself a gaming vector — normalize everything to nothing and every mode
  # looks equal — so the gate recomputes the declared rules here and rejects
  # any normalizer output that differs. A normalizer that masked timestamps,
  # numbers, paths or whole lines would not match this function.
  #
  # v1: (1) strict UTF-8 gate, (2) CRLF/CR -> LF, (3) >=8-hex-digit pointer
  # values -> 0xADDR. Nothing else.
  def audit_normalize(raw)
    text = raw.dup.force_encoding('UTF-8')
    return nil unless text.valid_encoding?
    text.gsub(/\r\n?/, "\n").gsub(/\b0x[0-9a-fA-F]{8,}\b/, '0xADDR')
  end

  # A blanket-masking detector independent of the byte comparison above: how
  # much of a stream normalization removed. A normalizer may only delete CR
  # bytes and shrink pointer literals, so a stream that loses more than a small
  # fraction of its bytes (or is emptied outright) is reported for audit.
  def masking_report(raw, normalized_bytes)
    return { 'raw_bytes' => 0, 'normalized_bytes' => normalized_bytes.to_i, 'emptied' => false } if raw.empty?
    { 'raw_bytes' => raw.bytesize, 'normalized_bytes' => normalized_bytes.to_i,
      'emptied' => normalized_bytes.to_i.zero? }
  end

  # ---------------------------------------------------------------- processes

  # The ONLY process entry point in this corpus. It delegates spawning,
  # deadline enforcement, process-group sweeping and descendant detection to
  # `Corpus.capture` (tools/corpus/executor.rb) and converts that primitive's
  # FILE-BACKED stream records into the in-memory raw bytes the tour normalizer
  # and ledger need — re-checking each log against the digest the shared library
  # recorded, so a log rewritten between capture and read is caught.
  #
  # `log_prefix` is a durable path: the raw `.stdout`/`.stderr` files stay on
  # disk for review next to the ledger's base64 copy of the same bytes.
  def run(argv, chdir:, timeout:, env:, log_prefix:)
    started_at = Time.now.to_f
    raw = Corpus.capture(argv, cwd: chdir, log_prefix: log_prefix, env: env, timeout: timeout)
    finished_at = Time.now.to_f
    streams = %w[stdout stderr].to_h do |stream|
      record = raw.fetch(stream)
      bytes = File.binread(record.fetch('path'))
      raise "capture log tampered: #{record['path']}" unless sha(bytes) == record.fetch('sha256')
      [stream, bytes]
    end
    # A signalled process has no exitstatus; 128+signal is the shell convention
    # the accepted baseline (tools/tour/run-baseline.sh) already used.
    status = raw['exit'] || (raw['signal'] ? 128 + raw['signal'] : nil)
    {
      'spawned' => raw['spawned'], 'state' => raw['state'], 'exit' => status, 'signal' => raw['signal'],
      'descendants_survived' => raw['descendants_survived'] ? true : false,
      'duration_ms' => (raw.fetch('duration_seconds') * 1000).round,
      'started_at' => started_at, 'finished_at' => finished_at,
      'stdout' => streams.fetch('stdout'), 'stderr' => streams.fetch('stderr'),
      'logs' => { 'stdout' => raw.fetch('stdout'), 'stderr' => raw.fetch('stderr') }
    }
  end

  # ---------------------------------------------------------------- artifacts

  def artifact_record(path)
    return { 'present' => false, 'bytes' => nil, 'sha256' => nil } unless File.file?(path)
    bytes = File.binread(path)
    { 'present' => true, 'bytes' => bytes.bytesize, 'sha256' => sha(bytes) }
  end

  # `--map` writes the transpiler source map. Recording its schema version, its
  # ORIGIN (the original upstream path the transpiler says it consumed), the
  # per-mapping source files, the mapping count and the GENERATION DIGEST it
  # claims for the emitted Go is how "preserve source maps" becomes checkable
  # evidence rather than a claim.
  def source_map_summary(path)
    return nil unless File.file?(path)
    data = JSON.parse(File.binread(path))
    mappings = data['mappings'].is_a?(Array) ? data['mappings'] : []
    { 'schema_version' => data['schema_version'], 'origin' => data['origin'],
      'go_digest' => data['go_digest'], 'mappings' => mappings.length,
      'source_files' => mappings.map { |m| m.is_a?(Hash) ? m['source_file'] : nil }.compact.uniq.sort,
      'positioned' => mappings.all? do |m|
        m.is_a?(Hash) && %w[go_line go_col source_line source_col].all? { |k| m[k].is_a?(Integer) && m[k].positive? }
      end }
  rescue JSON::ParserError, TypeError
    { 'schema_version' => nil, 'origin' => nil, 'go_digest' => nil, 'mappings' => nil,
      'source_files' => [], 'positioned' => false }
  end

  # The source map must describe THIS transpile: the declared schema, a
  # non-empty positioned mapping set, the original upstream path as its origin
  # and per-mapping source file, and a generation digest equal to the SHA-256 of
  # the generated Go the same stage produced. A map that points at another file
  # or another artifact is not preservation.
  def source_map_failures(stage, source_path)
    map = (stage['artifacts'] || {})['map'] || {}
    return ['source_map_missing'] unless map['present']
    summary = map['source_map'] || {}
    findings = []
    findings << "source_map_schema:#{summary['schema_version']}" unless summary['schema_version'] == 'bashy-transpile-map-v1'
    findings << 'source_map_empty' unless summary['mappings'].to_i.positive?
    findings << 'source_map_unpositioned' unless summary['positioned']
    findings << "source_map_origin:#{summary['origin']}" unless summary['origin'] == source_path
    unless summary['source_files'].to_a.empty? || summary['source_files'].to_a == [source_path]
      findings << "source_map_source_files:#{summary['source_files'].inspect}"
    end
    generated = (stage['artifacts'] || {})['go'] || {}
    if generated['present']
      expected = "sha256:#{generated['sha256']}"
      findings << 'source_map_generation_digest' unless summary['go_digest'] == expected
    end
    findings
  end

  # Input artifacts are captured before execution and must match the preceding
  # producer, in addition to the gate's exact row/mode-specific argv check.
  def consumed_artifacts(spec)
    { 'go' => '{OUT_GO}', 'bin' => '{BIN}' }.select do |name, token|
      spec['argv_template'].include?(token) && !spec['produces'].include?(name)
    end.keys
  end

  # ---------------------------------------------------------------- statuses

  # Whether one recorded stage met its own obligation. Returns nil on success
  # or the failure token that makes it authoritative.
  #
  # A stage that does NOT execute the tested body has two extra obligations:
  # it must produce every declared artifact, and — when it succeeds — it must
  # emit nothing on stdout. A `norun` row whose "check" or "build" stage
  # printed program output did execute a body, and that is a contract
  # violation, not a pass.
  def stage_failure(stage)
    return 'launch_failure' unless stage['spawned']
    return 'deadline' if stage['state'] == 'deadline'
    # `process_leak` comes from the shared capture primitive: the parent exited
    # but a descendant outlived its process group. Several tour concurrency rows
    # can do exactly this, and it is a failure, not a clean exit.
    return "state:#{stage['state']}" unless stage['state'] == 'exited'
    return 'descendants_survived' if stage['descendants_survived']
    return "exit:#{stage['exit']}" unless stage['exit'] == 0
    missing = (stage['artifacts'] || {}).reject { |_, a| a['present'] }.keys.sort
    return "missing_artifact:#{missing.join(',')}" unless missing.empty?
    unless stage['execute_body']
      return 'body_executed' unless stage.dig('normalized', 'stdout', 'bytes').to_i.zero?
    end
    return 'invalid_utf8' unless stage.dig('normalized', 'stdout', 'valid_utf8') && stage.dig('normalized', 'stderr', 'valid_utf8')
    nil
  end

  # Index of the stage that owns the observation's verdict: the FIRST stage
  # that failed, otherwise the last stage. This is what stops a successful
  # transpile from masquerading as a successful artifact run.
  def authoritative_index(stages)
    idx = stages.index { |stage| !stage_failure(stage).nil? }
    idx || stages.length - 1
  end

  # Recomputes an observation's status purely from its own recorded stages, the
  # contract recipe, the accepted baseline row, the reviewed semantic verdict
  # (for a declared-volatile row) and, for the two product modes, the fresh
  # baseline observation of the same source. The gate calls this on ledger data
  # it did not produce, so a hand-edited status cannot survive.
  def observation_status(observation, recipe:, accepted:, baseline_observation: nil, semantic_row: nil)
    stages = observation['stages'] || []
    expected = recipe['stages']
    return 'FAIL:stage_contract' unless stages.length == expected.length
    expected.each_with_index do |spec, i|
      got = stages[i]
      return 'FAIL:stage_contract' unless got['stage'] == spec['stage'] && got['index'] == spec['index'] &&
                                         got['execute_body'] == spec['execute_body'] &&
                                         (got['artifacts'] || {}).keys.sort == spec['produces'].sort
    end
    idx = authoritative_index(stages)
    failure = stage_failure(stages[idx])
    return "FAIL:#{stages[idx]['stage']}:#{failure}" if failure

    final = stages[idx]

    if observation['mode'] == 'baseline'
      # For a declared-volatile row the pinned accepted STREAMS are historical:
      # they record one draw of a nondeterministic program on one day. Exit
      # statuses and the stage shape are still compared exactly, and the streams
      # are adjudicated by the reviewed comparator against the fresh native
      # oracle instead.
      return 'FAIL:accepted_mismatch' unless baseline_matches_accepted?(observation, accepted, compare_streams: semantic_row.nil?)
      return semantic_verdict(observation, semantic_row) if semantic_row
      return 'PASS'
    end

    # A non-body phase (build-only check / build-only transpile+build) has no
    # output to compare: succeeding at the declared phase IS the obligation.
    return 'PASS' unless final['execute_body']

    return semantic_verdict(observation, semantic_row) if semantic_row

    return 'FAIL:no_baseline' if baseline_observation.nil?
    base = baseline_observation['stages'][authoritative_index(baseline_observation['stages'])]
    return 'FAIL:mismatch' unless final['exit'] == base['exit']
    %w[stdout stderr].each do |stream|
      return 'FAIL:mismatch' unless final.dig('normalized', stream, 'sha256') == base.dig('normalized', stream, 'sha256')
    end
    'PASS'
  end

  # The wall-clock interval a semantic comparison is adjudicated against: the
  # stages of THAT observation together with the native oracle repeats it is
  # compared to. Producer and gate both call this, so the window is a derived
  # fact rather than a runner assertion — a widened window is detectable.
  def semantic_window(stages, oracle_runs, utc_offset)
    stamps = (stages.flat_map { |s| [s['started_at'], s['finished_at']] } +
              oracle_runs.flat_map { |r| [r['started_at'], r['finished_at']] }).compact
    return nil if stamps.empty?
    { 'from' => stamps.min, 'to' => stamps.max, 'utc_offset' => utc_offset }
  end

  # Consumes the recorded semantic verdict. The verdict's INTEGRITY is the
  # gate's job (it recomputes TourSemantics.compare from the stored raw bytes
  # and the stored oracle); here we only refuse to accept one that is absent,
  # is for another comparator or another version, or that failed.
  def semantic_verdict(observation, semantic_row)
    verdict = observation['semantic']
    return 'FAIL:semantic_missing' unless verdict.is_a?(Hash)
    return "FAIL:semantic_comparator:#{verdict['comparator']}" unless verdict['comparator'] == semantic_row['comparator']
    return "FAIL:semantic_version:#{verdict['version']}" unless verdict['version'] == TourSemantics::VERSION
    return "FAIL:semantic:#{verdict['findings'].to_a.first}" unless verdict['ok']
    'PASS'
  end

  # The fresh Go baseline must reproduce the pinned accepted observation in
  # tests/tour/results.tsv, otherwise the accepted baseline no longer describes
  # this host/toolchain and nothing downstream can be compared to it. For a
  # declared-volatile row `compare_streams:` is false: the exit statuses and the
  # stage shape are still enforced, the streams move to the comparator.
  def baseline_matches_accepted?(observation, accepted, compare_streams: true)
    return false if accepted.nil?
    stages = observation['stages']
    build = stages.find { |s| s['stage'] == 'build' }
    return false unless build && build['exit'] == accepted['build_exit']
    if observation['applicability'] == 'build_only_go_program'
      # norun row: build only, and nothing may have been executed.
      return stages.length == 1 && accepted['run_exit'].nil?
    end
    run = stages.find { |s| s['stage'] == 'run' }
    return false unless run && run['exit'] == accepted['run_exit']
    return true unless compare_streams
    run.dig('normalized', 'stdout', 'bytes') == accepted['stdout_bytes'] &&
      run.dig('normalized', 'stdout', 'sha256') == accepted['stdout_sha256'] &&
      run.dig('normalized', 'stderr', 'bytes') == accepted['stderr_bytes'] &&
      run.dig('normalized', 'stderr', 'sha256') == accepted['stderr_sha256']
  end

  # ---------------------------------------------------------------- candidate
  #
  # A candidate is authenticated against the EXACT MANIFEST the manager
  # supplied, not against commits this harness derives for itself. The previous
  # rule parsed `bashy --version`, resolved each sibling worktree by convention
  # and reported a "binary commit is not HEAD" diagnosis — none of which ties
  # the binary in front of us to the sources that produced it. The manifest
  # does: it names the launcher and payload digests and every repository
  # revision compiled into that payload, and `Corpus.authenticate_candidate`
  # (the shared library) verifies all of them, including that each repository
  # is at the stated revision with no untracked files.

  # docs/tour/candidate.tsv: component / role / go_module_path / replace_directive
  # / frozen_commit. `frozen_commit` is empty until the manager freezes the
  # integrated revision set; once filled, the gate enforces equality.
  def load_candidate_contract(path)
    tsv_rows(path).map do |component, role, module_path, replace_directive, frozen_commit|
      { 'component' => component, 'role' => role, 'go_module_path' => module_path,
        'replace_directive' => replace_directive,
        'frozen_commit' => frozen_commit.to_s.empty? ? nil : frozen_commit }
    end
  end

  def load_candidate_manifest(path)
    JSON.parse(File.binread(path))
  end

  # Authenticates the supplied manifest with the shared library and renders the
  # ledger's candidate record. Raises when authentication fails: an
  # unauthenticated product must not reach the execution loop at all.
  def authenticate_candidate(bashy_path:, manifest_path:, contract:)
    manifest = load_candidate_manifest(manifest_path)
    authenticated = Corpus.authenticate_candidate(bashy_path, manifest)
    version, = Open3.capture2e(bashy_path, '--version')
    repositories = authenticated.fetch('repositories').map do |repo|
      { 'path' => repo.fetch('path'), 'commit' => repo.fetch('commit'), 'name' => File.basename(repo.fetch('path')) }
    end
    components = contract.map do |component|
      repo = repositories.find { |r| r['name'] == component['component'] }
      component.merge('bound' => !repo.nil?, 'dir' => repo && repo['path'], 'commit' => repo && repo['commit'])
    end
    {
      'binding' => 'manifest:launcher+payload+repository-commits',
      'authenticated_by' => 'Corpus.authenticate_candidate (tools/corpus/executor.rb)',
      'manifest_path' => manifest_path,
      'manifest_sha256' => sha(File.binread(manifest_path)),
      'frontend_version' => manifest['frontend_version'],
      'build_recipe' => manifest['build_recipe'],
      'manifest_status' => manifest['status'],
      'version_line' => version.lines.first.to_s.strip,
      'binaries' => {
        'launcher' => { 'path' => authenticated.dig('launcher', 'path'), 'present' => true,
                        'bytes' => authenticated.dig('launcher', 'bytes'), 'sha256' => authenticated.dig('launcher', 'sha256') },
        'payload' => { 'path' => authenticated.dig('payload', 'path'), 'present' => true, 'expected' => true,
                       'bytes' => authenticated.dig('payload', 'bytes'), 'sha256' => authenticated.dig('payload', 'sha256') }
      },
      'repositories' => repositories,
      'components' => components,
      'contract_sha256' => nil # filled by the runner from the on-disk contract
    }
  end

  # The gate's candidate predicate: an empty list means the candidate is
  # authenticated. Deliberately NOT a release-tag check, and deliberately not a
  # derived-commit check either. Every declared component must be bound to a
  # manifest repository, every manifest repository must be a declared component
  # (an unbound replaced dependency compiled into the payload is exactly what
  # this catches), both halves of the Makefile output must carry a digest, and a
  # frozen commit, once the manager sets one, must match.
  def candidate_failures(candidate)
    reasons = []
    reasons << 'candidate:unauthenticated_manifest' unless candidate['binding'] == 'manifest:launcher+payload+repository-commits'
    reasons << 'candidate:no_manifest_digest' unless candidate['manifest_sha256'].to_s.length == 64
    %w[launcher payload].each do |which|
      binary = candidate.dig('binaries', which) || {}
      reasons << "candidate:missing_#{which}" unless binary['present']
      reasons << "candidate:unbound_#{which}_digest" unless binary['sha256'].to_s.length == 64
    end
    components = candidate['components'] || []
    reasons << 'candidate:no_product_component' if components.none? { |c| c['role'] == 'product' }
    components.each do |component|
      name = component['component']
      reasons << "candidate:unbound:#{name}" unless component['bound'] && component['commit'].to_s.length == 40
      if component['frozen_commit'] && component['commit'] != component['frozen_commit']
        reasons << "candidate:frozen_mismatch:#{name}"
      end
    end
    declared = components.map { |c| c['component'] }
    (candidate['repositories'] || []).each do |repo|
      reasons << "candidate:undeclared_repository:#{repo['name']}" unless declared.include?(repo['name'])
      reasons << "candidate:unbound_revision:#{repo['name']}" unless repo['commit'].to_s.length == 40
    end
    reasons
  end

  # ---------------------------------------------------------------- ledger

  def ledger_root(records)
    sha(records.map { |record| canonical(record) }.join("\n") + "\n")
  end

  def write_ledger(path, records)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'wb') { |io| records.each { |record| io.puts(canonical(record)) } }
  end

  def read_ledger(path)
    File.readlines(path, chomp: true).map.with_index do |line, i|
      record = JSON.parse(line)
      raise "non-canonical JSON on line #{i + 1}" unless line == canonical(record)
      record
    end
  end
end
