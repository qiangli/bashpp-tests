# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/go-full/product'

class ModuleContextTests < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('module-context-'))
    @cache = File.join(@tmp, 'gomodcache'); @dependency = File.join(@cache, 'example.org/dep@v1.0.0')
    FileUtils.mkdir_p(@dependency); File.write(File.join(@dependency, 'source.go'), "package dep\n")
    @sh = File.join(@tmp, 'sh'); FileUtils.mkdir_p(@sh)
    File.write(File.join(@sh, 'go.mod'), "module mvdan.cc/sh/v3\n")
    File.write(File.join(@sh, 'go.sum'), '')
    @candidate = write('candidate.json', { 'repositories' => [{ 'path' => @sh, 'commit' => 'fixture-commit' }] })
    sdkroot = File.join(@tmp, 'sdk'); FileUtils.mkdir_p(File.join(sdkroot, 'bin')); File.write(File.join(sdkroot, 'bin/go'), 'fixture SDK bytes')
    @sdk = write('sdk.json', { 'root' => sdkroot, 'go' => Corpus.file_record(File.join(sdkroot, 'bin/go')), 'source_archive' => { 'path' => File.join(@tmp, 'source/archive') } })
    @modules = { 'go.mod' => "module fixture\nrequire example.org/dep v1.0.0\nreplace mvdan.cc/sh/v3 => #{@sh}\n", 'go.sum' => "example.org/dep v1.0.0 h1:fixturearchive=\nexample.org/dep v1.0.0/go.mod h1:fixturemod=\n" }
    @argument = write('module-files.json', @modules)
    records = @modules.to_h { |name, bytes| p = File.join(@tmp, name); File.write(p, bytes); [name, Corpus.file_record(p)] }
    @archive = File.join(@cache, 'dep.zip'); File.write(@archive, 'fixture archive bytes')
    @gomod = File.join(@cache, 'dep.mod'); File.write(@gomod, 'module example.org/dep')
    source = Corpus.file_record(File.join(@dependency, 'source.go')).merge('path' => 'source.go')
    @manifest = { 'schema' => 'go-full-module-context/v1', 'candidate_manifest' => Corpus.file_record(@candidate), 'sdk_identity' => Corpus.file_record(@sdk),
      'replacement' => { 'module' => 'mvdan.cc/sh/v3', 'path' => @sh, 'commit' => 'fixture-commit', 'original_go_mod' => Corpus.file_record(File.join(@sh, 'go.mod')), 'original_go_sum' => Corpus.file_record(File.join(@sh, 'go.sum')) },
      'module_files_argument' => Corpus.file_record(@argument), 'module_files' => records, 'gomodcache' => @cache,
      'environment' => { 'GOENV' => 'off', 'GOWORK' => 'off', 'GOFLAGS' => '-mod=readonly -p=2', 'GOMODCACHE' => @cache },
      'modules' => [{ 'module' => 'example.org/dep', 'version' => 'v1.0.0', 'sum' => 'h1:fixturearchive=', 'gomod_sum' => 'h1:fixturemod=', 'directory' => @dependency, 'archive' => Corpus.file_record(@archive), 'gomod' => Corpus.file_record(@gomod), 'files' => [source] }],
      'provisioning_evidence' => {}, 'cache_root' => File.join(@tmp, 'build-cache'), 'original_program_edits' => false, 'whole_original_native_delegation' => false }
    @path = write('manifest.json', @manifest); @sha = Corpus.digest(@path)
  end
  def teardown; FileUtils.rm_rf(@tmp); end
  def write(name, value)
    path = File.join(@tmp, name); File.write(path, Corpus.canonical(value)); path
  end
  def reseal
    write('manifest.json', @manifest); @sha = Corpus.digest(@path)
  end
  def load_context(**options)
    GoFullModuleContext.load(@path, candidate_path: @candidate, sdk_path: @sdk, expected_sha256: @sha, **options)
  end
  def test_complete_context_and_scaffold_authenticate
    context = load_context
    assert_equal @modules, context.fetch('module_files')
    assert_equal 1, context.dig('proof', 'dependency_files')
    assert_equal File.join(@tmp, 'build-cache', @sha), context['cache_root']
  end
  def test_unreviewed_manifest_rejected
    File.write(@path, File.read(@path) + ' '); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_tampered_dependency_tree_rejected
    File.write(File.join(@dependency, 'source.go'), 'tampered'); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_extra_dependency_file_rejected
    File.write(File.join(@dependency, 'extra.go'), 'extra'); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_missing_dependency_file_rejected
    File.unlink(File.join(@dependency, 'source.go')); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_dependency_symlink_rejected
    File.symlink(@gomod, File.join(@dependency, 'extra')); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_archive_mutation_rejected
    File.write(@archive, 'tampered'); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_gomod_mutation_rejected
    File.write(@gomod, 'tampered'); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_scaffold_argument_mutation_rejected
    File.write(@argument, '{}'); assert_raises(Corpus::ContractError) { load_context }
  end
  def test_scaffold_bytes_must_match_argument_even_after_resealing
    File.write(File.join(@tmp, 'go.mod'), 'different'); @manifest['module_files']['go.mod'] = Corpus.file_record(File.join(@tmp, 'go.mod')); reseal
    assert_raises(Corpus::ContractError) { load_context }
  end
  def test_mutated_sdk_binary_rejected
    sdk = JSON.parse(File.read(@sdk)); File.write(File.join(sdk['root'], 'bin/go'), 'tampered')
    assert_raises(Corpus::ContractError) { load_context }
  end
  def test_wrong_candidate_and_sdk_inputs_rejected
    other = write('other.json', {})
    assert_raises(Corpus::ContractError) { GoFullModuleContext.load(@path, candidate_path: other, sdk_path: @sdk, expected_sha256: @sha) }
    assert_raises(Corpus::ContractError) { GoFullModuleContext.load(@path, candidate_path: @candidate, sdk_path: other, expected_sha256: @sha) }
  end
  def test_duplicate_dependencies_rejected_after_resealing
    @manifest['modules'] *= 2; reseal; assert_raises(Corpus::ContractError) { load_context }
  end
  def test_mutable_environment_rejected_after_resealing
    @manifest['environment']['GOFLAGS'] = '-mod=mod'; reseal; assert_raises(Corpus::ContractError) { load_context }
  end
  def test_build_cache_cannot_overlap_inputs_even_through_symlink
    assert_raises(Corpus::ContractError) { load_context(cache_root: File.join(@cache, 'build')) }
    link = File.join(@tmp, 'cache-alias'); File.symlink(@cache, link)
    assert_raises(Corpus::ContractError) { load_context(cache_root: File.join(link, 'build')) }
  end
  def test_actual_captures_share_cache_environment_and_scaffold_in_all_paths
    context = load_context
    sdk = JSON.parse(File.read(@sdk)); go = File.join(sdk.fetch('root'), 'bin/go')
    tool = <<~'TOOL'
      #!/usr/bin/ruby
      require 'json'
      if ARGV.first == 'version'
        puts 'go version go1.27.0 fixture/fixture'; exit 0
      end
      if ARGV.first == 'build' && ARGV.last == '.'
        target = ARGV[ARGV.index('-o') + 1]
        File.write(target, "#!/usr/bin/ruby\nrequire 'json'\nputs JSON.generate({'verdict'=>'FAIL','reason'=>'authored matcher fixture'})\nexit 1\n")
        File.chmod(0755, target)
        puts JSON.generate(ENV.to_h)
        exit 0
      end
      puts JSON.generate(ENV.to_h)
      exit 2
    TOOL
    bashy = File.join(@tmp, 'bashy')
    [go, bashy, bashy + '.real'].each { |path| File.write(path, tool); File.chmod(0755, path) }
    candidate = { 'launcher_sha256' => Corpus.digest(bashy), 'payload_sha256' => Corpus.digest(bashy + '.real') }
    cache_path = File.join(context.fetch('cache_root'), 'unit-candidate-sdk-environment-key')
    env = { 'PATH' => '/usr/bin:/bin', 'GOROOT' => sdk.fetch('root'), 'GOTOOLCHAIN' => 'local', 'GOMAXPROCS' => '2', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'BASHY_HINTS' => 'off' }.merge(context.fetch('environment'))
    runtime = { 'base_environment' => env, 'cache_path' => cache_path, 'module_files' => @modules, 'module_context' => context.fetch('proof') }
    provenance = { 'candidate' => { 'launcher' => Corpus.file_record(bashy), 'payload' => Corpus.file_record(bashy + '.real') }, 'sdk' => { 'binary' => Corpus.file_record(go) }, 'cache' => { 'path' => cache_path, 'key' => 'unit-key', 'policy' => 'unit-shared' } }
    source = File.join(@tmp, 'original'); FileUtils.mkdir_p(source); File.write(File.join(source, 'case.go'), "package main\nfunc main() {}\n")
    root = { 'id' => 'testdir:case.go', 'axis' => 'testdir', 'path' => 'case.go', 'input_files' => ['case.go'], 'recipe' => { 'want_error' => true, 'want_autogenerated_diagnostics' => false } }
    evidence = File.join(@tmp, 'evidence')
    sdk.merge!('release' => 'go1.27.0', 'goos' => 'fixture', 'goarch' => 'fixture', 'go' => Corpus.file_record(go))
    setup = nil
    GoFullModuleContext.stub(:load, context) do
      Corpus.stub(:authenticate_candidate, provenance.fetch('candidate')) do
        setup = GoFullProduct.execution_setup({ bashy: bashy, candidate: @candidate, sdk_identity: @sdk, module_context: @path, timeout: 2 }, evidence, candidate, sdk)
      end
    end
    executor = setup.fetch(:executor); runtime = setup.fetch(:runtime)
    provenance = executor.provenance; env = runtime.fetch('base_environment'); cache_path = runtime.fetch('cache_path')
    assert cache_path.start_with?(context.fetch('cache_root') + '/')
    execution = executor.execute(id: root['id'], source_root: source, sources: ['case.go'], module_files: @modules)
    probes = GoFullProduct.probe(root, { bashy: bashy, timeout: 2, runtime: runtime }, source, evidence, sdk, candidate)
    matcher = GoFullProduct.build_matcher(evidence, sdk, runtime)
    matched = GoFullProduct.match_diagnostics(root, probes, matcher, evidence, 2)
    type_matcher = GoFullTypechecker.build_matcher(evidence, sdk, runtime)
    type_root = root.merge('axis' => 'typechecker', 'family' => 'fixedbugs', 'column_tolerance' => 0, 'runner' => 'authored-contract', 'runner_sha256' => 'fixture')
    typechecked = GoFullTypechecker.execute(root: type_root, options: { bashy: bashy, timeout: 2, runtime: runtime }, source_root: source, evidence: evidence, sdk_identity: sdk, candidate: candidate, matcher: type_matcher)
    stages = execution['modes'].values.flat_map { |mode| mode['stages'] } + probes.values.map { |mode| mode.fetch('stage') } + [matcher.fetch('build_stage')] + matched.values.map { |mode| mode.fetch('diagnostic_stage') }
    stages += [type_matcher.fetch('build_stage')] + typechecked.fetch('modes').values.flat_map { |mode| [mode.fetch('stage'), mode.fetch('match').fetch('stage')] }
    assert_equal 13, stages.length
    stages.each do |stage|
      assert_equal cache_path, stage.fetch('environment').fetch('GOCACHE')
      context.fetch('environment').each { |key, value| assert_equal value, stage.fetch('environment').fetch(key) }
    end
    execution['modes'].each_value do |mode|
      @modules.each { |name, bytes| assert_equal bytes, File.binread(File.join(mode.fetch('source_directory'), name)) }
    end
    assert GoFullResume.probes!({ 'modes' => probes }, root: root, source_root: source, provenance: provenance, environment: env, modules: @modules)
    probes['compiled']['stage']['environment']['GOCACHE'] = File.join(@tmp, 'private-cold-cache')
    assert_raises(Corpus::ContractError) { GoFullResume.probes!({ 'modes' => probes }, root: root, source_root: source, provenance: provenance, environment: env, modules: @modules) }
    probes['compiled']['stage']['environment']['GOCACHE'] = cache_path
    File.write(File.join(probes['compiled']['stage']['cwd'], 'go.mod'), 'tampered')
    assert_raises(Corpus::ContractError) { GoFullResume.probes!({ 'modes' => probes }, root: root, source_root: source, provenance: provenance, environment: env, modules: @modules) }
    assert_empty Dir[File.join(evidence, '**', 'gocache')]
  end

end
