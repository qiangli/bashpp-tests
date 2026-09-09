#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline gate for the tour-executor/v2 ledger.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# The gate trusts NOTHING the runner wrote about itself. Every field it acts
# on is re-derived from files the gate reads independently (the contract, the
# phase-migration table, the inventory, the accepted baseline, the pins, the
# normalizer, the semantic comparator table) or recomputed from the ledger's
# own raw bytes. It fails closed on:
#
#   missing        a declared (row, mode) observation is absent, or the
#                  denominator is not 97 rows / 291 observations
#   PLANNED        any placeholder status (PLANNED, TODO, SKIP, PENDING, ...)
#   unexpected N/A any not-applicable claim inside the executable denominator,
#                  or an executable row citing an exception other than `none`
#   mismatched     a recorded status that disagrees with the status recomputed
#                  from that observation's own stages; a fresh Go baseline that
#                  does not reproduce the pinned accepted observation; a
#                  product mode whose normalized output differs from the
#                  baseline
#
# plus: a ledger not produced by the shared capture primitive, forged commands
# (argv re-derived from the contract), stage substitution (a successful
# transpile standing in for an artifact run), body execution on a `norun` row,
# a phase contract that drifted from either end of the migration table, an
# unauthenticated candidate, a source map that does not describe its own
# generated artifact, an over-strong input-absence claim, over-eager
# normalization, a forged semantic verdict or a fabricated oracle, and a
# tampered root or verdict.

require_relative 'executor'

ROOT = File.expand_path('../..', __dir__)
# Directory holding the reference pins/inventory/contract the gate re-derives
# from. It is ALWAYS this repository in real use — tools/tour/validate-executor.sh
# never sets TOUR_GATE_ROOT. The override exists so tools/tour/executor-selftests.rb
# can point the real gate at a synthetic 97-row fixture tree and prove the gate
# both passes a well-formed ledger and rejects each way of forging one.
REFS = ENV.fetch('TOUR_GATE_ROOT', ROOT)
LEDGER = ENV.fetch('TOUR_EXECUTOR_RESULTS', File.join(ROOT, 'tests/tour/executor-results.jsonl'))
NORMALIZER = ENV.fetch('TOUR_NORMALIZER', File.join(REFS, 'tools/tour/normalize.rb'))
# The longest wall-clock interval a single row's observations may claim. The
# clock-dependent comparators are evaluated against the RECORDED window, so an
# unbounded window would be an escape hatch: a run that "took eleven hours"
# could admit any hour-of-day greeting.
MAX_WINDOW_SECONDS = 900.0

FAILURES = []
def bad(reason)
  FAILURES << reason
end

abort "FATAL: missing ledger #{LEDGER}" unless File.file?(LEDGER)
records =
  begin
    TourExecutor.read_ledger(LEDGER)
  rescue StandardError => e
    abort "FATAL: unreadable ledger: #{e.message}"
  end

manifest = records.first
abort 'FATAL: ledger does not begin with a manifest' unless manifest.is_a?(Hash) && manifest['type'] == 'manifest'
abort "FATAL: schema mismatch (#{manifest['schema']})" unless manifest['schema'] == TourExecutor::SCHEMA
summary, root, verdict = records[-3], records[-2], records[-1]
abort 'FATAL: malformed ledger envelope' unless summary['type'] == 'summary' && root['type'] == 'root' && verdict['type'] == 'verdict'

# --- 1. binding: every pin the manifest names is re-hashed here -------------

{
  'contract' => 'docs/tour/executor-contract.tsv',
  'phase_migration' => 'docs/tour/phase-migration.tsv',
  'semantics' => 'docs/tour/semantics.tsv',
  'inventory' => 'tests/tour/inventory.tsv',
  'accepted_baseline' => 'tests/tour/results.tsv',
  'source_pin' => 'docs/tour/pin.tsv',
  'corpus' => 'docs/tour/corpus.tsv',
  'normalizer' => 'tools/tour/normalize.rb'
}.each do |key, expected_path|
  declared = manifest.dig(key, 'path')
  bad("binding:#{key}:path=#{declared}") unless declared == expected_path
  on_disk = TourExecutor.sha(File.binread(File.join(REFS, expected_path)))
  bad("binding:#{key}:sha256") unless manifest.dig(key, 'sha256') == on_disk
