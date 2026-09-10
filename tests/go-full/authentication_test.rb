# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/go-full/product'

class SDKRelocationAuthenticationTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('sdk-auth-')
    current = File.join(@tmp, 'current'); FileUtils.mkdir_p(File.join(current, 'root/bin'))
    %w[source.tar.gz distribution.tar.gz root/bin/go].each { |path| File.write(File.join(current, path), path) }
    @current = { 'schema' => 'go-full-sdk/v1', 'root' => File.join(current, 'root'), 'release' => 'go1.27.0', 'goos' => 'test', 'goarch' => 'test',
      'go' => { 'path' => 'bin/go', 'sha256' => Corpus.digest(File.join(current, 'root/bin/go')), 'bytes' => File.size(File.join(current, 'root/bin/go')) },
      'source_archive' => { 'path' => File.join(current, 'source.tar.gz'), 'sha256' => Corpus.digest(File.join(current, 'source.tar.gz')) },
      'distribution_archive' => { 'path' => File.join(current, 'distribution.tar.gz'), 'sha256' => Corpus.digest(File.join(current, 'distribution.tar.gz')) },
      'manifest_sha256' => 'pinned-tree', 'source_files' => 1, 'merged_files' => 1 }
    @native = Marshal.load(Marshal.dump(@current))
    @old = File.join(@tmp, 'absent-old')
    @native['root'] = @current['root'].sub(current, @old)
    %w[source_archive distribution_archive].each { |key| @native[key]['path'] = @current[key]['path'].sub(current, @old) }
    entries = Find.find(current).reject { |path| path == current }.sort.map do |path|
      row = { 'path' => path.delete_prefix(current + '/'), 'mode' => File.stat(path).mode & 0o777, 'kind' => File.directory?(path) ? 'directory' : 'file' }
      row.merge!(Corpus.file_record(path).reject { |key, _| key == 'path' }) if row['kind'] == 'file'
      row
    end
    @manifest = { 'schema' => 'sprint118-cache-relocation/v1', 'state' => 'complete', 'original_identity_bytes_preserved' => true, 'raw_evidence_rewritten' => false,
      'moves' => [{ 'old' => @old, 'new' => current, 'entries' => entries, 'files' => 3, 'bytes' => entries.sum { |row| row.fetch('bytes', 0) }, 'verified_after' => true,
                   'entry_manifest_sha256' => Digest::SHA256.hexdigest(JSON.generate(Corpus.sort(entries), ascii_only: true)) }] }
    @mapping = File.join(@tmp, 'mapping.json'); write_manifest
  end
  def teardown; FileUtils.rm_rf(@tmp); end
  def write_manifest
    File.write(@mapping, Corpus.canonical(@manifest)); @mapping_sha = Corpus.digest(@mapping)
  end
  def check
    GoFullAuthentication.stub(:derive_identity, ->(value) { assert_equal @current['root'], value['root']; @current }) do
      GoFullProduct.verify_sdk_identity(@native, @current, @mapping, relocation_sha256: @mapping_sha)
    end
  end
  def test_only_existing_current_tree_is_rederived
    assert_equal @current, check.fetch('current')
    refute File.exist?(@old)
  end
  def test_non_path_identity_change_rejected
    @native['source_files'] += 1
    assert_raises(Corpus::ContractError) { check }
  end
  def test_claimed_identity_must_equal_fresh_derivation
    GoFullAuthentication.stub(:derive_identity, @current.merge('manifest_sha256' => 'different')) do
      assert_raises(Corpus::ContractError) { GoFullProduct.verify_sdk_identity(@native, @current, @mapping, relocation_sha256: @mapping_sha) }
    end
  end
  def test_mutated_go_binary_rejected
    File.write(File.join(@current['root'], 'bin/go'), 'tampered')
    assert_raises(Corpus::ContractError) { check }
  end
  def test_mutated_archive_rejected
    File.write(@current['distribution_archive']['path'], 'tampered')
    assert_raises(Corpus::ContractError) { check }
  end
  def test_unreviewed_manifest_rejected
    File.write(@mapping, File.read(@mapping) + ' ')
    assert_raises(Corpus::ContractError) { check }
  end
  def test_prefix_collision_does_not_authenticate_old_path
    @native['root'] = @native['root'].sub(@old, @old + '-other')
    assert_raises(Corpus::ContractError) { check }
  end
  def test_wrong_mapping_rejected_even_with_reviewed_fixture_digest
    @manifest['moves'][0]['old'] += '-wrong'; write_manifest
    assert_raises(Corpus::ContractError) { check }
  end
  def test_extra_and_missing_current_entries_rejected
    File.write(File.join(File.dirname(@current['root']), 'extra'), 'x')
    assert_raises(Corpus::ContractError) { check }
  end
  def test_absent_current_sdk_is_never_materialized
    missing = Marshal.load(Marshal.dump(@current)); missing['root'] = File.join(@tmp, 'never-create')
    assert_raises(Corpus::ContractError) { GoFullAuthentication.derive_identity(missing) }
    refute File.exist?(missing['root'])
  end
