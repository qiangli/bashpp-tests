# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
require_relative '../corpus/validate'

module GoFullResume
  module_function
  ROOT_SCHEMA = 'go-full-product-root/v2'
  CONTEXT_SCHEMA = 'go-full-checkpoint/v1'

  def sha(value)
    Digest::SHA256.hexdigest(Corpus.canonical(value))
  end
  def stable_provenance(value)
    copy = Marshal.load(Marshal.dump(value)); copy.fetch('cache').delete('path'); copy
  end

  def context(roots:, inventory:, sdk:, provenance:, native:, modules:, timeout:, environment:)
    raise Corpus::ContractError, 'duplicate context root IDs' unless roots.map { |root| root.fetch('id') }.uniq.length == roots.length
    { 'schema' => CONTEXT_SCHEMA, 'roots' => roots.to_h { |root| [root.fetch('id'), sha(root)] },
      'inventory' => inventory, 'sdk' => sdk, 'provenance' => stable_provenance(provenance),
      'native' => native, 'modules' => modules.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
      'timeout' => timeout, 'execution_environment' => environment,
      'tools' => Dir[File.join(__dir__, '*.{rb,py}'), File.join(__dir__, 'diagnostics/*'), File.join(__dir__, 'typecheck-diagnostics/*'), File.join(__dir__, '../corpus/*.rb')].select { |path| File.file?(path) }.sort.to_h { |path| [path.delete_prefix(__dir__ + '/'), Corpus.digest(path)] } }
  end

  def inputs(root, source_root)
    paths = root['input_files'] || root.fetch('source_files')
    paths.to_h { |path| [path, Corpus.file_record(Corpus.safe_path(source_root, path))] }
  end

  def seal(row, root:, source_root:, context:, provenance:, evidence:)
    row = row.merge('schema' => ROOT_SCHEMA, 'context_sha256' => sha(context), 'root_sha256' => sha(root),
                    'provenance' => provenance, 'retained_inputs' => inputs(root, source_root), 'attempt_state' => 'terminal')
    file = Corpus.safe_path(File.join(evidence, 'root-records'), root.fetch('id') + '.json')
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, Corpus.canonical(row) + "\n", mode: 'wx')
    row.merge('retained_record' => Corpus.file_record(file))
  end

  def files!(value)
    case value
    when Hash
      Corpus::Validation.file!(value) if value.key?('path') && value.key?('bytes') && value.key?('sha256')
      value.each_value { |child| files!(child) }
    when Array then value.each { |child| files!(child) }
    end
  end

  def unique_streams!(value, seen = {})
    if value.is_a?(Hash)
      if value.key?('argv') && value.key?('stdout') && value.key?('stderr')
        %w[stdout stderr].each do |key|
          path = File.realpath(value.fetch(key).fetch('path'))
          raise Corpus::ContractError, 'duplicate retained capture stream' if seen[path]
          seen[path] = true
        end
      end
      value.each_value { |child| unique_streams!(child, seen) }
    elsif value.is_a?(Array)
      value.each { |child| unique_streams!(child, seen) }
    end
  end

  def stage!(stage, argv:, cwd:, source_root:, provenance:)
    raise Corpus::ContractError, 'capture command/cwd differs' unless stage.fetch('argv') == argv && stage.fetch('cwd') == cwd
    environment = stage.fetch('environment')
    raise Corpus::ContractError, 'capture SDK/toolchain differs' unless environment['GOROOT'] == source_root && environment['GOTOOLCHAIN'] == 'local'
    raise Corpus::ContractError, 'incomplete capture terminal' unless %w[exited deadline process_leak launch_failure].include?(stage.fetch('state')) && [true, false].include?(stage.fetch('spawned')) && stage.key?('exit') && stage.key?('signal') && stage.fetch('duration_seconds').is_a?(Numeric)
    %w[stdout stderr].each { |key| Corpus::Validation.file!(stage.fetch(key)) }
    raise Corpus::ContractError, 'stream paths reused' if File.realpath(stage.fetch('stdout').fetch('path')) == File.realpath(stage.fetch('stderr').fetch('path'))
    if stage['spawned'] && stage['state'] == 'exited'
      raise Corpus::ContractError, 'exited capture lacks process result' unless stage['exit'].is_a?(Integer) || stage['signal'].is_a?(Integer)
    end
    Corpus::Validation.file!(provenance.fetch('candidate').fetch('launcher'))
    Corpus::Validation.file!(provenance.fetch('candidate').fetch('payload'))
    Corpus::Validation.file!(provenance.fetch('sdk').fetch('binary'))
  end

  def copies!(directory, expected)
    expected.each do |relative, record|
      path = Corpus.safe_path(directory, relative)
      raise Corpus::ContractError, 'retained copied source differs' unless Corpus.digest(path) == record.fetch('sha256') && File.size(path) == record.fetch('bytes')
    end
  end

  # Authenticate complete process attempts, including a justified failing prefix.
  # A prefix never acquires PASS: later unexecuted phases remain failures.
  def execution!(record, root:, source_root:, provenance:, modules:, environment:)
    expected = { 'phase' => root.fetch('recipe').fetch('action') == 'build' ? 'build' : 'run',
      'sources' => [root.fetch('path')], 'assets' => [], 'inputs' => [root.fetch('path')].to_h { |p| [p, Corpus.file_record(Corpus.safe_path(source_root, p))] },
      'args' => root.fetch('recipe').fetch('args'), 'module_files' => modules.transform_values { |b| Digest::SHA256.hexdigest(b) }, 'package_input' => nil, 'runtime_environment' => {} }
    raise Corpus::ContractError, 'execution identity/provenance differs' unless record['schema'] == Corpus::SCHEMA && record['id'] == root['id'] && record['provenance'] == provenance
    expected.each { |key, value| raise Corpus::ContractError, "execution obligation differs: #{key}" unless record[key] == value }
    files!(record)
    raise Corpus::ContractError, 'unknown execution verdict' unless %w[PASS FAIL].include?(record['verdict'])
    modes = record.fetch('modes')
    raise Corpus::ContractError, 'incomplete execution modes' unless modes.keys.sort == Corpus::MODES.sort
    modes.each do |mode, result|
      raise Corpus::ContractError, 'mode identity/source integrity differs' unless result['mode'] == mode && result['phase'] == expected['phase'] && result['input_integrity'] == true
      wanted = mode == 'baseline' ? ['build'] : mode == 'compiled' ? %w[transpile build] : [expected['phase'] == 'run' ? 'run' : 'check']
      wanted += ['run'] if expected['phase'] == 'run' && mode != 'interpreted'
      stages = result.fetch('stages')
      actual = stages.map { |stage| stage.fetch('stage') }
      raise Corpus::ContractError, 'missing/extra/reordered execution phases' if actual.empty? || wanted.first(actual.length) != actual
      return false unless %w[complete stage_failure].include?(result['state'])
      if actual != wanted
        raise Corpus::ContractError, 'unjustified missing execution phases' unless result['state'] == 'stage_failure' && !Corpus.success?(stages.last)
      end
      expected_checks = actual.reject { |stage| stage == 'run' && mode != 'interpreted' }.flat_map { |stage| ['before-' + stage, 'after-' + stage] }
      raise Corpus::ContractError, 'missing source phase checks' unless result.fetch('input_checks').map { |c| c['phase'] } == expected_checks && result['input_checks'].all? { |c| c['valid'] == true }
      copied = if mode != 'interpreted' && actual.last == 'run'
                 File.join(File.dirname(result.fetch('artifacts').fetch('native').fetch('path')), 'inputs')
               else result.fetch('source_directory')
               end
      copies!(copied, expected.fetch('inputs'))
      modules.each do |relative, bytes|
        raise Corpus::ContractError, 'retained module input differs' unless File.binread(Corpus.safe_path(copied, relative)) == bytes
      end
      stages.each_with_index do |stage, index|
        raise Corpus::ContractError, 'execution continues after a failed phase' if index < stages.length - 1 && !Corpus.success?(stage)
        input = expected.fetch('sources').first
        argv = case stage.fetch('stage')
               when 'transpile' then [provenance.dig('candidate', 'launcher', 'path'), 'transpile', '--bashpp', '--source=go', input, '-o', File.join(File.dirname(result.fetch('source_directory')), 'artifacts/generated.go'), '--map', File.join(File.dirname(result.fetch('source_directory')), 'artifacts/generated.go.map')]
               when 'build' then [provenance.dig('sdk', 'binary', 'path'), 'build', '-o', File.join(File.dirname(result.fetch('source_directory')), 'artifacts/program'), mode == 'baseline' ? input : File.join(File.dirname(result.fetch('source_directory')), 'artifacts/generated.go')]
               when 'check', 'run'
                 mode == 'interpreted' ? [provenance.dig('candidate', 'launcher', 'path'), '--bashpp', '--source=go', *(stage['stage'] == 'check' ? ['--check'] : []), File.expand_path(input, result.fetch('source_directory')), *expected.fetch('args')] : [result.dig('artifacts', 'native', 'path'), *expected.fetch('args')]
               end
        mode_dir = File.dirname(result.fetch('source_directory'))
        expected_environment = environment.merge('HOME' => File.join(mode_dir, 'home'), 'TMPDIR' => File.join(mode_dir, 'tmp'), 'GOCACHE' => provenance.dig('cache', 'path'))
        expected_environment['PATH'] = File.join(mode_dir, 'empty-path') if stage['stage'] == 'run'
        raise Corpus::ContractError, 'capture environment differs' unless stage.fetch('environment') == expected_environment
        raise Corpus::ContractError, 'capture cache differs' unless stage.fetch('environment')['GOCACHE'] == provenance.dig('cache', 'path')
        if Corpus.success?(stage) && stage['stage'] == 'transpile'
          generated = result.fetch('artifacts').fetch('generated')
          mapping = JSON.parse(File.read(result.fetch('artifacts').fetch('source_map').fetch('path')))
          raise Corpus::ContractError, 'retained source map differs' unless Corpus.valid_source_map?(mapping, generated, expected.fetch('inputs'))
        elsif Corpus.success?(stage) && stage['stage'] == 'build'
          binary = result.fetch('artifacts').fetch('native')
          raise Corpus::ContractError, 'retained native artifact invalid' unless binary.fetch('bytes').positive? && (expected['phase'] == 'build' || Corpus.native_binary?(binary.fetch('path')))
        end
        stage!(stage, argv: argv, cwd: stage['stage'] == 'run' ? result.fetch('runtime_directory') : result.fetch('source_directory'), source_root: File.dirname(File.dirname(provenance.dig('sdk', 'binary', 'path'))), provenance: provenance)
      end
    end
    raise Corpus::ContractError, 'execution verdict differs from phases' unless execution_verdict(record) == record['verdict']
    Corpus::Validation.validate!([record], expected: { root.fetch('id') => expected }, provenance: provenance) if record['verdict'] == 'PASS'
    true
  end

  def execution_verdict(record)
    modes = record.fetch('modes')
    return 'FAIL' unless modes.values.all? { |result| result['state'] == 'complete' && result['input_integrity'] }
    return 'PASS' if record['phase'] == 'build'
    observations = modes.values.map do |result|
      run = result.fetch('stages').last
      return 'FAIL' unless run['stage'] == 'run' && run['state'] == 'exited' && run['spawned'] && run['signal'].nil?
      [run['exit'], run['signal'], run.dig('stdout', 'sha256'), run.dig('stderr', 'sha256'), result.fetch('effects')]
    end
    observations.uniq.length == 1 ? 'PASS' : 'FAIL'
  end

  def probes!(row, root:, source_root:, provenance:)
    modes = row.fetch('modes')
    return false unless modes.keys.sort == %w[compiled interpreted] && modes.values.all? { |m| m.key?('stage') }
    selector = root['axis'] == 'package' ? 'src/' + root.fetch('package') : root['directory'] ? root.fetch('directory').fetch('path') : root.fetch('path')
    expected_inputs = inputs(root, source_root)
    modes.each do |mode, observation|
      raise Corpus::ContractError, 'probe inputs differ' unless observation['input_integrity'] == true && observation.fetch('inputs') == expected_inputs
      stage = observation.fetch('stage'); work = stage.fetch('cwd'); copies!(work, expected_inputs)
      directory = File.dirname(work); generated = File.join(directory, 'generated.go')
      argv = mode == 'interpreted' ? [provenance.dig('candidate', 'launcher', 'path'), '--bashpp', '--source=go', '--check', selector] : [provenance.dig('candidate', 'launcher', 'path'), 'transpile', '--bashpp', '--source=go', selector, '-o', generated, '--map', generated + '.map']
      expected_environment = { 'PATH' => '/usr/bin:/bin', 'GOROOT' => File.dirname(File.dirname(provenance.dig('sdk', 'binary', 'path'))), 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'GOENV' => 'off',
        'HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => File.join(directory, 'gocache'), 'GOMAXPROCS' => '2', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'BASHY_HINTS' => 'off' }
      raise Corpus::ContractError, 'probe environment differs' unless stage.fetch('environment') == expected_environment
      stage!(stage, argv: argv, cwd: work, source_root: File.dirname(File.dirname(provenance.dig('sdk', 'binary', 'path'))), provenance: provenance)
    end
    true
  end

  def load(directory, context:, roots:, source_root:, provenance:, modules:, native:, catalog:)
    checkpoint = JSON.parse(File.read(File.join(directory, 'context.json')))
    raise Corpus::ContractError, 'checkpoint context differs' unless checkpoint == context
    records = File.foreach(File.join(directory, 'roots.jsonl')).map { |line| JSON.parse(line) }
    ids = records.map { |row| row.fetch('id') }
    raise Corpus::ContractError, 'duplicate/foreign resumed IDs' unless ids.uniq == ids && (ids - roots.keys).empty?
    reusable = {}; fresh = {}
    records.each do |row|
      root = roots.fetch(row.fetch('id'))
      raise Corpus::ContractError, 'unauthenticated legacy/incomplete root' unless row['schema'] == ROOT_SCHEMA && row['attempt_state'] == 'terminal' && row['context_sha256'] == sha(context) && row['root_sha256'] == sha(root)
      receipt = row.fetch('retained_record'); Corpus::Validation.file!(receipt)
      raise Corpus::ContractError, 'retained root record differs' unless JSON.parse(File.read(receipt.fetch('path'))) == row.reject { |k, _| k == 'retained_record' }
      raise Corpus::ContractError, 'resumed provenance differs' unless stable_provenance(row.fetch('provenance')) == stable_provenance(provenance)
      raise Corpus::ContractError, 'resumed immutable sources differ' unless row.fetch('retained_inputs') == inputs(root, source_root)
      raise Corpus::ContractError, 'resumed native observation differs' unless row.fetch('native_observation') == native.fetch(root.fetch('id')).fetch('observation')
      files!(row)
      unique_streams!(row)
      eligible = case row.fetch('product_verdict')
                 when 'UPSTREAM_SKIP'
                   raise Corpus::ContractError, 'unbound upstream skip' unless %w[skip ancestor-skip].include?(row.dig('native_observation', 'status')) && row.fetch('modes').empty? && !row.key?('execution') && row['unfinished_phases'] == []
                   true
                 when 'PASS', 'FAIL'
                   if root['axis'] == 'testdir' && GoFullProduct.simple_recipe?(root) && row.key?('execution')
                     raise Corpus::ContractError, 'simple recipe claims unfinished phases' unless row['unfinished_phases'] == []
                     complete = execution!(row.fetch('execution'), root: root, source_root: source_root, provenance: row.fetch('provenance'), modules: modules, environment: context.fetch('execution_environment'))
                     if complete
                       output = GoFullProduct.exact_upstream_output(row.fetch('execution'), root, source_root)
                       expected = row.dig('execution', 'verdict') == 'PASS' && row.dig('native_observation', 'status') == 'pass' && %w[PASS not-consumed].include?(output['status']) ? 'PASS' : 'FAIL'
                       raise Corpus::ContractError, 'resumed product verdict differs' unless row['product_verdict'] == expected && row['upstream_output'] == output
                     end
                     complete
                   elsif row['product_verdict'] == 'FAIL' && !row.fetch('unfinished_phases').empty?
                     phases = root['axis'] == 'testdir' ? catalog.fetch(root.fetch('recipe').fetch('action'), { 'phase_contract' => ['resolve-build-ignore-before-action'] }).fetch('phase_contract') : root['axis'] == 'typechecker' ? %w[check-original-fixture match-source-positioned-diagnostics] : %w[build-test-harness enumerate-runtime-tests execute-product-test-bodies join-all-runtime-results]
                     raise Corpus::ContractError, 'missing recipe obligations' unless row['unfinished_phases'] == phases && row['modes'].values.all? { |m| m['verdict'] == 'FAIL' && m['stage_role'] == 'diagnostic-probe-only' }
                     probes!(row, root: root, source_root: source_root, provenance: row.fetch('provenance'))
                   elsif root['axis'] == 'typechecker' && row.key?('typechecker_evidence')
                     # Fail-closed: the check-harness adapter has no independent
                     # resume validator yet, so its terminals are re-executed
                     # without credit until one is reviewed.
                     false
                   else false
                   end
                 else raise Corpus::ContractError, 'unknown resumed verdict'
                 end
      (eligible ? reusable : fresh)[row.fetch('id')] = eligible ? row : 'No independent resume adapter for this terminal evidence; execute fresh without credit.'
    end
    { 'reusable' => reusable, 'fresh' => fresh, 'checkpoint_roots' => records.length }
  rescue KeyError, TypeError, JSON::ParserError, SystemCallError => error
    raise Corpus::ContractError, "malformed/legacy checkpoint: #{error.message}"
  end
end