end
bad('binding:volatility:path') unless manifest.dig('volatility', 'path') == 'docs/tour/volatility.tsv'
bad('binding:volatility:sha256') unless manifest.dig('volatility', 'sha256') ==
                                        TourExecutor.sha(File.binread(File.join(REFS, 'docs/tour/volatility.tsv')))
# The volatility table is the MEASUREMENT RECORD; the comparator bindings live
# in docs/tour/semantics.tsv. A ledger that swaps those roles — claiming the
# measurement table itself excuses a mismatch — is rejected by name.
bad('volatility:claims_gate_effect') unless manifest.dig('volatility', 'gate_effect') == 'measurement-record'
bad('semantics:gate_effect') unless manifest.dig('semantics', 'gate_effect') == 'semantic-comparator'
bad('semantics:version') unless manifest.dig('semantics', 'version') == TourSemantics::VERSION
bad('semantics:library_sha256') unless manifest.dig('semantics', 'library_sha256') ==
                                       TourExecutor.sha(File.binread(File.join(REFS, 'tools/tour/semantics.rb')))
bad('binding:baseline_pin') unless manifest.dig('accepted_baseline', 'pin_sha256') ==
                                  TourExecutor.sha(File.binread(File.join(REFS, 'docs/tour/baseline-pin.tsv')))
bad('binding:normalizer_version') unless manifest.dig('normalizer', 'version') == 'tour-normalizer/v1'
bad('ledger:partial') if manifest['partial']

# -- the streams must have come from the SHARED capture primitive.
bad("capture:implementation=#{manifest['capture_implementation']}") unless
  manifest['capture_implementation'] == TourExecutor::CAPTURE_IMPLEMENTATION
bad('capture:library_sha256') unless manifest['capture_library_sha256'] ==
                                     TourExecutor.sha(File.binread(File.join(REFS, 'tools/corpus/executor.rb')))

contract = TourExecutor.load_contract(File.join(REFS, 'docs/tour/executor-contract.tsv'))
migration = TourExecutor.load_phase_migration(File.join(REFS, 'docs/tour/phase-migration.tsv'))
inventory = TourExecutor.load_inventory(File.join(REFS, 'tests/tour/inventory.tsv'))
items = inventory['items'].to_h { |i| [i['path'], i] }
accepted = TourExecutor.load_accepted(File.join(REFS, 'tests/tour/results.tsv'))
pin = TourExecutor.tsv_rows(File.join(REFS, 'docs/tour/pin.tsv')).first
tc = TourExecutor.tsv_rows(File.join(REFS, 'docs/tour/toolchain.tsv')).first
declared_volatility = TourExecutor.tsv_rows(File.join(REFS, 'docs/tour/volatility.tsv'))
                      .to_h { |p, e, c| [p, { 'volatile_element' => e, 'comparator_needed' => c }] }
semantics =
  begin
    TourSemantics.load_table(File.join(REFS, 'docs/tour/semantics.tsv'), inventory: items)
  rescue TourSemantics::TableError => e
    bad("semantics:table:#{e.message}")
    {}
  end
bad('semantics:row_set') unless semantics.keys.sort == declared_volatility.keys.sort

bad('denominator:inventory_data_sha256') unless manifest.dig('inventory', 'data_sha256') == inventory['data_sha256'] &&
                                               inventory['data_sha256'] == pin[7]
