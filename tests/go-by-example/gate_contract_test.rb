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
      result = GoByExampleInputs.enforce({'state' => 'complete'}, [binding], [:shared])
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

  # --- Sprint 118 / Story #3: mode-scoped input bindings -------------------
  #
  # candidate007 made examples/signals and examples/tcp-server actually reach
  # their blocking call instead of exiting early with a diagnostic, so for the
  # first time the interpreted run was terminated by a signal (SIGINT from the
  # signal_injector adapter; SIGKILL at the run deadline). Killed that way the
  # interpreter never unlinks the .bashpp-eval-<n>/ scratch directory it creates
  # BESIDE the source file, so an entry appeared in src/interpreted. That is a
  # real mutation of a bound tree and the interpreted attempt must fail for it.
  #
  # What must NOT happen is what did happen: a single flat binding list meant
  # the interpreted leftover also made the *compiled* spawn guard false, so the
  # compiled run never started even though its own inputs were intact and its
  # native binary had already built. Two attempts were recorded unspawned and
  # the 255-attempt replay came back incomplete.

  def leftover_interpreter_scratch(dir)
    scratch = File.join(dir, '.bashpp-eval-1850870387')
    FileUtils.mkdir_p(scratch)
    File.write(File.join(scratch, 'bashpp-session-166838444.go'), 'package main')
    scratch
  end

  def test_interpreter_scratch_leak_fails_its_own_mode_and_not_the_others
    trees = %w[interpreted compiled].to_h do |mode|
      dir = File.join(@root, 'src', mode)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'signals.go'), 'package main')
      [mode, dir]
    end
    corpus = File.join(@root, 'examples', 'signals')
    FileUtils.mkdir_p(corpus)
    File.write(File.join(corpus, 'signals.go'), 'package main')

    bindings = [GoByExampleInputs.new(corpus, scope: :shared),
                GoByExampleInputs.new(trees.fetch('interpreted'), scope: :interpreted),
                GoByExampleInputs.new(trees.fetch('compiled'), scope: :compiled)]

    # A signal-killed interpreter leaves its scratch directory behind.
    leftover_interpreter_scratch(trees.fetch('interpreted'))

    # The mode that leaked is charged, and the evidence names the tree.
    interpreted = GoByExampleInputs.enforce({'state' => 'complete'}, bindings, [:shared, :interpreted])
    assert_equal 'input_mutation', interpreted.fetch('state')
    assert_includes interpreted.fetch('detail'), trees.fetch('interpreted')
    assert_includes interpreted.fetch('detail'), '.bashpp-eval-1850870387'
    refute GoByExampleInputs.intact?(bindings, [:shared, :interpreted])

    # The modes that did not leak still hold intact inputs and must still run.
    assert GoByExampleInputs.intact?(bindings, [:shared, :compiled]),
           'compiled inputs were untouched; its run must not be suppressed'
    compiled = GoByExampleInputs.enforce({'state' => 'complete'}, bindings, [:shared, :compiled])
    assert_equal 'complete', compiled.fetch('state')
    assert_nil compiled['detail']
  end

  # The same defect driven through the real capture lifecycle: a child that
  # creates its scratch directory beside the source and then blocks is killed at
  # the deadline exactly as bashy was on examples/tcp-server, so the cleanup it
  # would have run on a normal exit never happens.
  def test_deadline_killed_child_leaks_scratch_and_only_its_own_mode_fails
    interpreted = File.join(@root, 'src', 'interpreted')
    compiled = File.join(@root, 'src', 'compiled')
    [interpreted, compiled].each do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'tcp-server.go'), 'package main')
    end
    bindings = [GoByExampleInputs.new(interpreted, scope: :interpreted),
                GoByExampleInputs.new(compiled, scope: :compiled)]

    program = <<~RUBY
      scratch = File.join(ARGV.fetch(0), ".bashpp-eval-343973846")
      Dir.mkdir(scratch)
      File.write(File.join(scratch, "bashpp-session-3253152031.go"), "package main")
      at_exit { FileUtils.rm_rf(scratch) }   # never reached: we are killed
      sleep 30
    RUBY
    stage = Corpus.capture([RbConfig.ruby, '-rfileutils', '-e', program, interpreted],
                           cwd: @root, env: {}, timeout: 2,
                           log_prefix: File.join(Dir.tmpdir, "gbe-lifecycle-#{Process.pid}"))
    refute Corpus.success?(stage), 'the child must have been terminated, not have exited cleanly'
    assert File.directory?(File.join(interpreted, '.bashpp-eval-343973846')),
           'the killed child must have left its scratch directory behind'

    result = GoByExampleInputs.enforce({'state' => 'complete'}, bindings, [:shared, :interpreted])
    assert_equal 'input_mutation', result.fetch('state')
    assert GoByExampleInputs.intact?(bindings, [:shared, :compiled]),
           'a leak confined to src/interpreted must not suppress the compiled run'
    [stage['stdout']['path'], stage['stderr']['path']].each { |log| File.delete(log) if File.exist?(log) }
  end

  def test_shared_tree_mutation_still_fails_every_mode
    corpus = File.join(@root, 'examples', 'signals')
    binaries = File.join(@root, 'bin')
    [corpus, binaries].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(corpus, 'signals.go'), 'package main')
    File.write(File.join(binaries, 'oracle'), 'ELF')
    private_tree = File.join(@root, 'src', 'compiled')
    FileUtils.mkdir_p(private_tree)
    File.write(File.join(private_tree, 'signals.go'), 'package main')

    bindings = [GoByExampleInputs.new(corpus, scope: :shared),
                GoByExampleInputs.new(binaries, scope: :shared),
                GoByExampleInputs.new(private_tree, scope: :compiled)]

    # Tampering with the pinned corpus bytes, or with the binaries every mode
    # executes, is not attributable to one mode and must fail all of them.
    File.write(File.join(corpus, 'signals.go'), 'package main // tampered')
    File.write(File.join(binaries, 'oracle'), 'ELF-tampered')
    GoByExampleInputs::SCOPES.each do |scope|
      refute GoByExampleInputs.intact?(bindings, [:shared, scope]),
             "shared mutation must fail scope #{scope}"
      result = GoByExampleInputs.enforce({'state' => 'complete'}, bindings, [:shared, scope])
      assert_equal 'input_mutation', result.fetch('state')
      assert_includes result.fetch('detail'), corpus
    end
  end

  def test_scoping_never_licenses_an_addition_a_binding_did_not_declare
    dir = File.join(@root, 'src', 'interpreted')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'signals.go'), 'package main')
    binding = GoByExampleInputs.new(dir, scope: :interpreted)
    # A dotted scratch directory is still an addition, and additions were not
    # declared for a product source tree.
    leftover_interpreter_scratch(dir)
    refute binding.unchanged?
    assert(binding.changes.any? { |c| c.start_with?('+') && c.include?('.bashpp-eval') })
  end

  def test_removing_a_bound_entry_is_a_mutation_even_where_additions_are_allowed
    dir = File.join(@root, 'build')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'main.go'), 'package main')
    binding = GoByExampleInputs.new(dir, allow_additions: true, scope: :compiled)
    File.write(File.join(dir, 'go.sum'), 'metadata')
    assert binding.unchanged?
    File.delete(File.join(dir, 'main.go'))
    refute binding.unchanged?
    assert(binding.changes.any? { |c| c == '!main.go' })
  end

  def test_binding_scope_must_be_declared_from_the_known_set
    FileUtils.mkdir_p(@root)
    assert_raises(ArgumentError) { GoByExampleInputs.new(@root, scope: :everything) }
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
