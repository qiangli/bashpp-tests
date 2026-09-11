# frozen_string_literal: true
# Sprint: #148; Story: #30; Story-ID: cdfb5e220f8e
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative '../tools/go-full/execution_identity'
require_relative '../tools/go-full/stage_resolver'
require_relative '../tools/go-full/product'

class Sprint148ExactExecutionIdentityTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('s148-2-identity-'))
    build_candidate; build_sdk; build_module_context
    @environment = controlled_environment
    build_importcfg; build_inventory_and_runners
  end
  def teardown; FileUtils.rm_rf(@tmp); end
  def write(relative, bytes)
    path = File.join(@tmp, relative); FileUtils.mkdir_p(File.dirname(path)); File.binwrite(path, bytes); path
  end
  def write_json(relative, value); write(relative, Corpus.canonical(value) + "\n"); end

  def build_candidate
    @launcher = write('candidate/bashy', "#!/bin/sh\nexit 0\n"); File.chmod(0o755, @launcher)
    @payload = write('candidate/bashy.real', "payload\n")
    @replacement = File.join(@tmp, 'candidate/sh')
    @replacement_mod = write('candidate/sh/go.mod', "module mvdan.cc/sh/v3\n")
    @replacement_sum = write('candidate/sh/go.sum', '')
    repository = @replacement
    env = { 'GIT_AUTHOR_NAME' => 'fixture', 'GIT_AUTHOR_EMAIL' => 'fixture@example.invalid',
            'GIT_COMMITTER_NAME' => 'fixture', 'GIT_COMMITTER_EMAIL' => 'fixture@example.invalid' }
    %w[init add].each do |command|
      argv = command == 'init' ? %w[git init -q] : %w[git add .]
      _out, error, status = Open3.capture3(env, *argv, chdir: repository)
      raise error unless status.success?
    end
    _out, error, status = Open3.capture3(env, 'git', 'commit', '-q', '-m', 'fixture', chdir: repository)
    raise error unless status.success?
    commit, _error, status = Open3.capture3('git', 'rev-parse', 'HEAD', chdir: repository)
    raise 'fixture revision unavailable' unless status.success?
    @candidate = write_json('manifests/candidate.json', {
      'launcher_sha256' => Corpus.digest(@launcher), 'payload_sha256' => Corpus.digest(@payload),
      'frontend_version' => 'gosource-v1', 'build_recipe' => 'fixture',
      'repositories' => [{ 'path' => repository, 'commit' => commit.strip }]
    }); @candidate_sha = Corpus.digest(@candidate)
  end

  def build_sdk
    @sdk_root = File.join(@tmp, 'sdk/root'); @go = write('sdk/root/bin/go', "fixture go\n")
    @source_archive = write('sdk/go.src.tar.gz', 'source archive'); @distribution_archive = write('sdk/go.fixture.tar.gz', 'distribution archive')
    @sdk = write_json('manifests/sdk.json', {
      'schema' => 'go-full-sdk/v1', 'root' => @sdk_root, 'release' => 'go1.27.0', 'goos' => 'fixture', 'goarch' => 'fixture',
      'go' => Corpus.file_record(@go), 'source_archive' => archive_manifest_record(@source_archive),
      'distribution_archive' => archive_manifest_record(@distribution_archive), 'manifest_sha256' => Digest::SHA256.hexdigest('sdk tree')
    }); @sdk_sha = Corpus.digest(@sdk)
  end
  def archive_manifest_record(path); Corpus.file_record(path).slice('path', 'sha256'); end

  def build_module_context
    @gomodcache = File.join(@tmp, 'gomodcache'); dependency = File.join(@gomodcache, 'example.org/dep@v1.0.0')
    @dependency_source = write('gomodcache/example.org/dep@v1.0.0/dep.go', "package dep\n")
    @module_archive = write('gomodcache/cache/download/example.org/dep/@v/v1.0.0.zip', 'dep zip')
    @module_gomod = write('gomodcache/cache/download/example.org/dep/@v/v1.0.0.mod', 'module example.org/dep')
    @go_mod_bytes = "module fixture.invalid/test\nrequire example.org/dep v1.0.0\nreplace mvdan.cc/sh/v3 => #{@replacement}\n"
    @go_sum_bytes = "example.org/dep v1.0.0 h1:fixturearchive=\nexample.org/dep v1.0.0/go.mod h1:fixturemod=\n"
    @go_mod = write('scaffold/go.mod', @go_mod_bytes); @go_sum = write('scaffold/go.sum', @go_sum_bytes)
    @module_files = write_json('manifests/module-files.json', { 'go.mod' => @go_mod_bytes, 'go.sum' => @go_sum_bytes })
    @module_context = write_json('manifests/module-context.json', {
      'schema' => 'go-full-module-context/v1', 'candidate_manifest' => Corpus.file_record(@candidate), 'sdk_identity' => Corpus.file_record(@sdk),
      'replacement' => { 'module' => 'mvdan.cc/sh/v3', 'path' => @replacement,
        'commit' => JSON.parse(File.read(@candidate)).fetch('repositories').first.fetch('commit'),
        'original_go_mod' => Corpus.file_record(@replacement_mod), 'original_go_sum' => Corpus.file_record(@replacement_sum) },
      'module_files_argument' => Corpus.file_record(@module_files),
      'module_files' => { 'go.mod' => Corpus.file_record(@go_mod), 'go.sum' => Corpus.file_record(@go_sum) },
      'gomodcache' => @gomodcache, 'environment' => { 'GOENV' => 'off', 'GOWORK' => 'off', 'GOFLAGS' => '-mod=readonly -p=2', 'GOMODCACHE' => @gomodcache },
      'modules' => [{ 'module' => 'example.org/dep', 'version' => 'v1.0.0', 'sum' => 'h1:fixturearchive=', 'gomod_sum' => 'h1:fixturemod=',
        'directory' => dependency, 'archive' => Corpus.file_record(@module_archive), 'gomod' => Corpus.file_record(@module_gomod),
        'files' => [Corpus.file_record(@dependency_source).merge('path' => 'dep.go')] }],
      'provisioning_evidence' => {}, 'cache_root' => File.join(@tmp, 'build-cache'),
      'original_program_edits' => false, 'whole_original_native_delegation' => false
    }); @module_context_sha = Corpus.digest(@module_context)
  end

  def controlled_environment
    { 'BASHY_HINTS' => 'off', 'GOENV' => 'off', 'GOFLAGS' => '-mod=readonly -p=2', 'GOMAXPROCS' => '2',
      'GOMODCACHE' => @gomodcache, 'GOPROXY' => 'off', 'GOROOT' => @sdk_root, 'GOSUMDB' => 'off',
      'GOTOOLCHAIN' => 'local', 'GOWORK' => 'off', 'LC_ALL' => 'C', 'PATH' => '/usr/bin:/bin', 'TZ' => 'UTC' }
  end

  def build_importcfg
    @import_cache = File.join(@tmp, 'import-cache'); @stdlib_archive = write('sdk/pkg/fmt.a', "!<arch>\nfixture")
    @importcfg = write('import-cache/importcfg-std', "packagefile fmt=#{@stdlib_archive}\n")
    @import_stdout = write('import-cache/importcfg-logs/list-export.stdout', File.binread(@importcfg)); @import_stderr = write('import-cache/importcfg-logs/list-export.stderr', '')
    context = { 'identity' => 'go version go1.27.0 fixture/fixture', 'goroot' => @sdk_root, 'goos' => 'fixture', 'goarch' => 'fixture',
      'cache' => @import_cache, 'environment' => @environment }
    packages = [{ 'name' => 'fmt', 'archive' => Corpus.file_record(@stdlib_archive) }]
    stage = { 'argv' => [@go, *Corpus::IMPORTCFG_RECIPE, Corpus::IMPORTCFG_TEMPLATE, 'std'],
      'cwd' => File.join(@import_cache, Corpus::IMPORTCFG_HOME), 'environment' => Corpus.importcfg_environment(context),
      'timeout_seconds' => 60, 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil, 'descendants_survived' => false,
      'stdout' => Corpus.file_record(@import_stdout), 'stderr' => Corpus.file_record(@import_stderr) }
    @import_receipt = write_json('import-cache/importcfg-std.receipt.json', Corpus.file_record(@importcfg).merge(
      'schema' => Corpus::IMPORTCFG_SCHEMA, 'tool' => Corpus.file_record(@go), 'context' => context, 'preparation' => stage,
      'packages' => packages, 'packages_sha256' => Digest::SHA256.hexdigest(Corpus.canonical(packages))))
    @import_receipt_sha = Corpus.digest(@import_receipt)
  end

  def build_inventory_and_runners
    @inventory_paths = { 'summary.json' => write('inventory/summary.json', '{}'), 'package-roots.jsonl' => write('inventory/package-roots.jsonl', ''),
      'testdir-roots.jsonl' => write('inventory/testdir-roots.jsonl', ''), 'typechecker-roots.jsonl' => write('inventory/typechecker-roots.jsonl', '') }
    @runner_paths = { 'product.rb' => write('runner/product.rb', '# product'), 'resume.rb' => write('runner/resume.rb', '# resume'),
      'executor.rb' => write('runner/executor.rb', '# executor') }
    @inventory = @inventory_paths.transform_values { |path| Corpus.file_record(path) }
    @runners = @runner_paths.transform_values { |path| Corpus.file_record(path) }
  end

  def args
    { root_id: 'testdir:fixedbugs/example.go', stage_id: 'compiled:compile', candidate_manifest: @candidate,
      candidate_manifest_sha256: @candidate_sha, launcher: @launcher, payload: @payload, sdk_identity: @sdk,
      sdk_identity_sha256: @sdk_sha, bin_go: @go, inventory: @inventory, runners: @runners,
      module_context: @module_context, module_context_sha256: @module_context_sha, module_files: @module_files,
      go_mod: @go_mod, go_sum: @go_sum, importcfg_receipt: @import_receipt,
      importcfg_receipt_sha256: @import_receipt_sha, timeout_seconds: 60, environment: @environment }
  end
  def prepare; GoFullExecutionIdentity.prepare!(**args); end
  def persist(receipt = prepare, name = 'identity.json')
    path = File.join(@tmp, 'evidence', name); record = GoFullExecutionIdentity.persist!(path, receipt); [path, record]
  end
  def backing_paths
    [@candidate, @launcher, @payload, @replacement_mod, @replacement_sum,
     @sdk, @go, @source_archive, @distribution_archive, *@inventory_paths.values, *@runner_paths.values,
     @module_context, @module_files, @go_mod, @go_sum, @dependency_source, @module_archive, @module_gomod,
     @import_receipt, @importcfg, @import_stdout, @import_stderr, @stdlib_archive]
  end

  def test_preflight_binds_every_required_identity_and_persisted_receipt_reauthenticates
    receipt = prepare
    assert_equal archive_manifest_record(@source_archive), JSON.parse(File.read(@sdk)).fetch('source_archive')
    assert_equal Corpus.file_record(@source_archive), receipt.dig('sdk', 'source_archive')
    assert_equal GoFullExecutionIdentity::INVENTORY_FILES.sort, receipt.dig('inventory', 'files').keys.sort
    assert_equal @runners.keys.sort, receipt.dig('runners', 'files').keys.sort
    assert_equal ['fmt'], receipt.dig('importcfg', 'packages').map { |row| row.fetch('name') }
    path, record = persist(receipt); assert_equal receipt, GoFullExecutionIdentity.load!(path, expected_sha256: record.fetch('sha256'))
    assert_equal receipt.fetch('identity_sha256'), GoFullExecutionIdentity.authorize_launch!(receipt,
      root_id: receipt.fetch('root_id'), stage_id: receipt.fetch('stage_id'), timeout_seconds: 60, environment: @environment)
    assert_equal 'PASS', GoFullExecutionIdentity.authenticate_verdict!(path, expected_sha256: record.fetch('sha256'),
      root_id: receipt.fetch('root_id'), stage_id: receipt.fetch('stage_id'), verdict: 'PASS')
  end

  def rewrite_sdk_manifest
    sdk = JSON.parse(File.read(@sdk))
    yield sdk
    File.write(@sdk, Corpus.canonical(sdk) + "\n")
    @sdk_sha = Corpus.digest(@sdk)
  end

  def test_sdk_archive_manifest_bytes_bind_when_supplied
    rewrite_sdk_manifest do |sdk|
      sdk['source_archive'] = Corpus.file_record(@source_archive)
      sdk['distribution_archive'] = Corpus.file_record(@distribution_archive)
    end
    build_module_context
    receipt = prepare
    path, record = persist(receipt, 'archive-bytes-identity.json')
    assert_equal receipt, GoFullExecutionIdentity.load!(path, expected_sha256: record.fetch('sha256'))

    rewrite_sdk_manifest { |sdk| sdk.fetch('source_archive')['bytes'] += 1 }
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.prepare!(**args) }
  end

  def test_sdk_archive_manifest_fails_closed_on_unknown_fields
    rewrite_sdk_manifest { |sdk| sdk.fetch('source_archive')['mode'] = 0o644 }
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.prepare!(**args) }
  end


  def test_every_independent_backing_file_tamper_is_rejected_during_preflight
    backing_paths.length.times do |index|
      teardown; setup; target = backing_paths.fetch(index)
      File.chmod(0o644, target) rescue nil; File.open(target, 'ab') { |file| file.write('tamper') }
      assert_raises(Corpus::ContractError, target) { prepare }
    end
  end

  def test_fresh_process_reauthenticates_and_rejects_wrong_anchor
    path, record = persist
    command = ['ruby', File.expand_path('../tools/go-full/execution_identity.rb', __dir__), 'verify', path, record.fetch('sha256')]
    stdout, stderr, status = Open3.capture3(*command); assert status.success?, stderr; assert_equal "authenticated\n", stdout
    _out, _err, bad = Open3.capture3(*command[0..-2], '0' * 64); refute bad.success?
  end

  def test_every_independent_backing_file_tamper_is_rejected_before_verdict
    backing_paths.length.times do |index|
      teardown; setup; target = backing_paths.fetch(index); path, record = persist
      File.chmod(0o644, target) rescue nil; File.open(target, 'ab') { |file| file.write('tamper') }
      assert_raises(Corpus::ContractError, target) do
        GoFullExecutionIdentity.authenticate_verdict!(path, expected_sha256: record.fetch('sha256'),
          root_id: 'testdir:fixedbugs/example.go', stage_id: 'compiled:compile', verdict: 'PASS')
      end
    end
  end

  def reseal(receipt)
    receipt['identity_sha256'] = GoFullExecutionIdentity.identity_sha256(receipt.reject { |key, _| key == 'identity_sha256' }); receipt
  end
  def persist_raw(receipt, name)
    path = File.join(@tmp, 'evidence', name + '.json'); FileUtils.mkdir_p(File.dirname(path)); File.write(path, Corpus.canonical(receipt) + "\n"); [path, Corpus.file_record(path)]
  end
  def reseal_collection(receipt, key)
    receipt[key]['count'] = receipt[key]['files'].length
    receipt[key]['sha256'] = GoFullExecutionIdentity.identity_sha256(receipt[key]['files'])
  end

  def test_exact_path_digest_size_collection_environment_timeout_and_cross_joins
    original = prepare
    mutations = {
      'digest' => ->(r) { r['runners']['files']['product.rb']['sha256'] = '0' * 64; reseal_collection(r, 'runners') },
      'size' => ->(r) { r['runners']['files']['product.rb']['bytes'] += 1; reseal_collection(r, 'runners') },
      'missing inventory' => ->(r) { r['inventory']['files'].delete('summary.json'); reseal_collection(r, 'inventory') },
      'runner count' => ->(r) { r['runners']['count'] += 1 }, 'runner set digest' => ->(r) { r['runners']['sha256'] = '0' * 64 },
      'environment injection' => ->(r) { r['environment']['INJECTED'] = 'yes' }, 'environment deletion' => ->(r) { r['environment'].delete('GOENV') },
      'network toolchain' => ->(r) { r['environment']['GOTOOLCHAIN'] = 'auto' }, 'timeout zero' => ->(r) { r['timeout_seconds'] = 0 },
      'timeout over ceiling' => ->(r) { r['timeout_seconds'] = 61 }, 'SDK identity' => ->(r) { r['sdk']['identity'] = 'go version go1.26.0 fixture/fixture' },
      'candidate launcher join' => ->(r) { r['candidate']['launcher']['sha256'] = r['candidate']['payload']['sha256'] },
      'module-files join' => ->(r) { r['module']['module_files'] = r['module']['context'] }, 'importcfg package join' => ->(r) { r['importcfg']['packages'] = [] }
    }
    mutations.each do |label, mutation|
      receipt = Marshal.load(Marshal.dump(original)); mutation.call(receipt); path, record = persist_raw(reseal(receipt), label.gsub(/\W+/, '-'))
      assert_raises(Corpus::ContractError, label) { GoFullExecutionIdentity.load!(path, expected_sha256: record.fetch('sha256')) }
    end
  end


  def test_receipt_path_substitution_cannot_cross_the_persisted_trust_anchor
    path, anchor = persist
    receipt = JSON.parse(File.read(path))
    receipt['runners']['files']['product.rb']['path'] = write('alternate/product.rb', File.binread(@runner_paths['product.rb']))
    receipt['runners']['files']['injected.rb'] = Corpus.file_record(write('runner/injected.rb', '# injected'))
    reseal_collection(receipt, 'runners'); reseal(receipt)
    File.chmod(0o644, path); File.write(path, Corpus.canonical(receipt) + "\n")
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.load!(path, expected_sha256: anchor.fetch('sha256')) }
  end

  def test_prepare_rejects_uncontrolled_environment_and_unbounded_timeout
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.prepare!(**args.merge(environment: @environment.merge('SECRET' => 'ambient'))) }
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.prepare!(**args.merge(timeout_seconds: 61)) }
  end

  def test_persistence_is_exclusive_and_verdict_identity_is_exact
    path, record = persist; assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.persist!(path, prepare) }
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.authenticate_verdict!(path, expected_sha256: record.fetch('sha256'), root_id: 'foreign', stage_id: 'compiled:compile', verdict: 'PASS') }
    assert_raises(Corpus::ContractError) { GoFullExecutionIdentity.authenticate_verdict!(path, expected_sha256: record.fetch('sha256'), root_id: 'testdir:fixedbugs/example.go', stage_id: 'compiled:compile', verdict: 'UNKNOWN') }
  end

  def test_stage_resolver_runs_through_authenticated_identity_and_lineage
    path, record = persist
    lineage_path = File.join(@tmp, 'evidence', 'lineage.jsonl')
    result = GoFullStageResolver.run!(
      identity_path: path, identity_sha256: record.fetch('sha256'),
      root_id: args.fetch(:root_id), stage_id: args.fetch(:stage_id),
      native_observation: { 'status' => 'pass', 'evidence_kind' => 'native-go-only' },
      decision: 'execute', stage_role: 'compile', argv: [RbConfig.ruby, '-e', 'exit 0'],
      cwd: @tmp, environment: @environment, lineage_path: lineage_path,
      log_prefix: File.join(@tmp, 'evidence', 'logs', 'compile')
    )
    assert_equal 'PASS', result.fetch('verdict')
    payload = Corpus::ProcessLineage.authenticate!(lineage_path).fetch(0)
    assert_equal record.fetch('sha256'), payload.dig('artifacts', 'execution_identity', 'sha256')
    assert_equal result.dig('stage', 'lineage', 'payload_sha256'),
                 Corpus::ProcessLineage.payload_sha256(payload)
  end

  def test_shared_executor_preflight_consumes_exact_stage_identity_reference
    path, record = persist
    executor = Corpus::Executor.allocate
    executor.instance_variable_set(:@timeout, 60)
    references = { args.fetch(:stage_id) => { 'path' => path, 'sha256' => record.fetch('sha256') } }
    assert_equal references.fetch(args.fetch(:stage_id)), executor.send(:authenticate_stage_identity,
      references, args.fetch(:stage_id), args.fetch(:root_id), @environment)
    assert_raises(Corpus::ContractError) do
      executor.send(:authenticate_stage_identity, references, 'other-stage', args.fetch(:root_id), @environment)
    end
    assert_raises(Corpus::ContractError) do
      executor.send(:authenticate_stage_identity, references, args.fetch(:stage_id), 'other-root', @environment)
    end
  end

  def test_identity_index_rejects_missing_and_extra_stages_against_plan
    path, record = persist
    reference = { 'path' => path, 'sha256' => record.fetch('sha256') }
    index = write_json('evidence/index.json', { 'schema' => 'go-full-execution-identity-index/v1',
      'root_id' => args.fetch(:root_id), 'entries' => { args.fetch(:stage_id) => reference } })
    loaded, = GoFullProduct.load_identity_index(index, Corpus.digest(index), args.fetch(:root_id),
      expected_stage_ids: [args.fetch(:stage_id)])
    assert_equal reference, loaded.fetch(args.fetch(:stage_id))
    assert_raises(Corpus::ContractError) do
      GoFullProduct.load_identity_index(index, Corpus.digest(index), args.fetch(:root_id),
        expected_stage_ids: [args.fetch(:stage_id), 'missing'])
    end
    assert_raises(Corpus::ContractError) do
      GoFullProduct.load_identity_index(index, Corpus.digest(index), args.fetch(:root_id), expected_stage_ids: [])
    end
  end

  def test_shared_executor_stage_uses_resolver_identity_lineage_and_combined_sink
    path, record = persist
    executor = Corpus::Executor.allocate
    executor.instance_variable_set(:@timeout, 60)
    environment = @environment.merge('HOME' => File.join(@tmp, 'home'), 'TMPDIR' => File.join(@tmp, 'tmp'),
                                     'GOCACHE' => File.join(@tmp, 'gocache'))
    stage = executor.send(:capture_stage,
      argv: [RbConfig.ruby, '-e', 'STDOUT.sync=true; STDERR.sync=true; STDOUT.write("A\\n"); STDERR.write("\\n"); STDOUT.write("B\\n")'],
      cwd: @tmp, log_prefix: File.join(@tmp, 'evidence', 'shared-stage'), environment: environment,
      lineage_path: File.join(@tmp, 'evidence', 'shared-lineage.jsonl'), root_id: args.fetch(:root_id),
      stage_id: args.fetch(:stage_id), parent_launch_id: nil, artifact_paths: {}, artifact_parents: {},
      combined_output: true, identity: { 'path' => path, 'sha256' => record.fetch('sha256') },
      native_observation: { 'status' => 'pass', 'evidence_kind' => 'native-go-only' }, stage_role: 'compile')
    assert_equal "A\n\nB\n", File.binread(stage.dig('combined', 'path'))
    assert_equal 'PASS', stage.dig('resolution', 'verdict')
    payload = Corpus::ProcessLineage.authenticate!(stage.dig('lineage', 'path')).fetch(0)
    assert_equal record.fetch('sha256'), payload.dig('artifacts', 'execution_identity', 'sha256')
    assert_equal 'kernel-combined', payload['output_mode']
  end

  def test_stage_resolver_deadline_kills_reaps_and_remains_a_failure
    receipt = GoFullExecutionIdentity.prepare!(**args.merge(timeout_seconds: 0.05))
    path, record = persist(receipt, 'deadline-identity.json')
    lineage_path = File.join(@tmp, 'evidence', 'deadline-lineage.jsonl')
    result = GoFullStageResolver.run!(
      identity_path: path, identity_sha256: record.fetch('sha256'),
      root_id: args.fetch(:root_id), stage_id: args.fetch(:stage_id),
      native_observation: { 'status' => 'pass', 'evidence_kind' => 'native-go-only' },
      decision: 'execute', stage_role: 'compile',
      argv: [RbConfig.ruby, '-e', 'fork { sleep 30 }; sleep 30'],
      cwd: @tmp, environment: @environment, lineage_path: lineage_path,
      log_prefix: File.join(@tmp, 'evidence', 'logs', 'deadline')
    )
    assert_equal 'FAIL', result.fetch('verdict')
    assert_equal 'deadline-is-failed-execution', result.dig('decisive', 'rule')
    payload = Corpus::ProcessLineage.authenticate!(lineage_path).fetch(0)
    assert_equal 'deadline', payload.dig('terminal', 'state')
    assert_equal false, payload.dig('terminal', 'descendants_survived')
    assert payload.fetch('kill_events').any? { |event| event['reason'] == 'deadline' }
    refute_empty payload.fetch('reap_events')
  end
end
