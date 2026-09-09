# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
#
# Bounded REAL replay of the compile-only adapter against the frozen Sprint118
# runtime candidate and the pinned relocated Go SDK, on unchanged upstream
# GOROOT/test sources. This file is deliberately separate from the hermetic
# contract tests in compile_adapter_test.rb: it executes authenticated tools, so
# it is evidence, while those are harness unit tests.
#
# It carries NO host paths. Every location is supplied explicitly, so the file
# stays portable and cannot quietly bind itself to one machine's freeze. It also
# never skips itself into credit: when the configuration or an input is missing
# the run fails and names it, because a silent skip would look like a pass.
#
#   GO_FULL_PROOF_CONFIG=<config.json> ruby tests/go-full/compile_adapter_proof_test.rb
#
# The config is a JSON object; every key may also be given as the matching
# GO_FULL_* environment variable, which wins over the file.
#
#   source_root     GOROOT/test source tree
#   sdk_identity    relocated SDK identity manifest
#   candidate       frozen candidate manifest
#   bashy           frozen candidate launcher
#   receipts        durable directory for the raw execution records (REQUIRED)
#   cache_root      shared Go build cache root (optional)
#
# The raw records are written under `receipts` and are NEVER deleted by this
# test: they are the manager-reviewable evidence. Only scratch is cleaned up.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'time'
require_relative '../../tools/corpus/validate'
require_relative '../../tools/go-full/resume'