end

class AuthenticatedResumeTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir('resume-auth-')); @source = File.join(@tmp, 'source'); FileUtils.mkdir_p(@source)
    File.write(File.join(@source, 'case.go'), "package main\nfunc main() {}\n")
    @go = File.join(@tmp, 'sdk/bin/go'); @bashy = File.join(@tmp, 'candidate/bashy')
    [@go, @bashy, @bashy + '.real'].each { |p| FileUtils.mkdir_p(File.dirname(p)); File.write(p, "#!/bin/sh\nprintf 'actual fixture rejection\\n' >&2\nexit 2\n"); File.chmod(0o755, p) }
    @env = { 'PATH' => '/usr/bin:/bin', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'BASHY_HINTS' => 'off', 'GOROOT' => File.dirname(File.dirname(@go)), 'GOMAXPROCS' => '2' }
    @provenance = { 'candidate' => { 'launcher' => Corpus.file_record(@bashy), 'payload' => Corpus.file_record(@bashy + '.real') }, 'sdk' => { 'binary' => Corpus.file_record(@go) }, 'cache' => { 'path' => File.join(@tmp, 'cache'), 'key' => 'fixed-environment', 'policy' => 'immutable-fixture' }, 'executor_sha256' => Corpus.digest(File.expand_path('../../tools/corpus/executor.rb', __dir__)) }
    @root = { 'id' => 'testdir:case.go', 'axis' => 'testdir', 'path' => 'case.go', 'input_files' => ['case.go'], 'recipe' => { 'action' => 'run', 'flags' => [], 'args' => [], 'environment_append' => [] }, 'expected_failure_sets' => [], 'expected_output' => { 'path' => 'case.out', 'present' => false } }
    @native = { @root['id'] => { 'observation' => { 'status' => 'pass', 'evidence_kind' => 'native-go-only' } } }
    @context = { 'schema' => GoFullResume::CONTEXT_SCHEMA, 'roots' => { @root['id'] => GoFullResume.sha(@root) }, 'execution_environment' => @env }
    executor = Corpus::Executor.allocate
    { '@root' => File.join(@tmp, 'executions'), '@bashy' => @bashy, '@go' => @go, '@env' => @env, '@cache' => @provenance['cache']['path'], '@timeout' => 2, '@provenance' => @provenance }.each { |key, value| executor.instance_variable_set(key, value) }
    @modules = { 'go.mod' => "module fixture.invalid/resume\n\ngo 1.27\n" }
    execution = executor.execute(id: @root['id'], source_root: @source, sources: ['case.go'], module_files: @modules)
    assert_equal 'FAIL', execution['verdict']
    row = { 'id' => @root['id'], 'axis' => 'testdir', 'product_verdict' => 'FAIL', 'native_observation' => @native[@root['id']]['observation'], 'unfinished_phases' => [], 'modes' => {}, 'execution' => execution, 'upstream_output' => GoFullProduct.exact_upstream_output(execution, @root, @source) }
    @checkpoint = File.join(@tmp, 'checkpoint'); FileUtils.mkdir_p(@checkpoint)
    File.write(File.join(@checkpoint, 'context.json'), Corpus.canonical(@context))
    @row = GoFullResume.seal(row, root: @root, source_root: @source, context: @context, provenance: @provenance, evidence: @checkpoint)
    write_rows
  end
  def teardown; FileUtils.rm_rf(@tmp); end
  def write_rows(rows = [@row]); File.write(File.join(@checkpoint, 'roots.jsonl'), rows.map { |r| Corpus.canonical(r) + "\n" }.join); end
  # Update the receipt too: semantic tamper tests must pass the hash envelope
  # before exercising independent source/phase/command/provenance validation.
  def reseal
    path = @row.fetch('retained_record').fetch('path')
    File.write(path, Corpus.canonical(@row.reject { |key, _| key == 'retained_record' }) + "\n")
    @row['retained_record'] = Corpus.file_record(path); write_rows
  end
  def load_checkpoint
    GoFullResume.load(@checkpoint, context: @context, roots: { @root['id'] => @root }, source_root: @source, provenance: @provenance, modules: @modules, native: @native, catalog: {})
  end
  def test_complete_captured_failure_is_reused_as_failure
    result = load_checkpoint
    assert_equal 'FAIL', result['reusable'].fetch(@root['id'])['product_verdict']
  end

  def test_product_executor_stages_share_a_root_bound_durable_lineage
    stages = @row.fetch('execution').fetch('modes').values.flat_map { |mode| mode.fetch('stages') }
    refute_empty stages
    paths = stages.map { |stage| stage.dig('lineage', 'path') }.uniq
    assert_equal 1, paths.length
    assert stages.all? { |stage| stage.dig('lineage', 'root_id') == @root.fetch('id') }
    payloads = Corpus::ProcessLineage.authenticate!(paths.fetch(0))
    assert_equal stages.map { |stage| stage.dig('lineage', 'launch_id') }, payloads.map { |payload| payload.fetch('launch_id') }
    assert payloads.all? { |payload| payload.fetch('stage_id').start_with?(@root.fetch('id') + '/') }
  end
  def test_new_evidence_cache_location_preserves_exact_cache_identity
    @provenance['cache']['path'] = File.join(@tmp, 'new-run/cache')
    assert_equal 'FAIL', load_checkpoint['reusable'].fetch(@root['id'])['product_verdict']
  end
  def test_unsupported_recipe_keeps_full_unfinished_obligations_and_failure
    @root['recipe']['action'] = 'compile'
    @context['roots'][@root['id']] = GoFullResume.sha(@root)
    File.write(File.join(@checkpoint, 'context.json'), Corpus.canonical(@context))
    @row.delete('execution'); @row.delete('upstream_output')
    @row['root_sha256'] = GoFullResume.sha(@root); @row['context_sha256'] = GoFullResume.sha(@context)
    @row['unfinished_phases'] = ['resolve-build-ignore-before-action']
    @row['modes'] = GoFullProduct.probe(@root, { bashy: @bashy, timeout: 2 }, @source, File.join(@tmp, 'probe'),
      { 'root' => File.dirname(File.dirname(@go)) }, { 'launcher_sha256' => Corpus.digest(@bashy), 'payload_sha256' => Corpus.digest(@bashy + '.real') })
    reseal
    reused = load_checkpoint['reusable'].fetch(@root['id'])
    assert_equal 'FAIL', reused['product_verdict']
    assert_equal ['resolve-build-ignore-before-action'], reused['unfinished_phases']
    @row['unfinished_phases'] = ['invented-shorter-phase']; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_adapter_without_complete_captures_requires_fresh_execution
    @row['execution']['modes']['compiled']['state'] = 'missing_artifact'; reseal
    assert_empty load_checkpoint['reusable']
    assert load_checkpoint['fresh'].key?(@root['id'])
  end
  def test_native_duplicate_ids_are_rejected_before_hash_conversion
    assert_raises(Corpus::ContractError) do
      write_rows([@row, @row]); GoFullProduct.unique_rows(File.join(@checkpoint, 'roots.jsonl'))
    end
  end
  def test_context_binds_every_official_root_and_rejects_duplicate_membership
    directory = File.expand_path('../../docs/go-full', __dir__)
    roots = %w[testdir typechecker package].flat_map { |axis| GoFullProduct.read_rows(File.join(directory, axis + '-roots.jsonl')).map { |root| root.merge('axis' => axis) } }
    args = { roots: roots, inventory: {}, sdk: {}, provenance: @provenance, native: {}, modules: @modules, timeout: 2, environment: @env }
    context = GoFullResume.context(**args)
    assert_equal 3495, context.fetch('roots').length
    assert context.fetch('tools').key?('resume.rb')
    assert context.fetch('tools').key?('../corpus/validate.rb')
    assert_raises(Corpus::ContractError) { GoFullResume.context(**args.merge(roots: roots + [roots.first])) }
  end
  def test_duplicate_ids_rejected
    write_rows([@row, @row]); assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_legacy_pass_rejected_without_upgrade
    @row['schema'] = 'go-full-product-root/v1'; @row['product_verdict'] = 'PASS'; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_missing_checkpoint_context_rejected
    File.unlink(File.join(@checkpoint, 'context.json')); assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_forged_pass_rejected_after_resealing
    @row['product_verdict'] = 'PASS'; @row['execution']['verdict'] = 'PASS'; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_missing_phase_rejected_after_resealing
    @row['execution']['modes']['baseline']['stages'] = []; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_native_forwarding_command_rejected_after_resealing
    @row['execution']['modes']['interpreted']['stages'][0]['argv'] = [@go, 'run', 'case.go']; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_environment_rejected_after_resealing
    @row['execution']['modes']['interpreted']['stages'][0]['environment']['GOTOOLCHAIN'] = 'auto'; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_missing_stream_rejected
    File.unlink(@row['execution']['modes']['baseline']['stages'][0]['stdout']['path'])
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_stream_rejected
    File.write(@row['execution']['modes']['baseline']['stages'][0]['stderr']['path'], 'changed')
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_candidate_rejected
    File.write(@bashy + '.real', 'changed'); assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_original_source_rejected
    File.write(File.join(@source, 'case.go'), 'changed'); assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_retained_source_copy_rejected
    File.write(File.join(@row['execution']['modes']['interpreted']['source_directory'], 'case.go'), 'changed')
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_retained_module_copy_rejected
    File.write(File.join(@row['execution']['modes']['interpreted']['source_directory'], 'go.mod'), 'changed')
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_duplicate_stream_rejected_after_resealing
    stage = @row['execution']['modes']['interpreted']['stages'][0]
    stage['stderr'] = stage['stdout']; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_complete_build_checkpoint_passes_then_rejects_environment_and_map_tampering
    # Authored contract tools execute real processes; this is not corpus evidence.
    tool = <<~'RUBY'
      #!/usr/bin/ruby
      require 'json'
      require 'digest'
      if ARGV[0] == 'transpile'
        source = ARGV[3]; output = ARGV[ARGV.index('-o') + 1]
        File.write(output, "package main\n")
        map = { 'schema_version' => 'bashy-transpile-map-v1', 'origin' => source,
          'go_digest' => 'sha256:' + Digest::SHA256.file(output).hexdigest,
          'source_kind' => 'go', 'front_end' => 'gosource-v1', 'mappings' => [],
          'sources' => [{ 'name' => source, 'sha256' => Digest::SHA256.file(source).hexdigest, 'size' => File.size(source), 'base' => 0 }] }
        File.write(ARGV[ARGV.index('--map') + 1], JSON.generate(map))
      elsif ARGV[0] == 'build'
        # A real Go archive: an arbitrary nonempty file is not a build artifact.
        members = { '__.PKGDEF' => "go object authored\n\n!\n", '_go_.o' => "go object authored\n\n!\n\x00go120ld" }
        archive = "!<arch>\n"
        members.each do |name, bytes|
          archive << format('%-16s%-12d%-6d%-6d%-8o%-10d`', name, 0, 0, 0, 0o644, bytes.bytesize) << "\n" << bytes
          archive << "\n" if bytes.bytesize.odd?
        end
        File.binwrite(ARGV[ARGV.index('-o') + 1], archive)
      end
    RUBY
    [@go, @bashy, @bashy + '.real'].each { |path| File.write(path, tool) }
    @provenance['candidate']['launcher'] = Corpus.file_record(@bashy)
    @provenance['candidate']['payload'] = Corpus.file_record(@bashy + '.real')
    @provenance['sdk']['binary'] = Corpus.file_record(@go)
    @root['recipe']['action'] = 'build'; @root.delete('expected_output'); @context['roots'][@root['id']] = GoFullResume.sha(@root)
    File.write(File.join(@checkpoint, 'context.json'), Corpus.canonical(@context))
    executor = Corpus::Executor.allocate
    { '@root' => File.join(@tmp, 'passing'), '@bashy' => @bashy, '@go' => @go, '@env' => @env,
      '@cache' => @provenance['cache']['path'], '@timeout' => 2, '@provenance' => @provenance }.each { |key, value| executor.instance_variable_set(key, value) }
    execution = executor.execute(id: @root['id'], source_root: @source, sources: ['case.go'], phase: 'build', module_files: @modules)
    assert_equal 'PASS', execution['verdict']
    @row.merge!('execution' => execution, 'product_verdict' => 'PASS', 'root_sha256' => GoFullResume.sha(@root), 'context_sha256' => GoFullResume.sha(@context),
      'upstream_output' => GoFullProduct.exact_upstream_output(execution, @root, @source))
    reseal
    assert_equal 'PASS', load_checkpoint['reusable'].fetch(@root['id'])['product_verdict']
    stage = execution['modes']['baseline']['stages'][0]
    stage['environment']['GOTOOLCHAIN'] = 'auto'; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
    stage['environment']['GOTOOLCHAIN'] = 'local'
    map = execution['modes']['compiled']['artifacts']['source_map']
    File.write(map['path'], '{}'); execution['modes']['compiled']['artifacts']['source_map'] = Corpus.file_record(map['path']); reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_missing_provenance_rejected_after_resealing
    @row.delete('provenance'); reseal; assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_changed_declared_full_denominator_rejected
    @context['roots']['unattempted'] = 'different'; assert_raises(Corpus::ContractError) { load_checkpoint }
  end
  def test_upstream_skip_requires_exact_native_and_source_binding
    @row.delete('execution'); @row.delete('upstream_output'); @row['product_verdict'] = 'UPSTREAM_SKIP'
    @native[@root['id']]['observation']['status'] = 'skip'; reseal
    assert_equal 'UPSTREAM_SKIP', load_checkpoint['reusable'][@root['id']]['product_verdict']
    @native[@root['id']]['observation']['status'] = 'pass'; reseal
    assert_raises(Corpus::ContractError) { load_checkpoint }
  end
end
