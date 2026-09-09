# frozen_string_literal: true
# Sprint: #118; Story-ID: 3abd77da923c
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

module GoFullProduct
  module_function

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
    %w[run build buildrun].include?(recipe['action']) && recipe.fetch('flags', []).empty? &&
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
    generator = executor.execute(id: root.fetch('id') + ':generator', source_root: source_root, sources: [root.fetch('path')],
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
      raise Corpus::ContractError, 'generated source differs from its mode-specific emitter stream' unless child['generated_source']['sha256'] == child['emitter_stream']['sha256']
      execution = executor.execute(id: root.fetch('id') + ':generated-by-' + mode, source_root: generated_root, sources: ['tmp__.go'],
                                   phase: 'run', module_files: module_files)
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
    observations = record.fetch('modes').values.to_h do |mode|
      stage = mode.fetch('stages').find { |s| s['stage'] == 'run' }
      return { 'status' => 'FAIL', 'reason' => 'run stage absent or unsuccessful' } unless stage && Corpus.success?(stage)
      out = File.binread(stage.fetch('stdout').fetch('path'))
      err = File.binread(stage.fetch('stderr').fetch('path'))
      # Upstream combines both streams into one buffer. With two nonempty
      # streams, independent logs cannot recover their original interleaving.
      return { 'status' => 'FAIL', 'reason' => 'combined-stream ordering requires capture adapter' } unless out.empty? || err.empty?
      [mode.fetch('mode'), out + err]
    end
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

    roots = phase_roots(roots, options[:phase_shard])
    # Fresh-only adapters from a prior checkpoint must not starve roots that
    # have never been attempted when a manager bounds wall-clock execution.
    roots = roots.sort_by { |root| resumed.fetch('fresh').key?(root.fetch('id')) ? 1 : 0 }
    FileUtils.mkdir_p(evidence)
    File.write(File.join(evidence, 'context.json'), Corpus.canonical(checkpoint) + "\n", mode: 'wx')
    matcher = build_matcher(evidence, sdk_identity, options.fetch(:runtime))
    typecheck_matcher = GoFullTypechecker.build_matcher(evidence, sdk_identity, options.fetch(:runtime))
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
        if %w[skip ancestor-skip].include?(oracle.fetch('status'))
          row['product_verdict'] = 'UPSTREAM_SKIP'
          row['reason'] = 'Retained native skip requires manager applicability adjudication; no product execution credited.'
        elsif root['axis'] == 'testdir' && simple_recipe?(root)
          begin
            phase = root.fetch('recipe').fetch('action') == 'build' ? 'build' : 'run'
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
    summary = { 'schema' => 'go-full-product/v1', 'counts_by_axis' => counts, 'roots' => roots.length,
                'scope' => options[:phase_shard] ? "#{options[:phase_shard]}-phase-discovery-shard" : 'full-root-accounting',
                'full_manifest_denominators' => full_manifest_denominators, 'selected_root_denominator' => roots.length,
                'selection_rule' => options[:phase_shard] == 'typechecker' ? 'all 743 independent typechecker roots, including unsupported recipes and upstream skips' : (options[:phase_shard] ? 'all unflagged negative errorcheck/errorcheckwithauto roots without expected-failure inversion' : 'all independent static axes'),
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
                'native_roots' => Corpus.file_record(File.join(native_dir, 'roots.jsonl')),
                'all_runtime_tests_covered' => false, 'nested_process_instrumentation_complete' => false,
                'generated_program_denominator_complete' => false,
                'verdict' => 'FAIL', 'reason' => 'Sprint closure requires every phase, dynamic test, nested-tool and applicability obligation to be independently verified.' }
    File.write(File.join(evidence, 'summary.json'), Corpus.canonical(summary) + "\n")
    puts JSON.generate(summary.slice('verdict', 'counts_by_axis', 'roots', 'source_integrity_after'))
    1
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

if $PROGRAM_NAME == __FILE__
  options = { inventory: File.expand_path('../../docs/go-full', __dir__), timeout: 60 }
  OptionParser.new do |parser|
    %i[bashy candidate sdk_identity source_root evidence native inventory modules relocation resume module_context cache_root].each do |key|
      parser.on("--#{key.to_s.tr('_', '-')} PATH") { |value| options[key] = File.expand_path(value) }
    end
    parser.on('--relocation-sha256 SHA256') { |value| options[:relocation_sha256] = value }
    parser.on('--module-context-sha256 SHA256') { |value| options[:module_context_sha256] = value }
    parser.on('--phase-shard NAME') { |value| options[:phase_shard] = value }
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
