# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
# Portable contract tests for the compile-only single-file adapter. Every process
# here is a fake tool created by the test, so these tests are hermetic and prove
# harness behaviour only; they are never corpus certification. The real frozen
# candidate/SDK replay lives in compile_adapter_proof_test.rb.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'rbconfig'
require_relative '../../tools/corpus/validate'
require_relative '../../tools/go-full/product'

class CompileAdapterContractTest < Minitest::Test
  GO_OBJECT_MAGIC = "\x00go120ld"

  def setup
    @tmp = Dir.mktmpdir('compile-adapter-')
    @importcfg = File.join(@tmp, 'importcfg-std')
    File.write(@importcfg, "packagefile fmt=#{File.join(@tmp, 'fmt.a')}\n")
    FileUtils.touch(File.join(@tmp, 'fmt.a'))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # An ar container carrying the two members and the goobj magic that the pinned
  # toolchain writes. Byte-identical shape to `go tool compile -o`, built without
  # a toolchain so the contract stays portable.
  def object_archive_bytes(members = nil)
    members ||= { '__.PKGDEF' => "go object test\n\n!\n",
                  '_go_.o' => "go object test\n\n!\n" + GO_OBJECT_MAGIC + "body" }
    out = +"!<arch>\n"
    members.each do |name, body|
      out << format('%-16s%-12d%-6d%-6d%-8o%-10d`', name, 0, 0, 0, 0o644, body.bytesize) << "\n"
      out << body
      out << "\n" if body.bytesize.odd?
    end
    out.b
  end

  def tool(name, body)
    path = File.join(@tmp, name)
    File.write(path, "#!#{RbConfig.ruby}\n" + body)
    File.chmod(0o755, path)
    path
  end

  # A fake `go` that records its argv and then produces exactly what the plan
  # asks for. `plan` is baked into the script: the executor clears the
  # environment, so no variable can smuggle the plan in.
  def fake_go(plan)
    log = File.join(@tmp, 'go-argv.jsonl')
    tool('go', <<~SCRIPT)
      require 'json'
      plan = #{plan.merge('log' => log, 'archive' => object_archive_bytes.unpack1('H*')).inspect}
      File.open(plan['log'], 'a') { |f| f.puts(JSON.generate(ARGV)) }
      out = ARGV[ARGV.index('-o') + 1] if ARGV.include?('-o')
      case plan['behaviour']
      when 'object' then File.binwrite(out, [plan['archive']].pack('H*'))
      when 'junk' then File.binwrite(out, 'not an archive, but certainly not empty')
      when 'empty' then nil
      when 'tamper'
        File.binwrite(plan['tamper_path'], "package p\\n// rewritten by the tool\\n")
        File.binwrite(out, [plan['archive']].pack('H*'))
      when 'fail'
        warn 'source.go:3:14: undefined: x'
        exit 2
      end
      exit 0
    SCRIPT
    [File.realpath(File.join(@tmp, 'go')), log]
  end

  # A fake `bashy` that answers `--check` and emits a marker-free generated file
  # with the exact source map the executor requires.
  def fake_bashy(check_exit: 0)
    tool('bashy', <<~SCRIPT)
      require 'json'
      require 'digest'
      if ARGV.include?('--check')
        exit #{check_exit}
      elsif ARGV.first == 'transpile'
        source = ARGV[ARGV.index('--source=go') + 1]
        generated = ARGV[ARGV.index('-o') + 1]
        map = ARGV[ARGV.index('--map') + 1]
        bytes = File.binread(source)
        File.binwrite(generated, "package main\\n\\nfunc main() {}\\n")
        File.write(map, JSON.generate(
          'schema_version' => 'bashy-transpile-map-v1', 'origin' => source,
          'go_digest' => 'sha256:' + Digest::SHA256.file(generated).hexdigest,
          'source_kind' => 'go', 'front_end' => 'gosource-v1', 'mappings' => [],
          'sources' => [{ 'name' => source, 'sha256' => Digest::SHA256.hexdigest(bytes),
                          'size' => bytes.bytesize, 'base' => 0 }]))
      end
      exit 0
    SCRIPT
    File.realpath(File.join(@tmp, 'bashy'))
  end

  def executor(go:, bashy: '/certainly/not/a/bashy')
    instance = Corpus::Executor.allocate
    instance.instance_variable_set(:@go, go)
    instance.instance_variable_set(:@bashy, bashy)
    instance.instance_variable_set(:@env, { 'PATH' => '/usr/bin:/bin', 'GOTOOLCHAIN' => 'local' })
    instance.instance_variable_set(:@cache, File.join(@tmp, 'cache'))
    instance.instance_variable_set(:@timeout, 30)
    instance.instance_variable_set(:@importcfg, @importcfg)
    instance
  end

  def source(body = "package main\n\nfunc f() {}\n", name = 'main-without-main.go')
    path = File.join(@tmp, name)
    File.write(path, body)
    [{ name => Corpus.file_record(path) }, [name]]
  end

  def run_mode(instance, mode, inputs, sources, phase: 'compile')
    case_dir = File.join(@tmp, 'case')
    FileUtils.mkdir_p(case_dir)
    instance.send(:execute_mode, case_dir, mode, inputs, sources, [], {}, phase, [], {}, nil)
  end

  def test_compile_baseline_uses_the_upstream_compile_recipe_and_never_links
    go, log = fake_go('behaviour' => 'object')
    inputs, sources = source
    result = run_mode(executor(go: go), 'baseline', inputs, sources)

    assert_equal 'complete', result['state'], result.inspect
    assert_equal ['compile'], result['stages'].map { |stage| stage['stage'] }
    argv = result['stages'].fetch(0).fetch('argv')
    object = result.fetch('artifacts').fetch('object').fetch('path')
    assert_equal [go, 'tool', 'compile', '-e', '-p=p', '-importcfg=' + @importcfg, '-o', object, sources.fetch(0)], argv
    # An ordinary `go build` links, so it rejects a valid `package main` that
    # declares no `main`. It can never stand in as the compile oracle.
    refute_includes argv, 'build'
    refute result.fetch('artifacts').key?('native'), 'compile-only phase must not retain a linked program'
    assert_equal @importcfg, result.fetch('import_configuration').fetch('path')
    assert_equal [argv], File.readlines(log).map { |line| JSON.parse(line).unshift(go) }
  end

  def test_compile_interpreted_mode_checks_the_original_source_and_never_runs_it
    inputs, sources = source
    instance = executor(go: '/certainly/not/a/go', bashy: fake_bashy)
    result = run_mode(instance, 'interpreted', inputs, sources)

    assert_equal 'complete', result['state'], result.inspect
    assert_equal ['check'], result['stages'].map { |stage| stage['stage'] }
    argv = result['stages'].fetch(0).fetch('argv')
    assert_equal File.join(@tmp, 'case/interpreted/work', sources.fetch(0)), argv.last, 'the interpreter checks the copied original source itself'
    %w[--bashpp --source=go --check].each { |flag| assert_includes argv, flag }
    assert_empty result.fetch('artifacts')
    refute result.key?('effects'), 'a compile-only obligation never observes runtime effects'
  end

  def test_compile_interpreted_check_failure_is_not_credited
    inputs, sources = source
    instance = executor(go: '/certainly/not/a/go', bashy: fake_bashy(check_exit: 1))
    result = run_mode(instance, 'interpreted', inputs, sources)
    assert_equal 'stage_failure', result['state']
  end

  def test_compiled_mode_requires_a_generated_source_map_and_object_archive
    go, = fake_go('behaviour' => 'object')
    inputs, sources = source
    result = run_mode(executor(go: go, bashy: fake_bashy), 'compiled', inputs, sources)

    assert_equal 'complete', result['state'], result.inspect
    assert_equal %w[transpile compile], result['stages'].map { |stage| stage['stage'] }
    artifacts = result.fetch('artifacts')
    assert_equal %w[generated object source_map], artifacts.keys.sort
    assert_equal artifacts.fetch('generated').fetch('path'), result['stages'].fetch(1).fetch('argv').last
    assert Corpus.go_object_archive?(artifacts.fetch('object').fetch('path'))
  end

  def test_successful_compile_without_an_object_fails_closed
    go, = fake_go('behaviour' => 'empty')
    inputs, sources = source
    result = run_mode(executor(go: go), 'baseline', inputs, sources)
    assert_equal 'missing_artifact', result['state']
    assert_equal 0, result['stages'].fetch(0).fetch('exit')
    refute result.fetch('artifacts').key?('object')
  end

  def test_nonempty_output_that_is_not_a_go_archive_is_not_a_compile_result
    go, = fake_go('behaviour' => 'junk')
    inputs, sources = source
    result = run_mode(executor(go: go), 'baseline', inputs, sources)
    assert_equal 'missing_artifact', result['state']
    refute result.fetch('artifacts').key?('object')
  end

  def test_compile_diagnostics_are_a_stage_failure_never_a_pass
    go, = fake_go('behaviour' => 'fail')
    inputs, sources = source("package p\n\nfunc bad() { x }\n", 'bad.go')
    result = run_mode(executor(go: go), 'baseline', inputs, sources)
    assert_equal 'stage_failure', result['state']
    assert_equal 2, result['stages'].fetch(0).fetch('exit')
    assert_match(/undefined: x/, File.binread(result['stages'].fetch(0).fetch('stderr').fetch('path')))
  end

  def test_source_rewritten_by_the_toolchain_fails_closed
    inputs, sources = source
    tampered = File.join(@tmp, 'case/baseline/work', sources.fetch(0))
    go, = fake_go('behaviour' => 'tamper', 'tamper_path' => tampered)
    result = run_mode(executor(go: go), 'baseline', inputs, sources)

    assert_equal 'input_mutation', result['state']
    refute result['input_integrity']
    assert_includes result.fetch('input_checks').map { |check| check['valid'] }, false
    # The immutable upstream input itself is untouched.
    assert_equal inputs.fetch(sources.fetch(0)).fetch('sha256'), Corpus.digest(File.join(@tmp, sources.fetch(0)))
  end

  def test_object_archive_validator_rejects_malformed_and_foreign_files
    path = File.join(@tmp, 'candidate.o')
    write = lambda do |bytes|
      File.binwrite(path, bytes)
      Corpus.go_object_archive?(path)
    end

    assert write.call(object_archive_bytes)
    refute write.call(''), 'empty file'
    refute write.call('not an archive'), 'arbitrary nonempty file'
    refute write.call(object_archive_bytes[0, 40]), 'truncated member header'
    refute write.call(object_archive_bytes + 'trailing'), 'trailing garbage outside the members'
    refute write.call(object_archive_bytes('__.PKGDEF' => "go object test\n")), 'missing compiled object member'
    refute write.call(object_archive_bytes('_go_.o' => "go object test\n" + GO_OBJECT_MAGIC)), 'missing package export member'
    refute write.call(object_archive_bytes('__.PKGDEF' => "go object test\n\n!\n",
                                           '_go_.o' => "go object test\n\n!\nno magic here")), 'object member without goobj magic'
    refute write.call(object_archive_bytes('__.PKGDEF' => 'foreign export data',
                                           '_go_.o' => 'foreign' + GO_OBJECT_MAGIC)), 'members that are not Go objects'
    refute Corpus.native_binary?(path.tap { File.binwrite(path, object_archive_bytes) }), 'an archive is not a native program'
  end

  def test_compile_verdict_requires_every_mode_to_complete_with_intact_input
    complete = Corpus::MODES.to_h { |mode| [mode, { 'state' => 'complete', 'input_integrity' => true }] }
    instance = executor(go: '/certainly/not/a/go')
    assert_equal 'PASS', instance.send(:exact_verdict, 'modes' => complete, 'phase' => 'compile')
    Corpus::MODES.each do |mode|
      broken = complete.merge(mode => { 'state' => 'stage_failure', 'input_integrity' => true })
      assert_equal 'FAIL', instance.send(:exact_verdict, 'modes' => broken, 'phase' => 'compile'), mode
      mutated = complete.merge(mode => { 'state' => 'complete', 'input_integrity' => false })
      assert_equal 'FAIL', instance.send(:exact_verdict, 'modes' => mutated, 'phase' => 'compile'), mode
    end
  end

  def test_directory_and_link_phases_are_still_refused_by_name
    instance = executor(go: '/certainly/not/a/go')
    authenticated = %w[launcher payload sdk].to_h do |name|
      path = File.join(@tmp, name)
      File.write(path, name)
      [name, { 'path' => path, 'sha256' => Corpus.digest(path) }]
    end
    instance.instance_variable_set(:@provenance, 'candidate' => { 'launcher' => authenticated.fetch('launcher'), 'payload' => authenticated.fetch('payload') },
                                                 'sdk' => { 'binary' => authenticated.fetch('sdk') })
    File.write(File.join(@tmp, 'a.go'), "package p\n")
    %w[compiledir builddir link buildrun].each do |phase|
      error = assert_raises(Corpus::ContractError) do
        instance.execute(id: 'phase-' + phase, source_root: @tmp, sources: ['a.go'], phase: phase)
      end
      assert_equal 'unknown phase', error.message, phase
    end
  end

  def test_only_plain_unflagged_compile_recipes_enter_the_adapter
    root = { 'recipe' => { 'action' => 'compile', 'flags' => [], 'args' => [], 'environment_append' => [] },
             'expected_failure_sets' => [] }
    assert GoFullProduct.simple_recipe?(root)
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('flags' => ['-tags=magic'])))
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('environment_append' => [%w[GODEBUG x=1]])))
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('timeout_seconds_before_scale' => 5)))
    refute GoFullProduct.simple_recipe?(root.merge('expected_failure_sets' => ['types2']))
    %w[compiledir directory generated_program program_directory_inputs nested_process_obligation].each do |key|
      next if key == 'compiledir'
      refute GoFullProduct.simple_recipe?(root.merge(key => {})), key
    end
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('action' => 'compiledir')))
  end
end