bad("denominator:executable=#{items.length}") unless items.length == TourExecutor::DENOMINATOR
bad('denominator:applicable') unless items.values.count { |i| i['applicability'] == 'applicable_go_program' } == TourExecutor::APPLICABLE_ROWS
bad('denominator:build_only') unless items.values.count { |i| i['applicability'] == 'build_only_go_program' } == TourExecutor::BUILD_ONLY_ROWS
bad('denominator:manifest_full97') unless manifest.dig('inventory', 'executable_programs') == TourExecutor::DENOMINATOR

# --- 2. phase contract: both ends of the migration table --------------------
#
# The pinned historical schema must still be exactly what the migration table
# says it is, AND the current contract must implement exactly the phase and the
# body policy the table declares. Neither side may be quietly rewritten to
# agree with the other.
TourExecutor.phase_migration_failures(migration, contract, items.values).each { |f| bad(f) }
migration.each do |(applicability, mode), row|
  next unless applicability == 'build_only_go_program'
  bad("phase_migration:body_allowed:#{mode}") if row['executes_body']
end

# --- 3. pinned Go baseline identity ----------------------------------------

bad('toolchain:identity') unless manifest.dig('go', 'identity') == tc[3]
bad('toolchain:sha256') unless manifest.dig('go', 'sha256') == tc[4]

# --- 4. helper module provisioning -----------------------------------------

helper = TourExecutor.tsv_rows(File.join(REFS, 'docs/tour/helpers.tsv')).first
{ 'module' => 0, 'version' => 1, 'license' => 2, 'go_mod_sum' => 3, 'zip_sum' => 4 }.each do |field, i|
  bad("helper:#{field}") unless manifest.dig('helper_module', field) == helper[i]
end
bad('helper:packages') unless manifest.dig('helper_module', 'packages') == helper[5].split(',')
bad('helper:not_materialized') if manifest.dig('helper_module', 'materialized_dir').to_s.empty?

# --- 5. candidate provenance (manifest-authenticated) ----------------------

candidate = manifest['candidate'] || {}
bad('candidate:contract_sha256') unless candidate['contract_sha256'] ==
                                       TourExecutor.sha(File.binread(File.join(REFS, 'docs/tour/candidate.tsv')))
declared_contract = TourExecutor.load_candidate_contract(File.join(REFS, 'docs/tour/candidate.tsv'))
declared_components = declared_contract.map { |c| c['component'] }.sort
bad('candidate:component_set') unless (candidate['components'] || []).map { |c| c['component'] }.sort == declared_components
# Every replaced dependency compiled into the payload must be declared AND
# bound: a repository in the manifest that this contract never declared is
# unreviewed product code, and a declared component missing from the manifest
# is unauthenticated product code.
bad('candidate:repository_set') unless (candidate['repositories'] || []).map { |r| r['name'] }.sort == declared_components
declared_contract.each do |expected|
  component = (candidate['components'] || []).find { |c| c['component'] == expected['component'] } || {}
  bad("candidate:component_contract:#{expected['component']}") unless expected.all? { |k, v| component[k] == v }
  repository = (candidate['repositories'] || []).find { |repo| repo['name'] == expected['component'] } || {}
  bad("candidate:component_repository:#{expected['component']}") unless component['commit'] == repository['commit'] && component['dir'] == repository['path']
end
TourExecutor.candidate_failures(candidate).each { |reason| bad(reason) }
begin
  bad('runtime_dependency:candidate_binding') unless manifest['runtime_dependency'] == TourExecutor.runtime_dependency(candidate)
rescue Corpus::ContractError, KeyError => e
  bad("runtime_dependency:#{e.message}")
end
bad('candidate:not_reauthenticated') unless summary['candidate_reauthenticated'] == true

bad('candidate:runner_hid_failures') unless (manifest['candidate_failures'] || []).sort == TourExecutor.candidate_failures(candidate).sort
# The honest-scope claim, at manifest level.
bad('input_absence:os_sandbox_claimed') if manifest.dig('environment', 'os_sandbox')
bad('input_absence:scope') unless manifest.dig('environment', 'input_absence_scope') == TourExecutor::INPUT_ABSENCE_SCOPE

