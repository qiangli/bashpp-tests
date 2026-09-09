# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
#
# Bounded REAL replay of the compile-only adapter against the frozen Sprint118
# runtime candidate 010 and the pinned relocated Go SDK, on unchanged upstream
# GOROOT/test sources. This file is deliberately separate from the hermetic
# contract tests in compile_adapter_test.rb: it executes authenticated tools, so
# it is evidence, while those are harness unit tests.
#
# It never skips itself into credit. When an input is unavailable the run fails
# and names the missing path, because a silent skip would look like a pass.
#
#   ruby tests/go-full/compile_adapter_proof_test.rb
#
# Locations may be overridden for a relocated freeze:
#   GO_FULL_SOURCE_ROOT   GOROOT/test source tree (default below)
#   GO_FULL_SDK_IDENTITY  relocated SDK identity manifest
#   GO_FULL_CANDIDATE     frozen candidate manifest
#   GO_FULL_BASHY         frozen candidate launcher
#   GO_FULL_CACHE_ROOT    shared Go build cache root
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../tools/corpus/validate'
require_relative '../../tools/go-full/resume'

class CompileAdapterFrozenReplayTest < Minitest::Test
  DEFAULTS = {
    'GO_FULL_SOURCE_ROOT' => '/Users/qiangli/.bashy/sprint118/sources/go-full/go',
    'GO_FULL_SDK_IDENTITY' => '/Users/qiangli/.bashy/sprint118/sources/go-full-sdk-identity-relocated.json',
    'GO_FULL_CANDIDATE' => '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-010/candidate.json',
    'GO_FULL_BASHY' => '/private/tmp/s118-runtime-010/bashy/bin/bashy'
  }.freeze

  # One unchanged upstream root per plain compile-only shape. No wrapping, no
  # edits: these are the exact `// compile` sources the toolchain ships.
  ROOTS = {
    'package p without imports' => 'test/typeparam/issue47966.go',
    'package main that declares no main' => 'test/fixedbugs/issue17111.go',
    'package main with imports and no main' => 'test/fixedbugs/issue17710.go'
  }.freeze

  # An unchanged upstream compile root the frozen candidate still cannot lower
  # (`unsafe` import). It is replayed here to prove it keeps failing: the compile
  # adapter must not hand partial credit to a root the product cannot compile.
  RETAINED_FAILURE = 'test/fixedbugs/issue17270.go'

  def location(key)
    path = ENV.fetch(key, DEFAULTS.fetch(key))
    flunk "#{key} is unavailable: #{path}. Point it at the frozen candidate 010 inputs; a skipped replay is not a pass." unless File.exist?(path)
    path
  end

  def setup
    @source_root = location('GO_FULL_SOURCE_ROOT')
    @sdk_identity = JSON.parse(File.read(location('GO_FULL_SDK_IDENTITY')))
    @candidate = JSON.parse(File.read(location('GO_FULL_CANDIDATE')))
    @bashy = location('GO_FULL_BASHY')
    @tmp = Dir.mktmpdir('compile-proof-')
    (ROOTS.values + [RETAINED_FAILURE]).each do |path|
      flunk "upstream source is unavailable: #{path}" unless File.file?(File.join(@source_root, path))
    end
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def executor
    sdk = { 'sha256' => @sdk_identity.fetch('go').fetch('sha256'),
            'identity' => "go version #{@sdk_identity.fetch('release')} #{@sdk_identity.fetch('goos')}/#{@sdk_identity.fetch('goarch')}" }
    Corpus::Executor.new(bashy: @bashy, go: File.join(@sdk_identity.fetch('root'), 'bin/go'),
                         evidence_root: File.join(@tmp, 'evidence'), candidate: @candidate, sdk: sdk,
                         env: { 'GOTOOLCHAIN' => 'local', 'GOMAXPROCS' => '2' }, timeout: 120,
                         cache_root: ENV['GO_FULL_CACHE_ROOT'] || File.join(@tmp, 'cache'))
  end

  def obligation(record)
    %w[phase sources assets inputs args module_files package_input runtime_environment]
      .to_h { |field| [field, record.fetch(field)] }
  end

  def test_frozen_candidate_compiles_every_plain_upstream_compile_shape
    instance = executor
    records = ROOTS.map do |shape, path|
      record = instance.execute(id: 'compile:' + path, source_root: @source_root, sources: [path], phase: 'compile')

      assert_equal 'compile', record.fetch('phase')
      assert_equal 'PASS', record.fetch('verdict'), "#{shape} (#{path}) did not compile in all three modes"
      assert_equal Corpus::MODES, record.fetch('modes').keys

      record.fetch('modes').each do |mode, result|
        assert_equal 'complete', result.fetch('state'), "#{shape}/#{mode}"
        assert result.fetch('input_integrity'), "#{shape}/#{mode}"
        expected_stages = { 'baseline' => ['compile'], 'interpreted' => ['check'], 'compiled' => %w[transpile compile] }
        assert_equal expected_stages.fetch(mode), result.fetch('stages').map { |stage| stage['stage'] }, "#{shape}/#{mode}"
        next if mode == 'interpreted'

        argv = result.fetch('stages').last.fetch('argv')
        assert_equal %w[tool compile -e -p=p], argv[1, 4], "#{shape}/#{mode} must use the upstream compile recipe"
        object = result.fetch('artifacts').fetch('object')
        assert Corpus.go_object_archive?(object.fetch('path')), "#{shape}/#{mode} produced no Go object archive"
        refute Corpus.native_binary?(object.fetch('path')), "#{shape}/#{mode} linked a program for a compile-only root"
        refute result.fetch('artifacts').key?('native')
      end
      assert record.dig('modes', 'compiled', 'artifacts', 'generated'), "#{shape} kept no generated source"
      # The resume replay shares this verdict rule; a checkpoint must agree.
      assert_equal record.fetch('verdict'), GoFullResume.execution_verdict(record), shape
      record
    end

    expected = records.to_h { |record| [record.fetch('id'), obligation(record)] }
    assert Corpus::Validation.validate!(records, expected: expected, provenance: instance.provenance)
  end

  def test_go_build_would_reject_a_valid_compile_only_main_package
    # The defect this adapter exists to fix: `go build` links, so it rejects an
    # unchanged upstream `// compile` root that declares no main. Proving that
    # here keeps anyone from restoring a link-required oracle.
    go = File.realpath(File.join(@sdk_identity.fetch('root'), 'bin/go'))
    source = File.join(@source_root, ROOTS.fetch('package main that declares no main'))
    refute_match(/^func main\(/, File.read(source), 'the chosen root must genuinely declare no main')

    env = { 'PATH' => '/usr/bin:/bin', 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off',
            'HOME' => File.join(@tmp, 'home'), 'TMPDIR' => File.join(@tmp, 'tmp'), 'GOCACHE' => File.join(@tmp, 'gocache') }
    %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(env.fetch(key)) }
    work = File.join(@tmp, 'link-probe')
    FileUtils.mkdir_p(work)
    FileUtils.cp(source, File.join(work, 'input.go'))

    build = Corpus.capture([go, 'build', '-o', File.join(work, 'program'), 'input.go'],
                           cwd: work, log_prefix: File.join(work, 'build'), env: env, timeout: 120)
    refute Corpus.success?(build), 'go build unexpectedly linked a main package with no main'
    assert_match(/function main is undeclared/, File.binread(build.fetch('stderr').fetch('path')))
  end

  def test_validator_rejects_a_linked_build_substituted_for_a_compile_stage
    instance = executor
    path = ROOTS.fetch('package p without imports')
    record = instance.execute(id: 'substitution:' + path, source_root: @source_root, sources: [path], phase: 'compile')
    assert_equal 'PASS', record.fetch('verdict')
    expected = { record.fetch('id') => obligation(record) }
    assert Corpus::Validation.validate!([record], expected: expected, provenance: instance.provenance)

    substituted = JSON.parse(Corpus.canonical(record))
    stage = substituted.fetch('modes').fetch('baseline').fetch('stages').fetch(0)
    stage['argv'] = [stage.fetch('argv').fetch(0), 'build', '-o', stage.fetch('argv')[-2], stage.fetch('argv').last]
    error = assert_raises(Corpus::ContractError) do
      Corpus::Validation.validate!([substituted], expected: expected, provenance: instance.provenance)
    end
    assert_match(/compile/, error.message)

    forged = JSON.parse(Corpus.canonical(record))
    object = forged.dig('modes', 'baseline', 'artifacts', 'object')
    File.binwrite(object.fetch('path'), 'nonempty but not a Go object archive')
    object['bytes'] = File.size(object.fetch('path'))
    object['sha256'] = Corpus.digest(object.fetch('path'))
    error = assert_raises(Corpus::ContractError) do
      Corpus::Validation.validate!([forged], expected: expected, provenance: instance.provenance)
    end
    assert_match(/Go object archive/, error.message)
  end

  def test_a_candidate_limitation_stays_a_failure_without_partial_credit
    instance = executor
    record = instance.execute(id: 'retained:' + RETAINED_FAILURE, source_root: @source_root,
                              sources: [RETAINED_FAILURE], phase: 'compile')
    modes = record.fetch('modes')
    complete = modes.values.all? { |result| result['state'] == 'complete' && result['input_integrity'] }
    assert_equal complete, record.fetch('verdict') == 'PASS', 'the verdict must follow the modes, never a partial stage'
    assert_equal record.fetch('verdict'), GoFullResume.execution_verdict(record)

    modes.each do |mode, result|
      next if result['state'] == 'complete'
      refute result.fetch('artifacts').key?('object'), "#{mode} claimed a compile artifact for an incomplete obligation"
    end
    # The unchanged upstream bytes are the ones that were replayed either way.
    assert_equal Corpus.digest(File.join(@source_root, RETAINED_FAILURE)),
                 record.fetch('inputs').fetch(RETAINED_FAILURE).fetch('sha256')

    expected = { record.fetch('id') => obligation(record) }
    unless record.fetch('verdict') == 'PASS'
      assert_raises(Corpus::ContractError) do
        Corpus::Validation.validate!([record], expected: expected, provenance: instance.provenance)
      end
    end
  end
end
