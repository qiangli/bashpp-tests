# frozen_string_literal: true
# Sprint: #118/#142; Story: #24; Story-ID: 3abd77da923c/605c7c4f2cad
# Complete root accounting; only exact implemented recipes can acquire PASS.
require 'json'
require 'optparse'
require 'fileutils'
require 'digest'
require ENV.fetch('GO_FULL_CORPUS_LIB', File.expand_path('../corpus/executor.rb', __dir__))
require_relative 'native'
require_relative 'typechecker'
require_relative 'authentication'
require_relative 'resume'
require_relative 'module_context'
require_relative 'subset'
require_relative 'recipe_adapters'
require_relative 'router'
require_relative 'stage_resolver'
require_relative 'packet_manifest'

module GoFullProduct
  module_function

  PACKET_MANIFEST_SHA256 = {
    '148.4' => '2a5f736d560267caa155a942e2c8d326d6bb77b23a8f40b40980af5f3c99f841',
    '148.6' => '1c9c58f3343a707cd3dbca197bbb41b8cea4907ae4d2be87f776b4618e149f4c'
  }.freeze

  def anchor_stage_ids(packet, root_id)
    raise Corpus::ContractError, 'unsupported Wave B packet' unless PACKET_MANIFEST_SHA256.key?(packet)
    executions = packet == '148.4' ? 3.times.map { |index| "#{root_id}:ordered-#{index + 1}" } : [root_id]
    executions.flat_map do |execution_id|
      { 'baseline' => %w[build run], 'interpreted' => %w[run], 'compiled' => %w[transpile build run] }.flat_map do |mode, stages|
        stages.map { |stage| "#{execution_id}/#{mode}/#{stage}" }
      end
    end
  end

  def read_rows(path)
    File.foreach(path).map { |line| JSON.parse(line) }
  end

  def unique_rows(path)
    rows = read_rows(path)
    ids = rows.map { |row| row.fetch('id') }
    raise Corpus::ContractError, "duplicate root IDs: #{path}" unless ids.uniq == ids
    rows.to_h { |row| [row.fetch('id'), row] }
  end

  def verify_sdk_identity(native, current, relocation_file = nil, **options)
    GoFullAuthentication.verify_sdk_identity(native, current, relocation_file, **options)
  end

  def simple_recipe?(root)
    recipe = root.fetch('recipe')
    %w[run build buildrun compile].include?(recipe['action']) && recipe.fetch('flags', []).empty? &&
      recipe.fetch('environment_append', []).empty? && !recipe.key?('timeout_seconds_before_scale') &&
      !root.key?('nested_process_obligation') && !root.key?('program_directory_inputs') &&
      !root.key?('generated_program') && !root.key?('directory') && root.fetch('expected_failure_sets').empty?
  end

  def generator_recipe?(root)
    recipe = root.fetch('recipe')
    recipe['action'] == 'runoutput' && recipe.fetch('flags', []).empty? && recipe.fetch('environment_append', []).empty? &&
      !recipe.key?('timeout_seconds_before_scale') && !root.key?('nested_process_obligation') && root.fetch('expected_failure_sets').empty?
  end

  def execute_generator(root, executor, source_root, module_files, evidence)
    generator = executor.execute(id: root.fetch('id') + ':generator', root_id: root.fetch('id'), source_root: source_root, sources: [root.fetch('path')],
                                 phase: 'run', args: root.fetch('recipe').fetch('args'), module_files: module_files)
    children = {}
    generator.fetch('modes').each do |mode, observation|
      child = { 'parent_root' => root.fetch('id'), 'emitting_mode' => mode, 'verdict' => 'FAIL',
                'expected_child_modes' => Corpus::MODES, 'actual_child_modes' => [] }
      stage = observation.fetch('stages').find { |step| step['stage'] == 'run' }
      unless stage && Corpus.success?(stage) && observation['input_integrity']
        children[mode] = child.merge('reason' => 'generator did not successfully execute with intact source')
        next
      end
      out = File.binread(stage.fetch('stdout').fetch('path'))
      err = File.binread(stage.fetch('stderr').fetch('path'))
      unless out.empty? || err.empty?
        children[mode] = child.merge('reason' => 'generated source uses both streams; combined-stream capture order is unavailable')
        next
      end
      bytes, stream = out.empty? ? [err, 'stderr'] : [out, 'stdout']
      if bytes.empty?
        children[mode] = child.merge('reason' => 'generator produced no source bytes')
        next
      end
      generated_root = Corpus.safe_path(File.join(evidence, 'generated-inputs'), root.fetch('id') + '/' + mode)
      FileUtils.mkdir_p(generated_root)
      generated_path = File.join(generated_root, 'tmp__.go')
      # Exact bytes emitted by THIS parent mode; no formatting, edits, or reuse
      # of a different mode's generator output, even if all digests are equal.
      File.binwrite(generated_path, bytes)
      child['generated_source'] = Corpus.file_record(generated_path)
      child['emitter_stream'] = stage.fetch(stream)
      child['generated_source']['lineage'] = { 'root_id' => root.fetch('id'),
                                                'parent_launch_id' => stage.dig('lineage', 'launch_id'),
                                                'parent_artifact' => stream }
      raise Corpus::ContractError, 'generated source differs from its mode-specific emitter stream' unless child['generated_source']['sha256'] == child['emitter_stream']['sha256']
      execution = executor.execute(id: root.fetch('id') + ':generated-by-' + mode, root_id: root.fetch('id'),
                                   parent_launch_id: stage.dig('lineage', 'launch_id'), source_root: generated_root,
                                   sources: ['tmp__.go'], phase: 'run', module_files: module_files)
      child['execution'] = execution
      child['actual_child_modes'] = execution.fetch('modes').keys
      child['upstream_output'] = exact_upstream_output(execution, root, source_root)
      child['verdict'] = execution['verdict'] == 'PASS' && child['upstream_output']['status'] == 'PASS' && child['actual_child_modes'] == child['expected_child_modes'] ? 'PASS' : 'FAIL'
      children[mode] = child
    end
    retained_executions = [generator] + children.values.map { |child| child['execution'] }.compact
    stages = retained_executions.flat_map { |record| record.fetch('modes').values.flat_map { |mode| mode.fetch('stages') } }
    complete = generator['verdict'] == 'PASS' && children.keys == Corpus::MODES && children.values.all? { |child| child['verdict'] == 'PASS' }
    { 'verdict' => complete ? 'PASS' : 'FAIL', 'generator_execution' => generator, 'generated_children' => children,
      'generated_artifact_denominator' => { 'expected' => 3, 'observed' => children.values.count { |child| child.key?('generated_source') } },
      'child_mode_denominator' => { 'expected' => 9, 'observed' => children.values.sum { |child| child['actual_child_modes'].length } },
      'measured_process_seconds' => stages.sum { |stage| stage.fetch('duration_seconds', 0) },
      'retained_process_stage_count' => stages.length,
      'cache_policy' => 'shared executor creates private per-case/per-mode GOCACHE; no writable cross-candidate cache sharing',
      'lineage_rule' => 'Each original mode executes the source that its own generator emitted; extra cross-mode children also must pass.' }
  end

  def diagnostic_recipe?(root)
    recipe = root.fetch('recipe')
    %w[errorcheck errorcheckwithauto].include?(recipe['action']) && recipe['want_error'] == true &&
      recipe.fetch('flags', []).empty? && recipe.fetch('environment_append', []).empty? &&
      !recipe.key?('timeout_seconds_before_scale') && root.fetch('expected_failure_sets').empty?
  end

  def stage_environment(runtime, directory)
    environment = runtime.fetch('base_environment').merge('HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => runtime.fetch('cache_path'))
    %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(environment.fetch(key)) }
    environment
  end

  def build_matcher(evidence, sdk_identity, runtime = nil)
    source = File.join(__dir__, 'diagnostics')
    inputs = Dir[File.join(source, '*.go')] + [File.join(source, 'go.mod')]
    before = inputs.to_h { |path| [path, Corpus.file_record(path)] }
    directory = File.join(evidence, 'diagnostics-tool')
    FileUtils.mkdir_p(directory)
    env = { 'PATH' => '/usr/bin:/bin', 'GOTOOLCHAIN' => 'local', 'GOROOT' => sdk_identity.fetch('root'), 'GOMAXPROCS' => '1',
            'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'GOENV' => 'off', 'GOFLAGS' => '',
            'HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => File.join(directory, 'gocache') }
    env = stage_environment(runtime, directory) if runtime
    %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(env.fetch(key)) }
    binary = File.join(directory, 'diagnostics')
    stage = Corpus.capture([File.join(sdk_identity.fetch('root'), 'bin/go'), 'build', '-p=1', '-trimpath', '-o', binary, '.'],
                           cwd: source, log_prefix: File.join(directory, 'build'), env: env, timeout: 180)
    raise Corpus::ContractError, 'diagnostic matcher failed to build' unless Corpus.success?(stage) && File.executable?(binary) && File.size?(binary)
    raise Corpus::ContractError, 'diagnostic matcher sources changed during build' unless before.all? { |path, record| Corpus.digest(path) == record.fetch('sha256') }
    { 'binary' => Corpus.file_record(binary), 'sources' => before, 'build_stage' => stage, 'runtime' => runtime }
  end

  def match_diagnostics(root, modes, matcher, evidence, timeout)
    modes.to_h do |mode, observation|
      stage = observation['stage']
      unless stage && observation['input_integrity']
        next [mode, observation.merge('verdict' => 'FAIL', 'reason' => 'missing process evidence or source mutation')]
      end
      directory = Corpus.safe_path(File.join(evidence, 'diagnostic-matches'), root.fetch('id') + '/' + mode)
      FileUtils.mkdir_p(directory)
      inputs = observation.fetch('inputs').map do |relative, original|
        { 'path' => File.join(stage.fetch('cwd'), relative), 'short' => File.basename(relative), 'sha256' => original.fetch('sha256') }
      end
      request = { 'want_auto' => root.fetch('recipe').fetch('want_autogenerated_diagnostics'), 'want_error' => root.fetch('recipe').fetch('want_error'),
                  'sources' => inputs, 'stdout' => stage.fetch('stdout').slice('path', 'sha256'), 'stderr' => stage.fetch('stderr').slice('path', 'sha256'),
                  'process' => stage.slice('spawned', 'state', 'exit', 'signal') }
      input_path = File.join(directory, 'request.json')
      File.write(input_path, Corpus.canonical(request) + "\n")
      binary = matcher.fetch('binary')
      Corpus.authenticate_file(binary.fetch('path'), binary.fetch('sha256'))
      match_env = matcher['runtime'] ? stage_environment(matcher.fetch('runtime'), directory).merge('PATH' => '') : { 'PATH' => '', 'GOMAXPROCS' => '1', 'LC_ALL' => 'C' }
      checked = Corpus.capture([binary.fetch('path')], cwd: directory, log_prefix: File.join(directory, 'match'),
                               env: match_env, timeout: timeout, stdin: input_path)
      result = JSON.parse(File.read(checked.fetch('stdout').fetch('path'))) rescue { 'verdict' => 'FAIL', 'reason' => 'matcher did not return JSON' }
      verdict = Corpus.success?(checked) && result['verdict'] == 'PASS' ? 'PASS' : 'FAIL'
      [mode, observation.merge('verdict' => verdict, 'stage_role' => 'semantic-rejection-check', 'reason' => result['reason'],
                               'diagnostic_request' => Corpus.file_record(input_path), 'diagnostic_stage' => checked, 'diagnostic_result' => result)]
    end
  end

  def exact_upstream_output(record, root, source_root)
    expected = root['expected_output']
    return { 'status' => 'not-consumed' } unless expected
    executions = record.fetch('ordered_repetitions', [record])
    observations = {}
    executions.each_with_index do |execution, repetition|
      modes = execution.fetch('modes')
      unless modes.keys.sort == Corpus::MODES.sort
        return { 'status' => 'FAIL', 'reason' => 'execution mode denominator differs from required modes' }
      end
      modes.each do |mode_name, mode|
        unless mode.fetch('mode') == mode_name
          return { 'status' => 'FAIL', 'reason' => 'execution mode identity differs from its mode key' }
        end
        run_stages = mode.fetch('stages').select { |stage| stage['stage'] == 'run' }
        unless run_stages.length == 1 && Corpus.success?(run_stages.first)
          return { 'status' => 'FAIL', 'reason' => 'mode must contain exactly one successful run observation' }
        end
        stage = run_stages.first
        value = if stage['combined']
                  Corpus::Validation.file!(stage.fetch('combined'))
                  File.binread(stage.fetch('combined').fetch('path'))
                else
                  Corpus::Validation.file!(stage.fetch('stdout'))
                  Corpus::Validation.file!(stage.fetch('stderr'))
                  out = File.binread(stage.fetch('stdout').fetch('path'))
                  err = File.binread(stage.fetch('stderr').fetch('path'))
                  # Independent logs are non-ordering evidence. They can satisfy only the
                  # degenerate case where at most one stream contains bytes.
                  return { 'status' => 'FAIL', 'reason' => 'combined-stream ordering requires kernel-combined capture' } unless out.empty? || err.empty?
                  out + err
                end
        observations["#{repetition}:#{mode_name}"] = value
      end
    end
    return { 'status' => 'FAIL', 'reason' => 'no run observations matched expected output' } if observations.empty?
    path = File.join(source_root, expected.fetch('path'))
    bytes = if expected.fetch('present')
              raise Corpus::ContractError, 'sidecar digest changed' unless Corpus.digest(path) == expected.fetch('sha256')
              File.binread(path)
            else
              raise Corpus::ContractError, 'sidecar appeared where absent' if File.exist?(path)
              ''.b
            end
    { 'status' => observations.values.all? { |value| value == bytes } ? 'PASS' : 'FAIL',
      'expected' => expected, 'observed_sha256' => observations.transform_values { |value| Digest::SHA256.hexdigest(value) } }
  end

  def authenticate_execution_lineage!(record, root_id)
    executions = record.fetch('ordered_repetitions', [record])
    stages = executions.flat_map { |execution| execution.fetch('modes').values.flat_map { |mode| mode.fetch('stages') } }
    ledgers = stages.group_by { |stage| stage.dig('lineage', 'path') }
    raise Corpus::ContractError, 'execution stage lacks a lineage ledger' if ledgers.key?(nil)
    ledgers.each do |path, expected_stages|
      payloads = Corpus::ProcessLineage.authenticate!(path)
      expected_stages.each do |stage|
        reference = stage.fetch('lineage')
        matches = payloads.select { |payload| payload['launch_id'] == reference['launch_id'] }
        raise Corpus::ContractError, 'execution lineage launch is missing or ambiguous' unless matches.length == 1
        payload = matches.first
        unless payload.values_at('root_id', 'stage_id') == [root_id, reference['stage_id']] &&
               Corpus::ProcessLineage.payload_sha256(payload) == reference['payload_sha256']
          raise Corpus::ContractError, 'execution lineage root/stage/payload join differs'
        end
        terminal = payload.fetch('terminal')
        unless stage.values_at('spawned', 'state', 'exit', 'signal') ==
               [!payload.dig('launch', 'pid').nil?, terminal['state'], terminal['exit'], terminal['signal']]
          raise Corpus::ContractError, 'execution stage terminal differs from persisted lineage'
        end
        %w[combined stdout stderr].each do |label|
          next unless stage[label] || payload.fetch('artifacts')[label]
          payload_record = payload.fetch('artifacts').fetch(label)
          stage_record = stage.fetch(label)
          unless stage_record.slice('path', 'sha256', 'bytes') == payload_record.slice('path', 'sha256', 'bytes')
            raise Corpus::ContractError, 'execution stage artifact differs from persisted lineage'
          end
        end
      end
    end
    true
  end

  def fresh_reauthenticate_execution!(record, identity_receipts)
    executions = record.fetch('ordered_repetitions', [record])
    stages = executions.flat_map { |execution| execution.fetch('modes').values.flat_map { |mode| mode.fetch('stages') } }
    lineage_checks = stages.map { |stage| stage.dig('lineage', 'path') }.uniq.sort.map do |path|
      out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path('../corpus/process_lineage.rb', __dir__), path)
      raise Corpus::ContractError, "fresh lineage reauthentication failed: #{err}" unless status.success?
      { 'path' => path, 'result_sha256' => Digest::SHA256.hexdigest(out), 'status' => status.exitstatus }
    end
    identity_checks = identity_receipts.values.uniq.sort_by { |reference| reference.fetch('path') }.map do |reference|
      out, err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'execution_identity.rb'), 'verify',
                                       reference.fetch('path'), reference.fetch('sha256'))
      raise Corpus::ContractError, "fresh execution identity reauthentication failed: #{err}" unless status.success?
      { 'path' => reference.fetch('path'), 'sha256' => reference.fetch('sha256'),
        'result_sha256' => Digest::SHA256.hexdigest(out), 'status' => status.exitstatus }
    end
    { 'lineage' => lineage_checks, 'execution_identity' => identity_checks }
  end

  def execute_anchor(root, executor, source_root, module_files, oracle, identity_receipts: nil)
    id = root.fetch('id')
    case id
    when 'testdir:fixedbugs/issue21808.go'
      repetitions = 3.times.map do |index|
        executor.execute(id: "#{id}:ordered-#{index + 1}", root_id: id, source_root: source_root,
                         sources: [root.fetch('path')], phase: 'run', module_files: module_files,
                         combined_output: true, identity_receipts: identity_receipts, native_observation: oracle)
      end
      record = repetitions.first.merge('ordered_repetitions' => repetitions)
      [record, { 'mechanism' => 'kernel-combined', 'packet' => '148.4' }]
    when GoFullRecipeRouter::PACKET_ROOT_ID
      phases = GoFullRecipeRouter.phase_contract('run')
      graph = [{ 'kind' => 'sdk-dependency' }]
      routes = Corpus::MODES.to_h do |mode|
        [mode, GoFullRecipeRouter.route!(root: root, mode: mode, phases: phases, graph: graph,
                                         native_observation: oracle, source_root: source_root)]
      end
      plans = routes.values.map { |route| route.fetch('plan').slice('compile_inputs', 'argv', 'executor_phase', 'package_input_required') }
      raise Corpus::ContractError, 'mode routes produced different execution plans' unless plans.uniq.length == 1
      plan = plans.first
      package_input = plan.fetch('package_input_required') ? File.dirname(root.fetch('path')) : nil
      record = executor.execute(id: id, source_root: source_root, sources: plan.fetch('compile_inputs'),
                                phase: plan.fetch('executor_phase'), args: plan.fetch('argv'), module_files: module_files,
                                package_input: package_input, combined_output: true, route: routes,
                                identity_receipts: identity_receipts, native_observation: oracle)
      [record, routes]
    else
      raise Corpus::ContractError, 'root is not a Sprint 148 anchor'
    end
  end

  def anchor_root?(root)
    ['testdir:fixedbugs/issue21808.go', GoFullRecipeRouter::PACKET_ROOT_ID].include?(root['id'])
  end

  def load_identity_index(path, expected_sha256, root_id, expected_stage_ids:)
    record = Corpus.file_record(path)
    raise Corpus::ContractError, 'execution identity index digest differs' unless record['sha256'] == expected_sha256
    index = JSON.parse(File.binread(path))
    unless index.is_a?(Hash) && index.keys.sort == %w[entries root_id schema] &&
           index['schema'] == 'go-full-execution-identity-index/v1' && index['root_id'] == root_id &&
           index['entries'].is_a?(Hash) && !index['entries'].empty?
      raise Corpus::ContractError, 'execution identity index is malformed or for another root'
    end
    index.fetch('entries').each do |stage_id, reference|
      raise Corpus::ContractError, 'execution identity index stage/reference is malformed' unless stage_id.is_a?(String) &&
        reference.is_a?(Hash) && reference.keys.sort == %w[path sha256]
      receipt = GoFullExecutionIdentity.load!(reference.fetch('path'), expected_sha256: reference.fetch('sha256'))
      raise Corpus::ContractError, 'execution identity index stage differs from receipt' unless receipt.values_at('root_id', 'stage_id') == [root_id, stage_id]
    end
    unless index.fetch('entries').keys.sort == expected_stage_ids.sort && expected_stage_ids.uniq.length == expected_stage_ids.length
      raise Corpus::ContractError, 'execution identity index stage set differs from deterministic plan'
    end
    [index.fetch('entries'), record]
  rescue JSON::ParserError => error
    raise Corpus::ContractError, "invalid execution identity index: #{error.message}"
  end

  def packet_rows_pass?(rows)
    rows.is_a?(Array) && !rows.empty? && rows.all? { |row| row['product_verdict'] == 'PASS' }
  end

  def execution_setup(options, evidence, candidate, sdk_identity)
    sdk = { 'sha256' => sdk_identity.fetch('go').fetch('sha256'),
            'identity' => "go version #{sdk_identity.fetch('release')} #{sdk_identity.fetch('goos')}/#{sdk_identity.fetch('goarch')}" }
    raise Corpus::ContractError, 'full product execution requires --module-context' unless options[:module_context]
    module_context = GoFullModuleContext.load(options.fetch(:module_context), candidate_path: options.fetch(:candidate), sdk_path: options.fetch(:sdk_identity),
      cache_root: options[:cache_root], bashy: options.fetch(:bashy), expected_sha256: options.fetch(:module_context_sha256, GoFullModuleContext::REVIEWED_SHA256))
    module_files = module_context.fetch('module_files')
    if options[:modules]
      raise Corpus::ContractError, '--modules differs from authenticated scaffold' unless JSON.parse(File.read(options[:modules])) == module_files
    end
    execution_environment = { 'PATH' => ENV.fetch('PATH', ''), 'LC_ALL' => 'C', 'TZ' => 'UTC', 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'BASHY_HINTS' => 'off', 'GOROOT' => sdk_identity.fetch('root'), 'GOMAXPROCS' => '2' }.merge(module_context.fetch('environment'))
    go = File.join(sdk_identity.fetch('root'), 'bin/go')
    executor = Corpus::Executor.new(bashy: options.fetch(:bashy), go: go, evidence_root: File.join(evidence, 'executions'), candidate: candidate,
      sdk: sdk, timeout: options.fetch(:timeout), env: execution_environment, cache_root: module_context.fetch('cache_root'))
    { executor: executor, module_context: module_context, runtime: { 'base_environment' => execution_environment, 'cache_path' => executor.provenance.fetch('cache').fetch('path'), 'module_files' => module_files, 'module_context' => module_context.fetch('proof') } }
  end

  # Selection follows complete inventory authentication and native event joins.
  # It changes only the diagnostic work selected, never the full denominator.
  def phase_roots(roots, selection)
    return roots unless selection
    selected, expected = case selection
                         when 'negative'
                           [roots.select { |root| root['axis'] == 'testdir' && diagnostic_recipe?(root) }, 521]
                         when 'typechecker'
                           [roots.select { |root| root['axis'] == 'typechecker' }, 743]
                         else
                           raise Corpus::ContractError, 'unknown phase shard'
                         end
    ids = selected.map { |root| root.fetch('id') }
    raise Corpus::ContractError, "#{selection} shard denominator drift" unless selected.length == expected && ids.uniq.length == expected
    selected
  end

  def execute(options)
    options = options.merge(bashy: File.realpath(options.fetch(:bashy)))
    dir = File.expand_path(options.fetch(:inventory))
    source_root = File.realpath(options.fetch(:source_root))
    evidence = File.expand_path(options.fetch(:evidence))
    raise Corpus::ContractError, 'evidence root already exists' if File.exist?(evidence)
    native_dir = File.expand_path(options.fetch(:native))
    native_summary = JSON.parse(File.read(File.join(native_dir, 'summary.json')))
    raise Corpus::ContractError, 'requires retained native-only oracle evidence' unless native_summary['schema'] == 'go-full-native/v1' && native_summary['product_execution_claim'] == false
    native = unique_rows(File.join(native_dir, 'roots.jsonl'))
    expected_native_count = native_summary.fetch('counts_by_axis').values.sum { |counts| counts.values.sum }
    raise Corpus::ContractError, 'native root duplicates/denominator mismatch' unless native.size == expected_native_count
    log = native_summary.fetch('native_stage').fetch('stdout')
    Corpus::Validation.file!(log)
    Corpus::Validation.file!(native_summary.fetch('native_stage').fetch('stderr'))
    native_events = GoFull::NativeEvents.new
    File.foreach(log.fetch('path')) { |line| native_events.consume(line) }
    candidate = JSON.parse(File.read(options.fetch(:candidate)))
    sdk_identity = JSON.parse(File.read(options.fetch(:sdk_identity)))
    sdk_authentication = verify_sdk_identity(native_summary.fetch('sdk'), sdk_identity, options[:relocation], relocation_sha256: options.fetch(:relocation_sha256, GoFullAuthentication::REVIEWED_RELOCATION_SHA256))
    setup = execution_setup(options, evidence, candidate, sdk_identity)
    executor = setup.fetch(:executor)
    module_context = setup.fetch(:module_context)
    module_files = module_context.fetch('module_files')
    execution_environment = setup.fetch(:runtime).fetch('base_environment')
    options = options.merge(runtime: setup.fetch(:runtime))
    # The archive-backed source/inventory validator is the independent input
    # gate. No expected input set is derived from an execution result.
    _out, err, status = Open3.capture3('python3', File.join(__dir__, 'inventory.py'), 'validate', '--archive', sdk_identity.fetch('source_archive').fetch('path'),
                                    '--source-root', source_root, '--output', dir)
    raise Corpus::ContractError, "immutable input validation failed: #{err}" unless status.success?
    native_summary.fetch('inventory').each do |name, record|
      raise Corpus::ContractError, "native/product inventory mismatch: #{name}" unless Corpus.digest(File.join(dir, name)) == record.fetch('sha256')
    end
    catalog = JSON.parse(File.read(File.join(dir, 'action-catalog.json'))).to_h { |r| [r.fetch('action'), r] }
    rows = []
    roots = read_rows(File.join(dir, 'testdir-roots.jsonl')).map { |r| r.merge('axis' => 'testdir') }
    roots.concat(read_rows(File.join(dir, 'typechecker-roots.jsonl')).map { |r| r.merge('axis' => 'typechecker') })
    roots.concat(read_rows(File.join(dir, 'package-roots.jsonl')).map { |r| r.merge('axis' => 'package') })
    raise Corpus::ContractError, 'native root IDs differ from independent complete inventory' unless roots.map { |r| r.fetch('id') }.sort == native.keys.sort
    roots.each do |root|
      package, test = case root.fetch('axis')
                      when 'testdir' then ['cmd/internal/testdir', root.fetch('upstream_subtest')]
                      when 'typechecker' then root.fetch('id').split(':', 2)
                      else [root.fetch('package'), nil]
                      end
      raise Corpus::ContractError, 'native observation differs from retained event log: ' + root.fetch('id') unless native.fetch(root.fetch('id')).fetch('observation') == native_events.observation(package, test)
    end
    full_manifest_denominators = roots.group_by { |root| root.fetch('axis') }.transform_values(&:length)
    all_roots = roots.to_h { |root| [root.fetch('id'), root] }
    checkpoint = GoFullResume.context(roots: roots, inventory: native_summary.fetch('inventory').transform_values { |record| record.fetch('sha256') },
      sdk: sdk_identity, provenance: executor.provenance, modules: module_files, timeout: options.fetch(:timeout),
      environment: execution_environment, module_context: module_context.fetch('proof'),
      native: { 'summary' => Corpus.file_record(File.join(native_dir, 'summary.json')), 'roots' => Corpus.file_record(File.join(native_dir, 'roots.jsonl')), 'stdout' => log, 'stderr' => native_summary.fetch('native_stage').fetch('stderr') })
    resumed = options[:resume] ? GoFullResume.load(options[:resume], context: checkpoint, roots: all_roots, source_root: source_root,
      provenance: executor.provenance, modules: module_files, native: native, catalog: catalog) : { 'reusable' => {}, 'fresh' => {}, 'checkpoint_roots' => 0 }

    packet_selection = if options[:packet_projection]
                         raise Corpus::ContractError, 'packet execution cannot reuse a prior resume' if options[:resume]
                         raise Corpus::ContractError, 'packet execution cannot be combined with a phase shard' if options[:phase_shard]
                         required = %i[packet packet_index packet_index_sha256 causal_partition packet_projection_sha256]
                         missing = required.reject { |key| options[key] }
                         raise Corpus::ContractError, "packet execution inputs missing: #{missing.join(', ')}" unless missing.empty?
                         raise Corpus::ContractError, 'only Sprint 148 anchor packets may use this integration path' unless PACKET_MANIFEST_SHA256.key?(options[:packet])
                         packet_catalog = GoFullPacketManifest.authenticate_index(path: options.fetch(:packet_index),
                           expected_sha256: options.fetch(:packet_index_sha256), causal_partition_path: options.fetch(:causal_partition))
                         selected = GoFullPacketManifest.select(packet_catalog, options.fetch(:packet), roots,
                           expected_manifest_sha256: PACKET_MANIFEST_SHA256.fetch(options.fetch(:packet)))
                         inventory_paths = %w[summary.json package-roots.jsonl testdir-roots.jsonl typechecker-roots.jsonl]
                                           .map { |name| File.join(dir, name) }
                         runner_paths = [__FILE__, File.join(__dir__, 'packet_manifest.rb'), File.join(__dir__, 'router.rb'),
                                         File.join(__dir__, 'stage_resolver.rb'), File.expand_path('../corpus/executor.rb', __dir__),
                                         File.expand_path('../corpus/process_lineage.rb', __dir__)]
                         GoFullPacketManifest.authenticate_projection(path: options.fetch(:packet_projection),
                           expected_sha256: options.fetch(:packet_projection_sha256), selection: selected,
                           inventory_paths: inventory_paths, runner_paths: runner_paths,
                           candidate_path: options.fetch(:candidate), evidence: evidence,
                           protected_roots: options.fetch(:protected_evidence_roots, []))
                       end
    identity_receipts = identity_index_record = nil
    if packet_selection
      raise Corpus::ContractError, 'packet execution requires --execution-identity-index and digest' unless options[:execution_identity_index] && options[:execution_identity_index_sha256]
      selected_id = packet_selection.fetch('ids').then { |ids| ids.length == 1 ? ids.first : nil }
      raise Corpus::ContractError, 'substrate packet path requires exactly one selected root' unless selected_id
      identity_receipts, identity_index_record = load_identity_index(options.fetch(:execution_identity_index),
        options.fetch(:execution_identity_index_sha256), selected_id,
        expected_stage_ids: anchor_stage_ids(options.fetch(:packet), selected_id))
    end
    subset = if options[:root_subset]
               raise Corpus::ContractError, 'packet projection cannot be combined with root subset' if packet_selection
               raise Corpus::ContractError, '--root-subset cannot be combined with --phase-shard' if options[:phase_shard]
               GoFullSubset.load(path: options.fetch(:root_subset), expected_sha256: options[:root_subset_sha256], roots: roots,
                 inventory: native_summary.fetch('inventory'), candidate_path: options.fetch(:candidate), runner_paths: [__FILE__, File.join(__dir__, 'subset.rb'), *GoFullRecipeAdapters.runner_paths(__dir__)], evidence: evidence,
                 protected_roots: options.fetch(:protected_evidence_roots, []))
             end
    roots = packet_selection ? packet_selection.fetch('roots') : (subset ? subset.fetch('roots') : phase_roots(roots, options[:phase_shard]))
    # Fresh-only adapters from a prior checkpoint must not starve roots that
    # have never been attempted when a manager bounds wall-clock execution.
    roots = roots.sort_by { |root| resumed.fetch('fresh').key?(root.fetch('id')) ? 1 : 0 } unless subset
    FileUtils.mkdir_p(evidence)
    File.write(File.join(evidence, 'context.json'), Corpus.canonical(checkpoint) + "\n", mode: 'wx')
    matcher = packet_selection ? { 'status' => 'not-required-for-exact-output-anchor' } : build_matcher(evidence, sdk_identity, options.fetch(:runtime))
    typecheck_matcher = packet_selection ? { 'status' => 'not-required-for-testdir-anchor' } : GoFullTypechecker.build_matcher(evidence, sdk_identity, options.fetch(:runtime))
    File.open(File.join(evidence, 'roots.jsonl'), 'wx') do |stream|
      roots.each do |root|
        id = root.fetch('id')
        if (retained = resumed.fetch('reusable')[id])
          rows << retained
          stream.write(Corpus.canonical(retained) + "\n")
          stream.flush
          next
        end
        oracle = native.fetch(id).fetch('observation')
        row = { 'schema' => 'go-full-product-root/v1', 'id' => id, 'axis' => root.fetch('axis'),
                'native_observation' => oracle, 'product_verdict' => 'FAIL', 'modes' => {}, 'unfinished_phases' => [] }
        if packet_selection
          raise Corpus::ContractError, 'packet attempted an unselected root' unless packet_selection.fetch('ids') == [id]
          GoFullPacketManifest.reauthenticate!(packet_selection)
          row['packet_receipt'] = { 'packet' => packet_selection.fetch('packet'),
                                    'projection' => packet_selection.fetch('projection'),
                                    'manifest' => packet_selection.fetch('manifest'),
                                    'index' => packet_selection.fetch('index'),
                                    'claim_scope' => GoFullPacketManifest::CLAIM_SCOPE }
          row['execution_identity_index'] = identity_index_record
        end
        if %w[skip ancestor-skip].include?(oracle.fetch('status'))
          row['product_verdict'] = 'UPSTREAM_SKIP'
          row['reason'] = 'Retained native skip requires manager applicability adjudication; no product execution credited.'
        elsif root['axis'] == 'testdir' && anchor_root?(root)
          begin
            record, substrate = execute_anchor(root, executor, source_root, module_files, oracle,
                                                identity_receipts: identity_receipts)
            authenticate_execution_lineage!(record, id)
            row['fresh_reauthentication'] = fresh_reauthenticate_execution!(record, identity_receipts) if packet_selection
            Corpus::Validation.file!(identity_index_record) if packet_selection
            row['execution'] = record
            row['substrate'] = substrate
            row['upstream_output'] = exact_upstream_output(record, root, source_root)
            executions = record.fetch('ordered_repetitions', [record])
            resolutions = executions.flat_map { |execution| execution.fetch('modes').values.flat_map { |mode| mode.fetch('stages') } }.map do |stage|
              role = %w[compile build run check].include?(stage.fetch('stage')) ? stage.fetch('stage') : 'execute'
              GoFullStageResolver.adjudicate!(root_id: id, stage_id: stage.dig('lineage', 'stage_id'), decision: 'execute',
                native_observation: oracle.slice('status', 'evidence_kind'), stage_role: role, stage: stage)
            end
            row['stage_resolutions'] = resolutions
            row['product_verdict'] = executions.all? { |execution| execution['verdict'] == 'PASS' } && resolutions.all? { |value| value['verdict'] == 'PASS' } &&
                                     oracle['status'] == 'pass' && row.dig('upstream_output', 'status') == 'PASS' ? 'PASS' : 'FAIL'
          rescue Corpus::ContractError, SystemCallError => error
            row['reason'] = error.message
          end
        elsif root['axis'] == 'testdir' && simple_recipe?(root)
          begin
            action = root.fetch('recipe').fetch('action')
            phase = %w[build compile].include?(action) ? action : 'run'
            record = executor.execute(id: id, source_root: source_root, sources: [root.fetch('path')], phase: phase,
                                      args: root.fetch('recipe').fetch('args'), module_files: module_files)
            row['execution'] = record
            row['upstream_output'] = exact_upstream_output(record, root, source_root)
            row['product_verdict'] = record['verdict'] == 'PASS' && oracle['status'] == 'pass' && %w[PASS not-consumed].include?(row.dig('upstream_output', 'status')) ? 'PASS' : 'FAIL'
          rescue Corpus::ContractError, SystemCallError => error
            row['reason'] = error.message
          end
        elsif root['axis'] == 'testdir' && generator_recipe?(root)
          begin
            row['generated_evidence'] = execute_generator(root, executor, source_root, module_files, evidence)
            row['product_verdict'] = oracle['status'] == 'pass' && row['generated_evidence']['verdict'] == 'PASS' ? 'PASS' : 'FAIL'
          rescue Corpus::ContractError, SystemCallError => error
            row['reason'] = error.message
          end
        elsif root['axis'] == 'testdir' && diagnostic_recipe?(root)
          begin
            observed = probe(root, options, source_root, evidence, sdk_identity, candidate)
            row['modes'] = match_diagnostics(root, observed, matcher, evidence, options.fetch(:timeout))
            row['product_verdict'] = oracle['status'] == 'pass' && row['modes'].values.all? { |mode| mode['verdict'] == 'PASS' } ? 'PASS' : 'FAIL'
          rescue Corpus::ContractError, SystemCallError => error
            row['reason'] = error.message
          end
        elsif root['axis'] == 'testdir' && GoFullRecipeAdapters.eligible?(root)
          begin
            row.merge!(GoFullRecipeAdapters.dispatch(root: root, context: {
              source_root: source_root, evidence: evidence, executor: executor, module_files: module_files,
              options: options, sdk_identity: sdk_identity, candidate: candidate, native_observation: oracle
            }))
          rescue Corpus::ContractError, SystemCallError => error
            row['reason'] = error.message
          end
        elsif root['axis'] == 'typechecker' && GoFullTypechecker.adaptable?(root, source_root)
          begin
            checked = GoFullTypechecker.execute(root: root, options: options, source_root: source_root, evidence: evidence,
                                                sdk_identity: sdk_identity, candidate: candidate, matcher: typecheck_matcher)
            row['modes'] = checked.fetch('modes')
            row['typechecker_evidence'] = checked.fetch('evidence')
            row['product_verdict'] = oracle['status'] == 'pass' && checked['verdict'] == 'PASS' ? 'PASS' : 'FAIL'
          rescue Corpus::ContractError, SystemCallError => error
            row['reason'] = error.message
          end
        else
          # No success by relabeling a parse probe as errorcheck, asmcheck,
          # directory execution, generated execution, or a testing harness.
          row['reason'] = 'Exact product recipe adapter is not implemented; diagnostic probes cannot complete its phases.'
          if root['axis'] == 'typechecker'
            row['unsupported_recipe_options'] = GoFullTypechecker.unsupported_options(root, source_root)
            row['reason'] = 'Exact check-harness recipe options are not implemented: ' + row['unsupported_recipe_options'].join(', ') + '. Both obligations remain unexecuted.'
          end
          row['unfinished_phases'] = if root['axis'] == 'testdir'
                                       catalog.fetch(root.fetch('recipe').fetch('action'), { 'phase_contract' => ['resolve-build-ignore-before-action'] }).fetch('phase_contract')
                                     elsif root['axis'] == 'typechecker'
                                       %w[check-original-fixture match-source-positioned-diagnostics]
                                     else
                                       %w[build-test-harness enumerate-runtime-tests execute-product-test-bodies join-all-runtime-results]
                                     end
          row['modes'] = probe(root, options, source_root, evidence, sdk_identity, candidate)
        end
        row = GoFullResume.seal(row, root: root, source_root: source_root, context: checkpoint, provenance: executor.provenance, evidence: evidence)
        rows << row
        stream.write(Corpus.canonical(row) + "\n")
        stream.flush
      end
    end
    _out, err, integrity_status = Open3.capture3('python3', File.join(__dir__, 'inventory.py'), 'validate', '--archive', sdk_identity.fetch('source_archive').fetch('path'),
                                               '--source-root', source_root, '--output', dir)
    counts = rows.group_by { |r| r['axis'] }.transform_values { |group| group.group_by { |r| r['product_verdict'] }.transform_values(&:length) }
    module_integrity_after = GoFullModuleContext.load(options.fetch(:module_context), candidate_path: options.fetch(:candidate), sdk_path: options.fetch(:sdk_identity), cache_root: options[:cache_root], bashy: options.fetch(:bashy), expected_sha256: options.fetch(:module_context_sha256, GoFullModuleContext::REVIEWED_SHA256)).fetch('proof') == module_context.fetch('proof')
    common_summary = {
                'checkpoint' => Corpus.file_record(File.join(evidence, 'context.json')), 'sdk_authentication' => sdk_authentication, 'module_context' => module_context.fetch('proof'), 'module_integrity_after' => module_integrity_after,
                'resume' => { 'attempt_order' => 'unattempted and authenticated terminals before prior fresh-required adapters; complete selected denominator retained', 'checkpoint_roots' => resumed['checkpoint_roots'], 'reused_roots' => rows.count { |row| resumed['reusable'].key?(row['id']) }, 'fresh_required' => resumed['fresh'] },
                'typechecker_adapter' => { 'schema' => 'go-full-typechecker-adapter/v1', 'matcher' => typecheck_matcher,
                                           'phases' => GoFullTypechecker::PHASES, 'checking_modes' => GoFullTypechecker::MODES,
                                           'root_denominator' => full_manifest_denominators.fetch('typechecker', 0),
                                           'adapted' => rows.count { |row| row.key?('typechecker_evidence') },
                                           'unsupported_recipe_options' => rows.count { |row| row.key?('unsupported_recipe_options') },
                                           'claim_scope' => 'per-root check obligations only; no whole-axis or whole-corpus PASS is claimed' },
                'provenance' => executor.provenance, 'diagnostic_matcher' => matcher, 'source_integrity_after' => integrity_status.success?, 'source_integrity_error' => err,
                'native_summary' => Corpus.file_record(File.join(native_dir, 'summary.json')),
                'native_roots' => Corpus.file_record(File.join(native_dir, 'roots.jsonl')) }
    summary = if packet_selection
                GoFullPacketManifest.summary(packet_selection, rows, common_summary)
              elsif subset
                common_summary.fetch('typechecker_adapter').delete('root_denominator')
                common_summary.fetch('typechecker_adapter')['selected_root_count'] = rows.count { |row| row['axis'] == 'typechecker' }
                GoFullSubset.summary(subset, rows, common_summary)
              else
              { 'schema' => 'go-full-product/v1', 'counts_by_axis' => counts, 'roots' => roots.length,
                'scope' => options[:phase_shard] ? "#{options[:phase_shard]}-phase-discovery-shard" : 'full-root-accounting',
                'full_manifest_denominators' => full_manifest_denominators, 'selected_root_denominator' => roots.length,
                'selection_rule' => options[:phase_shard] == 'typechecker' ? 'all 743 independent typechecker roots, including unsupported recipes and upstream skips' : (options[:phase_shard] ? 'all unflagged negative errorcheck/errorcheckwithauto roots without expected-failure inversion' : 'all independent static axes'),
                **common_summary,
                'all_runtime_tests_covered' => false, 'nested_process_instrumentation_complete' => false,
                'generated_program_denominator_complete' => false,
                'verdict' => 'FAIL', 'reason' => 'Sprint closure requires every phase, dynamic test, nested-tool and applicability obligation to be independently verified.' }
              end
    File.write(File.join(evidence, 'summary.json'), Corpus.canonical(summary) + "\n")
    puts JSON.generate(summary.slice('schema', 'scope', 'verdict', 'counts_by_axis', 'roots', 'selected_root_count', 'source_integrity_after'))
    if packet_selection
      packet_rows_pass?(rows) ? 0 : 1
    elsif subset
      rows.any? { |row| row['product_verdict'] == 'FAIL' } ? 1 : 0
    else
      1
    end
  end

  def probe(root, options, source_root, evidence, sdk_identity, candidate)
    inputs = root['input_files'] || root.fetch('source_files')
    selector = if root['axis'] == 'package'
                 'src/' + root.fetch('package')
               elsif root['directory']
                 root.fetch('directory').fetch('path')
               else
                 root.fetch('path')
               end
    %w[interpreted compiled].to_h do |mode|
      directory = Corpus.safe_path(File.join(evidence, 'probes'), root.fetch('id') + '/' + mode)
      work = File.join(directory, 'work')
      FileUtils.mkdir_p(work)
      before = inputs.to_h do |relative|
        original = Corpus.safe_path(source_root, relative)
        copy = Corpus.safe_path(work, relative)
        FileUtils.mkdir_p(File.dirname(copy)); FileUtils.cp(original, copy)
        [relative, Corpus.file_record(original)]
      end
      scaffold = options[:runtime] ? options[:runtime].fetch('module_files') : {}
      raise Corpus::ContractError, 'scaffold overlaps original probe input' unless (scaffold.keys & before.keys).empty?
      scaffold.each { |name, bytes| File.binwrite(Corpus.safe_path(work, name), bytes) }
      generated = File.join(directory, 'generated.go')
      argv = if mode == 'interpreted'
               [options.fetch(:bashy), '--bashpp', '--source=go', '--check', selector]
             else
               [options.fetch(:bashy), 'transpile', '--bashpp', '--source=go', selector, '-o', generated, '--map', generated + '.map']
             end
      env = { 'PATH' => '/usr/bin:/bin', 'GOROOT' => sdk_identity.fetch('root'), 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'GOENV' => 'off',
              'HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => File.join(directory, 'gocache'), 'GOMAXPROCS' => '2', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'BASHY_HINTS' => 'off' }
      env = stage_environment(options.fetch(:runtime), directory) if options[:runtime]
      %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(env.fetch(key)) }
      Corpus.authenticate_file(options.fetch(:bashy), candidate.fetch('launcher_sha256'))
      Corpus.authenticate_file(options.fetch(:bashy) + '.real', candidate.fetch('payload_sha256'))
      stage = Corpus.capture(argv, cwd: work, log_prefix: File.join(directory, 'probe'), env: env, timeout: options.fetch(:timeout))
      intact = before.all? { |relative, data| Corpus.digest(File.join(work, relative)) == data.fetch('sha256') && Corpus.digest(data.fetch('path')) == data.fetch('sha256') }
      intact &&= scaffold.all? { |name, bytes| File.binread(Corpus.safe_path(work, name)) == bytes }
      [mode, { 'module_files' => scaffold.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }, 'verdict' => 'FAIL', 'stage_role' => 'diagnostic-probe-only', 'stage' => stage,
               'input_integrity' => intact, 'inputs' => before, 'reason' => 'Required recipe phases remain unexecuted regardless of probe exit.' }]
    end
  rescue Corpus::ContractError, SystemCallError => error
    %w[interpreted compiled].to_h { |mode| [mode, { 'verdict' => 'FAIL', 'reason' => error.message }] }
  end