# --- 6. the native oracle ---------------------------------------------------

run_window = manifest['run_window'] || {}
oracle_records = records.select { |r| r['type'] == 'oracle' }
oracles = oracle_records.to_h { |r| [r['path'], r] }
bad('oracle:duplicate') unless oracle_records.length == oracles.length
bad("oracle:row_set:#{(oracles.keys.sort - semantics.keys.sort).inspect}") unless oracles.keys.sort == semantics.keys.sort
oracles.each do |path, oracle|
  row = semantics[path]
  next bad("oracle:undeclared:#{path}") unless row
  bad("oracle:comparator:#{path}") unless oracle['comparator'] == row['comparator']
  bad("oracle:source_binding:#{path}") unless oracle['source_sha256'] == row['source_sha256'] &&
                                              oracle['source_sha256'] == items[path]['sha256']
  runs = oracle['runs'] || []
  bad("oracle:repeats:#{path}:#{runs.length}") unless runs.length == oracle['repeats'] && runs.length >= TourSemantics::MIN_ORACLE_RUNS
  runs.each do |r|
    bad("oracle:run_not_clean:#{path}:#{r['index']}") unless r['spawned'] && r['state'] == 'exited' && !r['descendants_survived']
    %w[stdout stderr].each do |stream|
      decoded = Base64.decode64(r["#{stream}_base64"].to_s)
      bad("oracle:raw_bytes:#{path}:#{r['index']}:#{stream}") unless decoded.bytesize == r["#{stream}_bytes"]
    end
  end
end

# --- 7. observations: completeness, statuses, commands, normalization -------

observations = records.select { |r| r['type'] == 'observation' }
seen = {}
observations.each do |observation|
  key = [observation['path'], observation['mode']]
  bad("duplicate:#{key.join('/')}") if seen.key?(key)
  seen[key] = observation
end
items.each_key do |path|
  TourExecutor::MODES.each do |mode|
    bad("missing:#{path}/#{mode}") unless seen.key?([path, mode])
  end
end
seen.each_key do |path, mode|
  bad("unknown_row:#{path}") unless items.key?(path)
  bad("unknown_mode:#{mode}") unless TourExecutor::MODES.include?(mode)
end
bad("observations=#{observations.length}") unless observations.length == TourExecutor::OBSERVATIONS

baselines = seen.select { |(_, mode), _| mode == 'baseline' }.to_h { |(path, _), o| [path, o] }

