# frozen_string_literal: true
# Parser/negative-contract unit tests, never successful corpus execution evidence.
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/go-full/native'
require_relative '../../tools/go-full/product'
require_relative '../../tools/go-full/prepare_wave_b'

class NativeEventTests < Minitest::Test
  def event(events, package, action, test = nil)
    events.consume(JSON.generate({ 'Package' => package, 'Action' => action, 'Test' => test }.compact))
  end

  def test_duplicate_and_unstarted_terminal_are_fatal
    events = GoFull::NativeEvents.new
    assert_raises(Corpus::ContractError) { event(events, 'p', 'pass', 'TestA') }
    event(events, 'p', 'run', 'TestA')
    assert_raises(Corpus::ContractError) { event(events, 'p', 'run', 'TestA') }
    event(events, 'p', 'pass', 'TestA')
    assert_raises(Corpus::ContractError) { event(events, 'p', 'pass', 'TestA') }
  end

  def test_missing_child_is_not_a_pass_inherited_from_parent
    events = GoFull::NativeEvents.new
    event(events, 'p', 'run', 'TestA')
    event(events, 'p', 'pass', 'TestA')
    assert_equal 'missing', events.observation('p', 'TestA/child')['status']
    assert_equal 'native-go-only', events.observation('p', 'TestA')['evidence_kind']
  end

  def test_actual_parent_skip_retains_origin_and_never_credits_execution
    events = GoFull::NativeEvents.new
    event(events, 'p', 'run', 'TestA')
    event(events, 'p', 'skip', 'TestA')
    result = events.observation('p', 'TestA/child')
    assert_equal 'ancestor-skip', result['status']
    assert_equal 'TestA', result.fetch('event').fetch('Test')
    assert_equal 'native-go-only', result['evidence_kind']
  end

  def test_incomplete_and_dynamic_children_are_independent_denominators
    events = GoFull::NativeEvents.new
    event(events, 'p', 'run', 'TestA')
    event(events, 'p', 'run', 'TestA/generated#01')
    event(events, 'p', 'pass', 'TestA/generated#01')
    assert_equal [['p', 'TestA']], events.incomplete
    assert_equal 2, events.started.size
    assert_equal 1, events.terminals.size
  end
end