class CompileAdapterFrozenReplayTest < Minitest::Test
  LOCATIONS = %w[source_root sdk_identity candidate bashy receipts cache_root].freeze
  REQUIRED = %w[source_root sdk_identity candidate bashy receipts].freeze

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

  def configuration
    @configuration ||= begin
      path = ENV['GO_FULL_PROOF_CONFIG']
      file = if path.nil? || path.empty?
               {}
             else
               flunk "GO_FULL_PROOF_CONFIG is unavailable: #{path}" unless File.file?(path)
               JSON.parse(File.read(path))
             end
      LOCATIONS.to_h { |key| [key, ENV.fetch('GO_FULL_' + key.upcase, file[key])] }.compact
    end
  end

  def location(key)
    value = configuration[key]
    if value.nil? || value.to_s.empty?
      flunk "#{key} is not configured. Set GO_FULL_PROOF_CONFIG (or GO_FULL_#{key.upcase}) " \
            'to the frozen candidate inputs; a skipped replay is not a pass.'
    end
    flunk "#{key} is unavailable: #{value}. Point it at the frozen candidate inputs; a skipped replay is not a pass." unless key == 'receipts' || File.exist?(value)
    value
  end

  def setup
    REQUIRED.each { |key| location(key) }
    @source_root = location('source_root')
    @sdk_identity = JSON.parse(File.read(location('sdk_identity')))
    @candidate = JSON.parse(File.read(location('candidate')))
    @bashy = location('bashy')
    # Durable, manager-reviewable raw records in the explicitly configured path.
    # One directory per run so a replay never overwrites retained evidence.
    @receipts = File.join(File.expand_path(location('receipts')),
                          Time.now.utc.strftime('%Y%m%dT%H%M%SZ') + "-#{Process.pid}")
    FileUtils.mkdir_p(@receipts)
    @tmp = Dir.mktmpdir('compile-proof-scratch-')
    (ROOTS.values + [RETAINED_FAILURE]).each do |path|
      flunk "upstream source is unavailable: #{path}" unless File.file?(File.join(@source_root, path))
    end
  end

  # Only scratch is removed. The retained raw records under @receipts survive the
  # run: deleting them would leave the replay unreviewable.
  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
    retain_index if @receipts && File.directory?(@receipts)
  end

  # A flat index of every retained raw record, so a manager can check the run
  # without walking the evidence tree.
  def retain_index
    records = Dir.glob(File.join(@receipts, '**', 'result.json')).sort
    File.write(File.join(@receipts, 'receipts.json'), Corpus.canonical(
      'schema' => 'compile-adapter-proof/v1', 'name' => self.name,
      'prepared_at' => Time.now.utc.iso8601, 'source_root' => @source_root,
      'records' => records.map { |path| Corpus.file_record(path) }
    ) + "\n")
  end

  def executor(name)
    sdk = { 'sha256' => @sdk_identity.fetch('go').fetch('sha256'),
            'identity' => "go version #{@sdk_identity.fetch('release')} #{@sdk_identity.fetch('goos')}/#{@sdk_identity.fetch('goarch')}" }
    Corpus::Executor.new(bashy: @bashy, go: File.join(@sdk_identity.fetch('root'), 'bin/go'),
                         evidence_root: File.join(@receipts, name), candidate: @candidate, sdk: sdk,
                         env: { 'GOTOOLCHAIN' => 'local', 'GOMAXPROCS' => '2' }, timeout: 120,
                         cache_root: configuration['cache_root'] || File.join(@tmp, 'cache'))
  end

  def obligation(record)
    %w[phase sources assets inputs args module_files package_input runtime_environment]
      .to_h { |field| [field, record.fetch(field)] }
  end

  # Every compile mode must name an import configuration that still
  # authenticates: prepared by this run's SDK with the exact bounded, captured
  # `go list -export ... std` recipe, and every packagefile archive unchanged.
  def assert_authenticated_import_configuration(result, provenance, label)
    configuration = result.fetch('import_configuration')
    assert Corpus.authenticate_import_configuration!(configuration, tool: provenance.dig('sdk', 'binary')), label
    preparation = configuration.fetch('preparation')
    assert_equal 'exited', preparation.fetch('state'), label
    assert_equal false, preparation.fetch('descendants_survived'), label
    assert preparation.fetch('timeout_seconds').positive?, label
    assert configuration.fetch('packages').any? { |package| package.fetch('name') == 'fmt' }, label
  end

  def test_frozen_candidate_compiles_every_plain_upstream_compile_shape
    instance = executor('plain-compile-shapes')
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
        assert_authenticated_import_configuration(result, instance.provenance, "#{shape}/#{mode}")
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
    records.each { |record| assert File.file?(File.join(@receipts, 'plain-compile-shapes', record.fetch('id'), 'result.json')) }
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
    work = File.join(@receipts, 'link-probe')
    FileUtils.mkdir_p(work)
    FileUtils.cp(source, File.join(work, 'input.go'))

    build = Corpus.capture([go, 'build', '-o', File.join(work, 'program'), 'input.go'],
                           cwd: work, log_prefix: File.join(work, 'build'), env: env, timeout: 120)
    refute Corpus.success?(build), 'go build unexpectedly linked a main package with no main'
    assert_match(/function main is undeclared/, File.binread(build.fetch('stderr').fetch('path')))
    File.write(File.join(work, 'receipt.json'), Corpus.canonical(build) + "\n")
  end

  def test_validator_rejects_a_linked_build_substituted_for_a_compile_stage
    instance = executor('substitution')
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

    # An import configuration that no longer authenticates cannot certify a
    # compile stage, even when the object archive itself is genuine. Editing a
    # retained archive digest is caught by the package-set seal; re-sealing the
    # forgery is then caught by re-hashing the archive on disk. Both layers are
    # exercised here without touching the shared cache.
    %w[seal rehash].each do |layer|
      unauthenticated = JSON.parse(Corpus.canonical(record))
      unauthenticated.fetch('modes').each_value do |result|
        next unless result.key?('import_configuration')
        configuration = result.fetch('import_configuration')
        configuration.fetch('packages').first.fetch('archive')['sha256'] = '0' * 64
        configuration['packages_sha256'] = Digest::SHA256.hexdigest(Corpus.canonical(configuration.fetch('packages'))) if layer == 'rehash'
      end
      error = assert_raises(Corpus::ContractError) do
        Corpus::Validation.validate!([unauthenticated], expected: expected, provenance: instance.provenance)
      end
      expected_message = layer == 'seal' ? /package set changed/ : /stdlib archive changed since preparation/
      assert_match(expected_message, error.message, layer)
    end

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
    instance = executor('retained-failure')
    record = instance.execute(id: 'retained:' + RETAINED_FAILURE, source_root: @source_root,
                              sources: [RETAINED_FAILURE], phase: 'compile')
    modes = record.fetch('modes')
    complete = modes.values.all? { |result| result['state'] == 'complete' && result['input_integrity'] }
    assert_equal complete, record.fetch('verdict') == 'PASS', 'the verdict must follow the modes, never a partial stage'
    assert_equal record.fetch('verdict'), GoFullResume.execution_verdict(record)

    modes.each do |mode, result|
      # A failing prefix still names the exact configuration it compiled against.
      assert_authenticated_import_configuration(result, instance.provenance, mode) if result.key?('import_configuration')
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