observations.each do |observation|
  path, mode = observation['path'], observation['mode']
  tag = "#{path}/#{mode}"
  item = items[path]
  next unless item

  # -- unexpected N/A and placeholder statuses
  status = observation['status'].to_s
  if TourExecutor::FORBIDDEN_STATUSES.include?(status.upcase) || status.upcase.start_with?('PLANNED', 'N/A', 'NOT_APPLICABLE')
    bad("placeholder_status:#{tag}:#{status}")
    next
  end
  # No observation-level escape hatch of any spelling may exist: an N/A, a
  # waiver or an "expected failure" inside the executable denominator is
  # exactly the unexpected-N/A class story #4 requires the gate to fail on.
  %w[not_applicable na_reason exempt exempt_reason waived expected_failure allowed_failure].each do |escape|
    bad("unexpected_na:#{tag}:#{escape}") if observation[escape]
  end
  # A volatility annotation is the measurement record, never a dispensation: it
  # must match the declared table, and it changes no status by itself.
  if observation['volatility']
    bad("volatility_undeclared:#{tag}") unless declared_volatility[path] == observation['volatility']
  end
  bad("unexpected_exception:#{tag}:#{item['exception']}") unless item['exception'] == 'none'
  bad("applicability_drift:#{tag}") unless observation['applicability'] == item['applicability']
  bad("schema_drift:#{tag}") unless observation['differential_schema'] == item['differential_schema']
  bad("source_drift:#{tag}") unless observation.dig('source', 'sha256') == item['sha256'] &&
                                    observation.dig('source', 'bytes') == item['bytes']

  recipe = contract.fetch([item['applicability'], mode])
  migration_row = migration.fetch([item['applicability'], mode])
  bad("phase_drift:#{tag}") unless observation['phase'] == recipe['phase']
  bad("historical_phase_drift:#{tag}") unless observation['historical_phase_token'] == migration_row['historical_token']
  stages = observation['stages'] || []
  bad("stage_count:#{tag}") unless stages.length == recipe['stages'].length

  artifact_dir = File.join(manifest.fetch('evidence_root', ''), mode, TourExecutor.slug(path), 'artifacts')
  expected_subs = TourExecutor.substitutions(item, bashy: candidate.dig('binaries', 'launcher', 'path'),
                                             go_bin: manifest.dig('go', 'path'), artifact_dir: artifact_dir)
  bad('artifact_root:missing_or_relative') unless manifest['evidence_root'].to_s.start_with?('/')
  # -- forged commands: re-render argv from the contract itself
  stages.each_with_index do |stage, i|
    spec = recipe['stages'][i]
    next unless spec
    bad("stage_name:#{tag}:#{i}") unless stage['stage'] == spec['stage'] && stage['index'] == spec['index']
    bad("execute_body_drift:#{tag}:#{spec['stage']}") unless stage['execute_body'] == spec['execute_body']
    template = spec['argv_template']
    got = stage['command'] || []
    bad("argv_identity:#{tag}:#{spec['stage']}") unless got == TourExecutor.render_argv(template, expected_subs)
    bad("argv_shape:#{tag}:#{spec['stage']}") unless got.length == template.length
    template.each_with_index do |token, j|
      next if token.match?(/\{\w+\}/) # placeholder: value checked below
      bad("argv_literal:#{tag}:#{spec['stage']}:#{j}") unless got[j] == token
    end
    # {SRC} must be the row's own module-relative path — a row cannot be
    # scored against a different (easier) source file.
    src_at = template.index('{SRC}')
    bad("argv_src:#{tag}:#{spec['stage']}") if src_at && got[src_at] != path
    go_at = template.index('{GO}')
    bad("argv_go:#{tag}:#{spec['stage']}") if go_at && got[go_at] != manifest.dig('go', 'path')
    bashy_at = template.index('{BASHY}')
    bad("argv_bashy:#{tag}:#{spec['stage']}") if bashy_at && got[bashy_at] != candidate.dig('binaries', 'launcher', 'path')
    bad("artifact_set:#{tag}:#{spec['stage']}") unless (stage['artifacts'] || {}).keys.sort == spec['produces'].sort
    (stage['artifacts'] || {}).each do |name, artifact|
      key = { 'go' => 'OUT_GO', 'map' => 'OUT_MAP', 'bin' => 'BIN' }[name]
      bad("artifact_path:#{tag}:#{name}") unless key && artifact['path'] == File.basename(expected_subs.fetch(key))
      if artifact['present']
        bad("artifact_digest:#{tag}:#{name}") unless artifact['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) && artifact['bytes'].is_a?(Integer) && artifact['bytes'].positive?
      end
    end
    if stage['spawned']
      inputs = stage['inputs'] || {}
      bad("artifact_input_set:#{tag}:#{spec['stage']}") unless inputs.keys.sort == TourExecutor.consumed_artifacts(spec).sort
      inputs.each do |name, input|
        producer = stages[0...i].reverse.find { |previous| previous.fetch('artifacts', {}).key?(name) }
        produced = producer && producer['artifacts'][name]
        fields = %w[present bytes sha256 path]
        bad("artifact_input_identity:#{tag}:#{name}") unless produced && input['present'] && fields.all? { |field| input[field] == produced[field] }
      end
    end

    # -- no body execution on a `norun`/build obligation
    if !spec['execute_body'] && stage['exit'] == 0 && stage.dig('normalized', 'stdout', 'bytes').to_i.positive?
      bad("body_executed:#{tag}:#{spec['stage']}")
    end

    # -- the input-absence claim: exactly the scope the corpus can honour.
    #    A body stage must run with an empty PATH; a NATIVE body stage must run
    #    from the emptied runtime cwd; interpreted mode necessarily keeps its
    #    module context and says so. Claiming an OS sandbox is a finding.
    if spec['execute_body'] && stage['state'] != 'not_reached'
      absence = stage['input_absence'] || {}
      bad("input_absence:scope:#{tag}") unless absence['scope'] == TourExecutor::INPUT_ABSENCE_SCOPE
      bad("input_absence:os_sandbox_claimed:#{tag}") if absence['os_sandbox']
      bad("input_absence:path:#{tag}") unless stage['path_env'] == '' && absence['path_env'] == ''
      expected_cwd = mode == 'interpreted' ? 'module' : 'runtime'
      bad("input_absence:cwd:#{tag}:#{stage['cwd']}") unless stage['cwd'] == expected_cwd && absence['cwd'] == expected_cwd
    end

    # -- normalization audit, recomputed from the stored raw bytes
    %w[stdout stderr].each do |stream|
      raw = Base64.decode64(stage.dig('raw', "#{stream}_base64").to_s)
      bad("raw_bytes:#{tag}:#{spec['stage']}:#{stream}") unless raw.bytesize == stage.dig('raw', "#{stream}_bytes")
      expected = TourExecutor.audit_normalize(raw)
      recorded = stage.dig('normalized', stream) || {}
      if expected.nil?
        bad("utf8_claim:#{tag}:#{spec['stage']}:#{stream}") if recorded['valid_utf8']
      else
        bad("normalizer_drift:#{tag}:#{spec['stage']}:#{stream}") unless recorded['valid_utf8'] &&
                                                                        recorded['bytes'] == expected.bytesize &&
                                                                        recorded['sha256'] == TourExecutor.sha(expected)
        # Blanket masking: the declared v1 rules can only delete CR bytes and
        # shrink pointer literals. A stream that survived normalization as
        # nothing, or lost more than a quarter of its bytes, is masking.
        if !raw.empty? && (expected.bytesize.zero? || expected.bytesize * 4 < raw.bytesize * 3)
          bad("blanket_masking:#{tag}:#{spec['stage']}:#{stream}")
        end
      end
    end
  end

  # -- stage substitution: a later stage may only have run once every earlier
  #    stage produced its declared artifacts.
  stages.each_with_index do |stage, i|
    next if i.zero?
    previous = stages[i - 1]
    if stage['spawned'] && (previous['exit'] != 0 || (previous['artifacts'] || {}).any? { |_, a| !a['present'] })
      bad("stage_substitution:#{tag}:#{stage['stage']}")
    end
  end

  # -- source map preservation: a successful transpile must have emitted a map
  #    that describes THIS source and THIS generated artifact.
  transpile = stages.find { |s| s['stage'] == 'transpile' }
  if transpile && transpile['exit'] == 0
    TourExecutor.source_map_failures(transpile, path).each { |f| bad("#{f}:#{tag}") }
  end

  # -- the semantic verdict, recomputed independently from the stored raw
  #    bytes and the stored oracle. A hand-written `ok` cannot survive this.
  semantic_row = semantics[path]
  if observation['semantic'] && semantic_row.nil?
    bad("semantic_undeclared:#{tag}")
  elsif semantic_row
    oracle = oracles[path]
    if oracle.nil?
      bad("semantic_no_oracle:#{tag}")
    else
      window = observation['window'] || {}
      derived = TourExecutor.semantic_window(stages, oracle['runs'] || [], window['utc_offset'])
      bad("semantic_window_forged:#{tag}") unless derived && window == derived
      bad("semantic_window_length:#{tag}") unless window['to'].to_f - window['from'].to_f <= MAX_WINDOW_SECONDS
      if run_window['from'] && run_window['to']
        contained = window['from'].to_f >= run_window['from'].to_f - 1 && window['to'].to_f <= run_window['to'].to_f + 1
        bad("semantic_window_outside_run:#{tag}") unless contained
      end
      # The oracle must be repeats of the very artifact the baseline built.
      baseline_build = (baselines[path] || {}).fetch('stages', []).find { |s| s['stage'] == 'build' }
      if baseline_build && baseline_build.dig('artifacts', 'bin', 'present')
        bad("oracle_binary_mismatch:#{path}") unless oracle.dig('binary', 'sha256') == baseline_build.dig('artifacts', 'bin', 'sha256')
      end
      decoded_oracle = (oracle['runs'] || []).map do |r|
        { 'exit' => r['exit'],
          'stdout' => Base64.decode64(r['stdout_base64'].to_s).force_encoding('UTF-8'),
          'stderr' => Base64.decode64(r['stderr_base64'].to_s).force_encoding('UTF-8') }
      end
      final = stages[TourExecutor.authoritative_index(stages)]
      candidate_streams = {
        'exit' => final['exit'],
        'stdout' => Base64.decode64(final.dig('raw', 'stdout_base64').to_s).force_encoding('UTF-8'),
        'stderr' => Base64.decode64(final.dig('raw', 'stderr_base64').to_s).force_encoding('UTF-8')
      }
      recomputed = TourSemantics.compare(semantic_row, candidate: candidate_streams,
                                         oracle: decoded_oracle, window: window)
      recorded = (observation['semantic'] || {}).reject { |k, _| k == 'stage' }
      bad("semantic_forged:#{tag}") unless recorded == recomputed
    end
  end

  # -- the verdict, recomputed from this observation's own stages
  recomputed = TourExecutor.observation_status(
    observation, recipe: recipe, accepted: accepted[path],
    baseline_observation: mode == 'baseline' ? nil : baselines[path],
    semantic_row: semantic_row
  )
  bad("status_forged:#{tag}:recorded=#{status} recomputed=#{recomputed}") unless status == recomputed
  bad("not_pass:#{tag}:#{recomputed}") unless recomputed == 'PASS'
end

# --- 8. summary, root and verdict recomputed -------------------------------

expected_counts = observations.group_by { |r| r['status'] }.transform_values(&:length).sort.to_h
bad('summary:outcomes') unless summary['outcomes'] == expected_counts
bad('summary:observations') unless summary['observations'] == observations.length
bad('summary:semantic_rows') unless summary['semantic_rows'] == oracles.length
bad('root:tampered') unless root['sha256'] == TourExecutor.ledger_root(records[0..-3])
bad('verdict:root_binding') unless verdict['root_sha256'] == root['sha256']
should_pass = FAILURES.empty?
bad("verdict:forged (claims #{verdict['value']})") if verdict['value'] == 'PASS' && !should_pass
bad("verdict:not_pass (#{verdict['value']})") unless verdict['value'] == 'PASS'

# --- report ----------------------------------------------------------------

if FAILURES.empty?
  puts "tour executor gate PASS: #{TourExecutor::DENOMINATOR} programs x #{TourExecutor::MODES.length} modes = #{TourExecutor::OBSERVATIONS} observations"
  puts "  semantic rows #{oracles.length}, oracle runs #{oracles.values.sum { |o| o['repeats'].to_i }}"
  puts "  root #{root['sha256']}"
  exit 0
end

grouped = FAILURES.group_by { |f| f.split(':').first }.transform_values(&:length).sort_by { |_, v| -v }
warn "tour executor gate FAIL: #{FAILURES.length} findings"
grouped.each { |kind, count| warn "  #{count.to_s.rjust(5)}  #{kind}" }
warn '  --- first 25 ---'
FAILURES.first(25).each { |f| warn "  #{f}" }
exit 1