class ProductRecipeTests < Minitest::Test
  def root
    { 'recipe' => { 'action' => 'run', 'flags' => [], 'args' => [], 'environment_append' => [] }, 'expected_failure_sets' => [] }
  end

  def test_complex_and_nested_recipes_never_enter_generic_success_path
    value = root
    assert GoFullProduct.simple_recipe?(value)
    %w[compiledir errorcheck errorcheckandrundir errorcheckwithauto runoutput errorcheckoutput asmcheck runindir skip].each do |action|
      refute GoFullProduct.simple_recipe?(value.merge('recipe' => value['recipe'].merge('action' => action))), action
    end
    %w[nested_process_obligation program_directory_inputs generated_program directory].each do |key|
      refute GoFullProduct.simple_recipe?(value.merge(key => {})), key
    end
    refute GoFullProduct.simple_recipe?(value.merge('recipe' => value['recipe'].merge('environment_append' => [['GODEBUG', 'x=1']])))
    refute GoFullProduct.simple_recipe?(value.merge('recipe' => value['recipe'].merge('flags' => ['-race'])))
  end

  def test_generator_adapter_keeps_nested_and_flagged_sources_out
    value = root.merge('recipe' => root['recipe'].merge('action' => 'runoutput'))
    assert GoFullProduct.generator_recipe?(value)
    refute GoFullProduct.generator_recipe?(value.merge('nested_process_obligation' => {}))
    refute GoFullProduct.generator_recipe?(value.merge('recipe' => value['recipe'].merge('flags' => ['-goexperiment=simd'])))
  end

  def test_failed_generators_do_not_acquire_oracle_generated_children
    failing = Object.new
    failing.define_singleton_method(:execute) do |**_args|
      { 'verdict' => 'FAIL', 'modes' => Corpus::MODES.to_h { |mode| [mode, { 'stages' => [], 'input_integrity' => true }] } }
    end
    value = root.merge('id' => 'testdir:generator.go', 'path' => 'test/generator.go', 'recipe' => root['recipe'].merge('action' => 'runoutput'))
    Dir.mktmpdir do |dir|
      result = GoFullProduct.execute_generator(value, failing, dir, {}, dir)
      assert_equal 'FAIL', result['verdict']
      assert_equal({ 'expected' => 3, 'observed' => 0 }, result['generated_artifact_denominator'])
      assert_equal({ 'expected' => 9, 'observed' => 0 }, result['child_mode_denominator'])
      assert result['generated_children'].values.all? { |child| child['verdict'] == 'FAIL' && !child.key?('execution') }
    end
  end

  def test_diagnostics_adapter_requires_exact_unflagged_negative_recipe
    value = root.merge('recipe' => root['recipe'].merge('action' => 'errorcheck', 'want_error' => true))
    assert GoFullProduct.diagnostic_recipe?(value)
    refute GoFullProduct.diagnostic_recipe?(value.merge('recipe' => value['recipe'].merge('want_error' => false)))
    refute GoFullProduct.diagnostic_recipe?(value.merge('recipe' => value['recipe'].merge('flags' => ['-lang=go1.17'])))
    refute GoFullProduct.diagnostic_recipe?(value.merge('expected_failure_sets' => ['types2Failures']))
  end

  def test_mixed_streams_are_not_silently_concatenated
    Dir.mktmpdir do |dir|
      out, err = %w[out err].map { |n| File.join(dir, n) }
      File.write(out, 'a'); File.write(err, 'b')
      stage = { 'stage' => 'run', 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil,
                'stdout' => Corpus.file_record(out), 'stderr' => Corpus.file_record(err) }
      record = { 'modes' => Corpus::MODES.to_h { |mode| [mode, { 'mode' => mode, 'stages' => [stage] }] } }
      result = GoFullProduct.exact_upstream_output(record, { 'expected_output' => { 'present' => false, 'path' => 'case.out' } }, dir)
      assert_equal 'FAIL', result['status']
      assert_match(/ordering/, result['reason'])
      stage['exit'] = 1
      result = GoFullProduct.exact_upstream_output(record, { 'expected_output' => { 'present' => false, 'path' => 'case.out' } }, dir)
      assert_equal 'FAIL', result['status']
      assert_match(/successful run/, result['reason'])
    end
  end

  def test_exact_output_consumes_only_authenticated_kernel_combined_bytes
    Dir.mktmpdir do |dir|
      combined = File.join(dir, 'combined'); File.binwrite(combined, "A\n\nB\n")
      sidecar = File.join(dir, 'want'); File.binwrite(sidecar, "A\n\nB\n")
      stage = { 'stage' => 'run', 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil,
                'combined' => Corpus.file_record(combined) }
      modes = Corpus::MODES.to_h { |mode| [mode, { 'mode' => mode, 'stages' => [stage] }] }
      expected = { 'path' => 'want', 'sha256' => Corpus.digest(sidecar), 'bytes' => File.size(sidecar), 'present' => true }
      result = GoFullProduct.exact_upstream_output({ 'modes' => modes },
        { 'expected_output' => expected }, dir)
      assert_equal 'PASS', result['status']
      File.binwrite(combined, "A\nB\n\n")
      assert_raises(Corpus::ContractError) do
        GoFullProduct.exact_upstream_output({ 'modes' => modes }, { 'expected_output' => expected }, dir)
      end
    end
  end

  # A verdict primitive whose entire job is refusing to certify without matching
  # bytes must not certify a present, non-empty sidecar when it observed NOTHING.
  # `observations.values.all? { |v| v == bytes }` is vacuously true on an empty
  # observation set, so an execution that yielded zero run observations reports
  # PASS with observed_sha256 == {}. The sibling verdict `exact_verdict` guards
  # `modes.keys == MODES`; this one has no such floor and fails OPEN.
  def test_exact_output_refuses_to_certify_a_present_sidecar_from_zero_observations
    Dir.mktmpdir do |dir|
      sidecar = File.join(dir, 'want'); File.binwrite(sidecar, "hello")
      expected = { 'path' => 'want', 'sha256' => Corpus.digest(sidecar), 'bytes' => 5, 'present' => true }
      # ordered_repetitions is the documented multi-run field (packet 148.4); an
      # empty list is structurally valid and produces zero observations.
      empty_reps = GoFullProduct.exact_upstream_output(
        { 'ordered_repetitions' => [], 'modes' => {} }, { 'expected_output' => expected }, dir)
      refute_equal 'PASS', empty_reps['status'],
        "certified a 5-byte sidecar from zero observations: #{empty_reps.inspect}"

      empty_modes = GoFullProduct.exact_upstream_output(
        { 'modes' => {} }, { 'expected_output' => expected }, dir)
      refute_equal 'PASS', empty_modes['status'],
        "certified a 5-byte sidecar from an empty mode set: #{empty_modes.inspect}"
    end
  end

  def test_exact_output_reauthenticates_separate_stream_artifacts_before_compare
    Dir.mktmpdir do |dir|
      stdout = File.join(dir, 'stdout'); File.binwrite(stdout, "A\n")
      stderr = File.join(dir, 'stderr'); File.binwrite(stderr, '')
      sidecar = File.join(dir, 'want'); File.binwrite(sidecar, "B\n")
      stage = { 'stage' => 'run', 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil,
                'stdout' => Corpus.file_record(stdout), 'stderr' => Corpus.file_record(stderr) }
      modes = Corpus::MODES.to_h { |mode| [mode, { 'mode' => mode, 'stages' => [stage] }] }
      expected = { 'path' => 'want', 'sha256' => Corpus.digest(sidecar), 'bytes' => File.size(sidecar), 'present' => true }
      File.binwrite(stdout, "B\n")
      assert_raises(Corpus::ContractError) do
        GoFullProduct.exact_upstream_output({ 'modes' => modes }, { 'expected_output' => expected }, dir)
      end
    end
  end

  def test_execution_lineage_binds_stage_stream_artifact_to_payload
    Dir.mktmpdir do |dir|
      ledger = File.join(dir, 'lineage.jsonl')
      stage = Corpus.capture([RbConfig.ruby, '-e', 'STDOUT.write("A\\n")'],
        cwd: dir, env: { 'PATH' => ENV.fetch('PATH', ''), 'LC_ALL' => 'C' }, timeout: 2,
        log_prefix: File.join(dir, 'run'),
        lineage: { path: ledger, root_id: 'testdir:fixedbugs/issue21808.go',
                   stage_id: 'testdir:fixedbugs/issue21808.go/baseline/run', combined_output: true })
      stage['stage'] = 'run'
      alternate = File.join(dir, 'alternate.combined')
      FileUtils.cp(stage.dig('combined', 'path'), alternate)
      stage['combined'] = Corpus.file_record(alternate)
      record = { 'modes' => { 'baseline' => { 'mode' => 'baseline', 'stages' => [stage] } } }
      assert_raises(Corpus::ContractError) do
        GoFullProduct.authenticate_execution_lineage!(record, 'testdir:fixedbugs/issue21808.go')
      end
    end
  end

  def test_packet_success_requires_selected_rows_to_pass
    assert GoFullProduct.packet_rows_pass?([{ 'product_verdict' => 'PASS' }])
    refute GoFullProduct.packet_rows_pass?([])
    refute GoFullProduct.packet_rows_pass?([{ 'product_verdict' => 'UPSTREAM_SKIP' }])
    refute GoFullProduct.packet_rows_pass?([{ 'product_verdict' => 'PASS' }, { 'product_verdict' => 'FAIL' }])
  end

  def test_shared_anchor_path_enables_combined_sink_and_consumes_router_plan
    calls = []
    executor = Object.new
    executor.define_singleton_method(:execute) { |**arguments| calls << arguments; { 'verdict' => 'FAIL', 'modes' => {} } }
    Dir.mktmpdir do |dir|
      issue = { 'id' => 'testdir:fixedbugs/issue21808.go', 'path' => 'test/fixedbugs/issue21808.go' }
      GoFullProduct.execute_anchor(issue, executor, dir, {}, { 'status' => 'pass', 'evidence_kind' => 'native-go-only' })
      assert_equal 3, calls.length
      assert_equal true, calls.last[:combined_output]

      root = File.foreach(File.expand_path('../../docs/go-full/testdir-roots.jsonl', __dir__)).map { |line| JSON.parse(line) }
                 .find { |row| row['id'] == GoFullRecipeRouter::PACKET_ROOT_ID }.merge('axis' => 'testdir')
      %w[cmplxdivide.go cmplxdivide1.go].each do |name|
        path = File.join(dir, 'test', name); FileUtils.mkdir_p(File.dirname(path)); File.write(path, "package main\n")
      end
      _record, routes = GoFullProduct.execute_anchor(root, executor, dir, {}, { 'status' => 'pass', 'evidence_kind' => 'native-go-only' })
      assert_equal ['test/cmplxdivide.go', 'test/cmplxdivide1.go'], calls.last[:sources]
      assert_equal [], calls.last[:args]
      assert_equal 'test', calls.last[:package_input]
      assert_equal true, calls.last[:combined_output]
      assert_equal Corpus::MODES, routes.keys
      assert routes.values.all? { |route| route['route'] == GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE }
    end
  end

  def test_wave_b_identity_stage_plan_is_deterministic_and_complete
    issue = GoFullWaveBPrepare.stage_plan('148.4', 'testdir:fixedbugs/issue21808.go')
    divide = GoFullWaveBPrepare.stage_plan('148.6', 'testdir:cmplxdivide.go')
    assert_equal 18, issue.length
    assert_equal 18, issue.map(&:last).uniq.length
    assert_equal 6, divide.length
    assert_equal 6, divide.map(&:last).uniq.length
    assert_equal issue, GoFullWaveBPrepare.stage_plan('148.4', 'testdir:fixedbugs/issue21808.go')
    assert issue.all? { |_execution, _mode, _stage, stage_id| stage_id.start_with?('testdir:fixedbugs/issue21808.go:ordered-') }
    assert_raises(Corpus::ContractError) { GoFullWaveBPrepare.stage_plan('148.5', 'root') }
    assert_raises(Corpus::ContractError) { GoFullWaveBPrepare.stage_plan('148.4', '') }
    paths = GoFullWaveBPrepare.runner_paths
    assert_equal paths.sort, GoFullWaveBPrepare.runner_paths.sort
    assert_equal paths.length, paths.uniq.length
    assert_includes paths, File.expand_path('../../tools/corpus/process_lineage.rb', __dir__)
    assert_includes paths, File.expand_path('../../tools/corpus/executor.rb', __dir__)
  end

  def test_wave_b_identity_index_fails_closed_before_stage_use
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'index.json')
      File.write(path, Corpus.canonical('schema' => 'go-full-execution-identity-index/v1',
        'root_id' => 'testdir:root.go', 'entries' => {}) + "\n")
      assert_raises(Corpus::ContractError) do
        GoFullProduct.load_identity_index(path, Corpus.digest(path), 'testdir:root.go', expected_stage_ids: ['root/run'])
      end
      assert_raises(Corpus::ContractError) do
        GoFullProduct.load_identity_index(path, '0' * 64, 'testdir:root.go', expected_stage_ids: ['root/run'])
      end
      File.write(path, '{}')
      assert_raises(Corpus::ContractError) do
        GoFullProduct.load_identity_index(path, Corpus.digest(path), 'testdir:root.go', expected_stage_ids: ['root/run'])
      end
    end
  end

  # The packet 148.4 determinism obligation is "run issue21808 three times, all
  # observations must match the sidecar." The sibling test above asserts this
  # primitive must not certify a present sidecar "when it observed NOTHING"; the
  # only floor the code carries is `return FAIL if observations.empty?`, which
  # fires solely when EVERY repetition is empty. A single ordered_repetitions
  # entry that produced zero run observations (an entire re-run that never
  # happened) is silently dropped: the surviving repetition matches, so PASS is
  # returned. A determinism gate that concludes "deterministic" from two runs
  # when only one ran fails OPEN at exactly the granularity the packet exists to
  # protect.
  def test_exact_output_refuses_to_certify_when_a_repetition_observed_nothing
    Dir.mktmpdir do |dir|
      combined = File.join(dir, 'combined'); File.binwrite(combined, "A\n\nB\n")
      sidecar = File.join(dir, 'want'); File.binwrite(sidecar, "A\n\nB\n")
      stage = { 'stage' => 'run', 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil,
                'combined' => Corpus.file_record(combined) }
      full = { 'modes' => Corpus::MODES.to_h { |mode| [mode, { 'mode' => mode, 'stages' => [stage] }] } }
      expected = { 'path' => 'want', 'sha256' => Corpus.digest(sidecar), 'bytes' => File.size(sidecar), 'present' => true }
      # Two ordered repetitions: one that ran and matched, and one that produced
      # no run observations at all (its differential never executed).
      record = { 'ordered_repetitions' => [full, { 'modes' => {} }], 'modes' => full.fetch('modes') }
      result = GoFullProduct.exact_upstream_output(record, { 'expected_output' => expected }, dir)
      refute_equal 'PASS', result['status'],
        "certified determinism across repetitions when one repetition observed nothing: #{result.inspect}"
    end
  end

  def test_exact_output_requires_one_run_observation_for_each_exact_mode
    Dir.mktmpdir do |dir|
      combined = File.join(dir, 'combined'); File.binwrite(combined, "ok\n")
      sidecar = File.join(dir, 'want'); File.binwrite(sidecar, "ok\n")
      stage = { 'stage' => 'run', 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil,
                'combined' => Corpus.file_record(combined) }
      modes = Corpus::MODES.to_h { |mode| [mode, { 'mode' => mode, 'stages' => [stage] }] }
      expected = { 'path' => 'want', 'sha256' => Corpus.digest(sidecar), 'bytes' => File.size(sidecar), 'present' => true }
      root = { 'expected_output' => expected }

      missing = { 'modes' => modes.reject { |name, _value| name == 'compiled' } }
      assert_equal 'FAIL', GoFullProduct.exact_upstream_output(missing, root, dir)['status']

      duplicate_run = Marshal.load(Marshal.dump('modes' => modes))
      duplicate_run.fetch('modes').fetch('baseline').fetch('stages') << stage
      assert_equal 'FAIL', GoFullProduct.exact_upstream_output(duplicate_run, root, dir)['status']

      duplicate_mode_identity = Marshal.load(Marshal.dump('modes' => modes))
      duplicate_mode_identity.fetch('modes').fetch('compiled')['mode'] = 'baseline'
      assert_equal 'FAIL', GoFullProduct.exact_upstream_output(duplicate_mode_identity, root, dir)['status']
    end
  end
end
