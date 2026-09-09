# frozen_string_literal: true
# These tests exercise harness rejection. They are not corpus certification.
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/corpus/validate'

class CorpusExecutorTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('corpus-contract-')
    @env = { 'PATH' => ENV.fetch('PATH', ''), 'GOTOOLCHAIN' => 'local' }
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def capture(code, timeout: 2)
    Corpus.capture([RbConfig.ruby, '-e', code], cwd: @tmp, env: @env,
                   timeout: timeout, log_prefix: File.join(@tmp, 'log'))
  end

  def test_native_exit_and_raw_bytes_are_separate
    result = capture('STDOUT.binmode; STDOUT.write("\\x00\\xff"); STDERR.write("error"); exit 7')
    assert_equal 'exited', result['state']
    assert_equal 7, result['exit']
    assert_equal "\x00\xff".b, File.binread(result['stdout']['path'])
    assert_equal 'error', File.binread(result['stderr']['path'])
    refute Corpus.success?(result)
  end

  def test_deadline_kills_whole_group
    result = capture('fork { sleep 30 }; sleep 30', timeout: 0.1)
    assert_equal 'deadline', result['state']
    assert_operator result['duration_seconds'], :<, 2
    refute Corpus.success?(result)
  end

  def test_orphaned_child_is_failure
    result = capture('fork { sleep 30 }; exit! 0')
    assert_equal 'process_leak', result['state']
    assert result['descendants_survived']
    refute Corpus.success?(result)
  end

  def test_missing_tool_is_not_negative_program_pass
    result = Corpus.capture(['/certainly/not/a/tool'], cwd: @tmp, env: @env,
                            timeout: 1, log_prefix: File.join(@tmp, 'missing'))
    assert_equal 'launch_failure', result['state']
    refute result['spawned']
    refute Corpus.success?(result)
  end

  def test_path_traversal_and_symlink_rejected
    assert_raises(Corpus::ContractError) { Corpus.safe_path(@tmp, '../a.go') }
    File.symlink('/tmp', File.join(@tmp, 'link'))
    assert_raises(Corpus::ContractError) { Corpus.safe_path(@tmp, 'link/a.go') }
  end

  def test_changed_artifact_rejected
    path = File.join(@tmp, 'artifact')
    File.write(path, 'original')
    record = Corpus.file_record(path)
    File.write(path, 'tampered')
    assert_raises(Corpus::ContractError) { Corpus::Validation.file!(record) }
  end

  def test_missing_or_duplicate_rows_rejected
    assert_raises(Corpus::ContractError) { Corpus::Validation.validate!([], expected: { 'hello' => {} }, provenance: {}) }
    assert_raises(Corpus::ContractError) { Corpus::Validation.validate!([{ 'id' => 'hello' }] * 2, expected: { 'hello' => {} }, provenance: {}) }
  end

  def test_real_go_oracle_builds_and_runs_native_exit_without_source
    go = ENV.fetch('CORPUS_TEST_GO') { ENV.fetch('PATH').split(':').map { |p| File.join(p, 'go') }.find { |p| File.executable?(p) } }
    skip 'Go unavailable for real oracle test' unless go
    src = File.join(@tmp, 'source'); FileUtils.mkdir_p(src)
    source = File.join(src, 'main.go')
    File.write(source, "package main\nimport (\"os\"; \"fmt\")\nfunc main() { fmt.Println(\"oracle\"); os.Exit(7) }\n")
    executor = Corpus::Executor.allocate
    executor.instance_variable_set(:@go, File.realpath(go))
    executor.instance_variable_set(:@bashy, '/certainly/not/a/bashy')
    executor.instance_variable_set(:@env, @env)
    executor.instance_variable_set(:@cache, File.join(@tmp, 'cache'))
    executor.instance_variable_set(:@timeout, 30)
    inputs = { 'main.go' => Corpus.file_record(source) }
    result = executor.send(:execute_mode, @tmp, 'baseline', inputs, ['main.go'], [], {}, 'run', [], {}, nil)
    assert_equal 'complete', result['state'], result.inspect
    assert_equal %w[build run], result['stages'].map { |s| s['stage'] }
    assert_equal 7, result['stages'].last['exit']
    assert_equal "oracle\n", File.binread(result['stages'].last['stdout']['path'])
    refute File.exist?(File.join(@tmp, 'baseline/work/main.go'))
    assert_equal inputs['main.go']['sha256'], Corpus.digest(source)
  end


  def test_successful_command_without_generated_artifact_fails_closed
    executor = Corpus::Executor.allocate
    executor.instance_variable_set(:@go, '/usr/bin/true')
    executor.instance_variable_set(:@bashy, '/usr/bin/true')
    executor.instance_variable_set(:@env, @env)
    executor.instance_variable_set(:@cache, File.join(@tmp, 'cache'))
    executor.instance_variable_set(:@timeout, 2)
    source = File.join(@tmp, 'source.go'); File.write(source, "package main\nfunc main() {}\n")
    result = executor.send(:execute_mode, @tmp, 'compiled', { 'source.go' => Corpus.file_record(source) }, ['source.go'], [], {}, 'run', [], {}, nil)
    assert_equal 'missing_artifact', result['state']
    assert_equal ['transpile'], result['stages'].map { |s| s['stage'] }
    assert_equal 0, result['stages'].first['exit']
    baseline = executor.send(:execute_mode, @tmp, 'baseline', { 'source.go' => Corpus.file_record(source) }, ['source.go'], [], {}, 'run', [], {}, nil)
    assert_equal 'missing_artifact', baseline['state']
    assert_equal ['build'], baseline['stages'].map { |stage| stage['stage'] }
  end

  def test_build_only_oracle_does_not_execute_init_or_main
    go = ENV.fetch('CORPUS_TEST_GO') { ENV.fetch('PATH').split(':').map { |p| File.join(p, 'go') }.find { |p| File.executable?(p) } }
    skip 'Go unavailable' unless go
    executor = Corpus::Executor.allocate
    executor.instance_variable_set(:@go, File.realpath(go))
    executor.instance_variable_set(:@env, @env)
    executor.instance_variable_set(:@cache, File.join(@tmp, 'cache'))
    executor.instance_variable_set(:@timeout, 30)
    source = File.join(@tmp, 'source.go')
    File.write(source, "package main\nfunc init() { panic(\"must not run init\") }\nfunc main() { panic(\"must not run main\") }\n")
    result = executor.send(:execute_mode, @tmp, 'baseline', { 'source.go' => Corpus.file_record(source) }, ['source.go'], [], {}, 'build', [], {}, nil)
    assert_equal 'complete', result['state']
    assert_equal ['build'], result['stages'].map { |s| s['stage'] }
    assert_empty File.binread(result['stages'].last['stderr']['path'])
  end

  def test_package_argument_rejects_traversal_and_normalizes_local_directories
    assert_equal './subdir', Corpus.package_argument('subdir')
    assert_equal './subdir', Corpus.package_argument('./subdir')
    assert_equal '.', Corpus.package_argument('./')
    ['', '../subdir', 'a/../b', 'a//b', '/tmp', 'a/'].each do |value|
      assert_raises(Corpus::ContractError) { Corpus.package_argument(value) }
    end
  end

  def test_executable_script_is_not_native_artifact
    path = File.join(@tmp, 'program')
    File.write(path, "#!/bin/sh\nexit 0\n"); File.chmod(0o755, path)
    refute Corpus.native_binary?(path)
    assert Corpus.native_binary?(File.realpath(RbConfig.ruby))
  end

  def test_source_map_digest_does_not_hide_missing_or_invalid_mapping_schema
    mapping = { 'schema_version' => 'bashy-transpile-map-v1', 'origin' => 'main.go', 'go_digest' => 'sha256:abc',
                'mappings' => [{ 'go_line' => 1, 'go_col' => 1, 'source_line' => 2, 'source_col' => 1, 'source_offset' => 3, 'node' => 'func' }] }
    refute Corpus.valid_source_map?(mapping.merge('schema_version' => 'unknown'), 'abc')
    refute Corpus.valid_source_map?(mapping.merge('mappings' => nil), 'abc')
    refute Corpus.valid_source_map?(mapping.merge('mappings' => [{}]), 'abc')
    refute Corpus.valid_source_map?(mapping.merge('origin' => ''), 'abc')
  end

  def test_module_path_and_mutated_asset_checks_fail_closed
    executor = Corpus::Executor.allocate
    source = File.join(@tmp, 'source.go'); File.write(source, 'package main')
    asset = File.join(@tmp, 'asset'); File.write(asset, 'original')
    inputs = { 'source.go' => Corpus.file_record(source), 'asset' => Corpus.file_record(asset) }
    assert executor.send(:verify_inputs, @tmp, inputs, {})
    refute executor.send(:verify_inputs, @tmp, inputs, { '../escape' => 'bad' })
    File.write(asset, 'tampered')
    refute executor.send(:verify_inputs, @tmp, inputs, {})
    refute executor.send(:verify_assets, @tmp, ['asset'], inputs)
  end

  def test_runtime_environment_assets_and_absolute_interpreter_input_share_contract
    go = ENV.fetch('CORPUS_TEST_GO') { ENV.fetch('PATH').split(':').map { |p| File.join(p, 'go') }.find { |p| File.executable?(p) } }
    skip 'Go unavailable' unless go
    executor = Corpus::Executor.allocate
    executor.instance_variable_set(:@go, File.realpath(go))
    # Missing interpreter deliberately prevents any claim of product certification.
    executor.instance_variable_set(:@bashy, '/certainly/not/a/bashy')
    executor.instance_variable_set(:@env, @env)
    executor.instance_variable_set(:@cache, File.join(@tmp, 'shared-cache'))
    executor.instance_variable_set(:@timeout, 30)
    source = File.join(@tmp, 'main.go')
    File.write(source, "package main\nimport (\"fmt\"; \"os\")\nfunc main() { b, e := os.ReadFile(\"data/value\"); if e != nil { panic(e) }; fmt.Print(os.Getenv(\"CORPUS_VALUE\"), string(b)) }\n")
    asset = File.join(@tmp, 'asset'); File.write(asset, ':asset')
    inputs = { 'sub/main.go' => Corpus.file_record(source), 'data/value' => Corpus.file_record(asset) }
    module_files = { 'go.mod' => "module example.invalid/corpus\ngo 1.20\n" }
    native = executor.send(:execute_mode, @tmp, 'baseline', inputs, ['sub/main.go'], ['data/value'], module_files, 'run', [], { 'CORPUS_VALUE' => 'runtime' }, 'sub')
    assert_equal 'complete', native['state'], native.inspect
    assert_equal './sub', native['stages'].first['argv'].last
    assert_equal 'runtime:asset', File.binread(native['stages'].last['stdout']['path'])
    interpreted = executor.send(:execute_mode, @tmp, 'interpreted', inputs, ['sub/main.go'], ['data/value'], module_files, 'run', [], { 'CORPUS_VALUE' => 'runtime' }, 'sub')
    assert_equal 'stage_failure', interpreted['state']
    run = interpreted['stages'].last
    assert_equal 'runtime', run['environment']['CORPUS_VALUE']
    assert_equal native['stages'].first['environment']['GOCACHE'], run['environment']['GOCACHE']
    assert_equal File.join(@tmp, 'interpreted/runtime'), run['cwd']
    assert_equal File.join(@tmp, 'interpreted/work/sub'), run['argv'].last
    assert_equal ['data', 'data/value'], Corpus.snapshot(run['cwd']).keys.sort
    assert_equal ':asset', File.read(asset)
  end

  def test_no_candidate_payload_cannot_authenticate
    file = File.join(@tmp, 'launcher'); File.write(file, 'data')
    candidate = { 'launcher_sha256' => Corpus.digest(file), 'payload_sha256' => '0' * 64,
                  'frontend_version' => 'test', 'build_recipe' => 'make build', 'repositories' => [{ 'path' => @tmp, 'commit' => 'x' }] }
    assert_raises(Errno::ENOENT) { Corpus.authenticate_candidate(file, candidate) }
  end
  def retained_source_map(name)
    fixture_dir = File.join(__dir__, 'fixtures/source-map')
    mapping = JSON.parse(File.read(File.join(fixture_dir, "#{name}.map.json")))
    generated = File.join(@tmp, "#{name}.generated.go")
    FileUtils.cp(File.join(fixture_dir, "#{name}.generated.go.txt"), generated)
    sources = mapping.fetch('sources').to_h do |source|
      original = name == 'functions' ? File.expand_path('../../' + source.fetch('name'), __dir__) : File.join(fixture_dir, source.fetch('name'))
      retained = File.join(@tmp, File.basename(source.fetch('name')))
      FileUtils.cp(original, retained)
      [source.fetch('name'), Corpus.file_record(retained)]
    end
    [mapping, Corpus.file_record(generated), sources]
  end

  def test_source_map_go_provenance_validation_runs_offline
    mapping, generated, sources = retained_source_map('functions')
    fixture_dir = File.join(__dir__, 'fixtures/source-map')
    provenance = JSON.parse(File.read(File.join(fixture_dir, 'provenance.json')))
    assert_equal provenance.fetch('generated_sha256'), generated.fetch('sha256')
    assert_equal provenance.fetch('source_sha256'), sources.values.first.fetch('sha256')
    assert_equal provenance.fetch('map_sha256'), Corpus.digest(File.join(fixture_dir, 'functions.map.json'))
    assert Corpus.valid_source_map?(mapping, generated, sources)
    mutations = {
      missing_kind: ->(m) { m.delete('source_kind') },
      wrong_frontend: ->(m) { m['front_end'] = 'unknown' },
      duplicate_source: ->(m) { m['sources'] << m['sources'].first.dup },
      missing_source: ->(m) { m['sources'].clear },
      invalid_source: ->(m) { m['sources'][0] = nil },
      changed_base: ->(m) { m['sources'][0]['base'] = 1 },
      noninteger_base: ->(m) { m['sources'][0]['base'] = 0.0 },
      changed_size: ->(m) { m['sources'][0]['size'] += 1 },
      changed_digest: ->(m) { m['sources'][0]['sha256'] = '0' * 64 },
      wrong_line: ->(m) { m['mappings'][0]['source_line'] += 1 },
      wrong_column: ->(m) { m['mappings'][0]['source_col'] += 1 },
      wrong_local_offset: ->(m) { m['mappings'][0]['source_file_offset'] += 1 },
      wrong_go_position: ->(m) { m['mappings'][0]['go_line'] += 1 },
      empty_mappings: ->(m) { m['mappings'].clear },
      incomplete_mappings: ->(m) { m['mappings'].pop },
      duplicate_mapping: ->(m) { m['mappings'] << m['mappings'].last.dup },
      unordered_mappings: ->(m) { m['mappings'].reverse! }
    }
    mutations.each do |name, change|
      bad = JSON.parse(JSON.generate(mapping))
      change.call(bad)
      refute Corpus.valid_source_map?(bad, generated, sources), name.to_s
    end
    refute Corpus.valid_source_map?(mapping, generated.fetch('sha256'), sources)
  end

  def test_source_map_direct_validation_rehashes_actual_bytes
    mapping, generated, sources = retained_source_map('functions')
    path = generated.fetch('path')
    original = File.binread(path)
    File.binwrite(path, original.sub('func add', 'func bad'))
    refute Corpus.valid_source_map?(mapping, generated, sources), 'same-size generated mutation with stale metadata'
    File.binwrite(path, original)
    source = sources.values.first
    original_source = File.binread(source.fetch('path'))
    File.binwrite(source.fetch('path'), original_source.sub('func add', 'func bad'))
    refute Corpus.valid_source_map?(mapping, generated, sources), 'same-size original mutation with stale metadata'
    File.binwrite(source.fetch('path'), original_source)
    refute Corpus.valid_source_map?(mapping, generated.merge('bytes' => generated['bytes'] + 1), sources)
    assert Corpus.valid_source_map?(mapping, generated, sources)
    File.delete(path)
    refute Corpus.valid_source_map?(mapping, generated, sources), 'missing actual generated file'
  end

  def test_real_empty_package_allows_empty_map_and_requires_sorted_source_bases
    mapping, generated, sources = retained_source_map('empty')
    assert_empty mapping.fetch('mappings')
    refute_match %r{// lower:}, File.read(generated.fetch('path'))
    assert Corpus.valid_source_map?(mapping, generated, sources)
    bad = JSON.parse(JSON.generate(mapping))
    bad['sources'].reverse!
    base = 0
    bad['sources'].each { |src| src['base'] = base; base += src['size'] + 1 }
    refute Corpus.valid_source_map?(bad, generated, sources), 'self-consistent bases in nonlexical source order'
    refute Corpus.valid_source_map?(mapping.merge('sources' => []), generated, {}), 'missing original source identity'
  end

end
