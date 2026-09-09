# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Contract tests only; no fixture executable is treated as product coverage.
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/go-by-example/inputs'
require_relative '../../tools/go-by-example/normalizer'
require_relative '../../tools/go-by-example/candidate'
require_relative '../../tools/go-by-example/runtime-config'

class GoByExampleGateContractTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('gbe-input-contract-')
  end
  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_extra_goroutine_output_is_not_normalized_away
    good = "direct : 0\ndirect : 1\ndirect : 2\ngoroutine : 0\ngoing\ngoroutine : 1\ngoroutine : 2\ndone\n"
    assert GoByExampleNormalizer.normalize(good, ['interleave_order'], :stdout)
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(good.sub("going\n", "going\nUNEXPECTED PRODUCT OUTPUT\n"), ['interleave_order'], :stdout) }
  end

  def test_extra_worker_and_job_ids_are_rejected
    workers = (1..5).map { |id| "Worker #{id} starting\nWorker #{id} done\n" }.join
    assert GoByExampleNormalizer.normalize(workers, ['interleave_order'], :stdout)
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(workers + "Worker 99 starting\nWorker 99 done\n", ['interleave_order'], :stdout) }
    pool = (1..5).map { |job| "worker 1 started  job #{job}\nworker 1 finished job #{job}\n" }.join
    assert GoByExampleNormalizer.normalize(pool, ['interleave_order'], :stdout)
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(pool + "worker 1 started  job 99\nworker 1 finished job 99\n", ['interleave_order'], :stdout) }
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(pool.gsub('worker 1', 'worker 99'), ['interleave_order'], :stdout) }
  end

  def test_real_phase_mutations_fail_closed_for_source_driver_and_asset
    %w[original_test.go gbe_test_driver.go asset.txt].each { |name| File.write(File.join(@root, name), name) }
    %w[original_test.go gbe_test_driver.go asset.txt].each do |name|
      path = File.join(@root, name)
      before = File.binread(path)
      binding = GoByExampleInputs.new(@root)
      assert binding.unchanged?
      stage = Corpus.capture([RbConfig.ruby, '-e', 'File.write(ARGV.fetch(0), "changed")', path], cwd: @root,
                             env: {}, timeout: 5, log_prefix: File.join(Dir.tmpdir, "gbe-contract-#{Process.pid}-#{name}"))
      assert Corpus.success?(stage)
      result = GoByExampleInputs.enforce({'state' => 'complete'}, [binding])
      assert_equal 'input_mutation', result.fetch('state')
      File.binwrite(path, before)
      [stage['stdout']['path'], stage['stderr']['path']].each { |log| File.delete(log) }
    end
  end

  def test_independent_mode_copies_do_not_change_each_other
    left, right = %w[compiled interpreted].map { |mode| File.join(@root, mode) }
    [left, right].each { |dir| FileUtils.mkdir_p(dir); File.write(File.join(dir, 'original.go'), 'package main') }
    compiled, interpreted = [left, right].map { |dir| GoByExampleInputs.new(dir) }
    File.write(File.join(left, 'original.go'), 'changed')
    refute compiled.unchanged?
    assert interpreted.unchanged?
  end

  def test_build_metadata_additions_do_not_license_input_mutation
    File.write(File.join(@root, 'main.go'), 'original')
    binding = GoByExampleInputs.new(@root, allow_additions: true)
    File.write(File.join(@root, 'go.sum'), 'new build metadata')
    assert binding.unchanged?
    File.write(File.join(@root, 'main.go'), 'modified')
    refute binding.unchanged?
  end

  def test_default_recipe_is_allowed_but_manifest_recipe_must_match
    original = GoByExampleCandidate.table
    row = original.find { |r| r[0, 2] == GoByExampleCandidate.host }.dup
    row[7] = 'GOTOOLCHAIN=go1.27.0 make build'
    table = File.join(@root, 'candidates.tsv')
    File.write(table, row.join("\t") + "\n")
    reviewed = GoByExampleCandidate.reviewed(table)
    assert_equal row[7], reviewed.fetch('build_recipe')
    manifest = reviewed.slice('launcher_sha256', 'payload_sha256', 'frontend_version', 'build_recipe')
    manifest['build_recipe'] += ' BASHY_GOSOURCE=1'
    path = File.join(@root, 'candidate.json')
    File.write(path, JSON.generate(manifest))
    reviewed['manifest_sha256'] = Corpus.digest(path)
    error = assert_raises(GoByExampleCandidate::Error) { GoByExampleCandidate.authenticate(path, '/missing/product', reviewed, {'identity' => reviewed.fetch('go_identity')}) }
    assert_match 'build_recipe differs', error.message
  end
  def test_reviewed_candidate_history_uses_exact_manifest_identity
    rows = GoByExampleCandidate.table.select { |row| row[0, 2] == GoByExampleCandidate.host }
    assert_operator rows.size, :>=, 2
    rows.each do |row|
      assert_equal row[2], GoByExampleCandidate.reviewed(manifest_sha256: row[2]).fetch('manifest_sha256')
    end
    assert_raises(GoByExampleCandidate::Error) { GoByExampleCandidate.reviewed(manifest_sha256: 'f' * 64) }
  end

  def test_real_sdk_telemetry_configuration_precedes_effect_baseline
    go = ENV.fetch('CORPUS_TEST_GO') { ENV.fetch('PATH').split(':').map { |dir| File.join(dir, 'go') }.find { |path| File.executable?(path) } }
    skip 'Go SDK not available' unless go
    home = File.join(@root, 'home'); FileUtils.mkdir_p(home)
    env = {'HOME' => home, 'PATH' => '', 'GOTOOLCHAIN' => 'local', 'OTEL_TRACES_EXPORTER' => 'none'}
    record = GoByExampleRuntimeConfig.configure(File.realpath(go), @root, env,
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20, log_prefix: File.join(@root, 'setup-log'))
    assert_equal 'complete', record['state'], record.inspect
    assert_equal 'off', record['go_mode']
    assert_equal Corpus.file_record(record['mode_file']['path']), record['mode_file']
    baseline = Corpus.snapshot(home)
    stage = Corpus.capture([File.realpath(go), 'env', 'GOTELEMETRY'], cwd: @root, env: env, timeout: 10, log_prefix: File.join(@root, 'check-log'))
    assert Corpus.success?(stage)
    assert_equal "off\n", File.read(stage['stdout']['path'])
    assert_equal baseline, Corpus.snapshot(home), 'disabled Go telemetry created new runtime HOME effects'
  end

  def observation(name, mode, stream = 'stdout')
    File.binread(File.join(__dir__, 'fixtures/observations', "#{name}.#{mode}.#{stream}.txt"))
  end

  def test_real_volatile_observations_preserve_declared_invariants
    {'time' => 'wallclock', 'stateful-goroutines' => 'throughput_count', 'execing-processes' => 'file_metadata'}.each do |name, normalization|
      assert_equal GoByExampleNormalizer.normalize(observation(name, 'oracle'), [normalization], :stdout),
                   GoByExampleNormalizer.normalize(observation(name, 'compiled'), [normalization], :stdout), name
    end
    lines = observation('time', 'oracle').lines
    lines[18] = (Integer(lines[18]) + 1).to_s + "\n"
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(lines.join, ['wallclock'], :stdout) }
    lines = observation('time', 'oracle').lines
    lines[2] = "2010\n"
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(lines.join, ['wallclock'], :stdout) }
    good = observation('stateful-goroutines', 'oracle')
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(good + "readOps: 1\n", ['throughput_count'], :stdout) }
    assert_raises(RuntimeError) { GoByExampleNormalizer.normalize(good.sub(/readOps: \d+/, 'readOps: 0'), ['throughput_count'], :stdout) }
    listing = observation('execing-processes', 'oracle')
    refute_equal GoByExampleNormalizer.normalize(listing, ['file_metadata'], :stdout),
                 GoByExampleNormalizer.normalize(listing.sub(' home', ' unexpected'), ['file_metadata'], :stdout)
  end

  def test_logging_clocks_normalize_but_source_positions_remain_observable
    native = observation('logging', 'oracle', 'stderr')
    shifted = native.gsub('2026/09/09', '2026/09/10').gsub('2026-09-09', '2026-09-10')
    assert_equal GoByExampleNormalizer.normalize(native, ['wallclock'], :stderr), GoByExampleNormalizer.normalize(shifted, ['wallclock'], :stderr)
    refute_equal GoByExampleNormalizer.normalize(native, ['wallclock'], :stderr), GoByExampleNormalizer.normalize(observation('logging', 'compiled', 'stderr'), ['wallclock'], :stderr)
  end

  def test_retained_observation_provenance_matches_real_bytes
    dir = File.join(__dir__, 'fixtures/observations')
    provenance = JSON.parse(File.read(File.join(dir, 'provenance.json')))
    provenance.fetch('files').each { |file| assert_equal file.fetch('sha256'), Corpus.digest(File.join(dir, file.fetch('file'))) }
  end

end