end

GoFullRecipeAdapters.load_directory(__dir__)

if $PROGRAM_NAME == __FILE__
  options = { inventory: File.expand_path('../../docs/go-full', __dir__), timeout: 60 }
  OptionParser.new do |parser|
    %i[bashy candidate sdk_identity source_root evidence native inventory modules relocation resume module_context cache_root root_subset
       packet_index causal_partition packet_projection execution_identity_index].each do |key|
      parser.on("--#{key.to_s.tr('_', '-')} PATH") { |value| options[key] = File.expand_path(value) }
    end
    parser.on('--relocation-sha256 SHA256') { |value| options[:relocation_sha256] = value }
    parser.on('--module-context-sha256 SHA256') { |value| options[:module_context_sha256] = value }
    parser.on('--phase-shard NAME') { |value| options[:phase_shard] = value }
    parser.on('--root-subset-sha256 SHA256') { |value| options[:root_subset_sha256] = value }
    parser.on('--packet NAME') { |value| options[:packet] = value }
    parser.on('--packet-index-sha256 SHA256') { |value| options[:packet_index_sha256] = value }
    parser.on('--packet-projection-sha256 SHA256') { |value| options[:packet_projection_sha256] = value }
    parser.on('--execution-identity-index-sha256 SHA256') { |value| options[:execution_identity_index_sha256] = value }
    parser.on('--protected-evidence-root PATH') { |value| (options[:protected_evidence_roots] ||= []) << File.expand_path(value) }
    parser.on('--timeout N', Integer) { |value| options[:timeout] = value }
  end.parse!
  begin
    raise Corpus::ContractError, 'positive timeout required' unless options[:timeout].positive?
    exit GoFullProduct.execute(options)
  rescue KeyError, Corpus::ContractError, JSON::ParserError, SystemCallError => error
    warn "FATAL: #{error.message}"
    exit 2
  end
end
