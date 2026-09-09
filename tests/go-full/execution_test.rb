# frozen_string_literal: true
# Parser/negative-contract unit tests, never successful corpus execution evidence.
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/go-full/native'
require_relative '../../tools/go-full/product'

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
    %w[compile compiledir errorcheck errorcheckandrundir errorcheckwithauto runoutput errorcheckoutput asmcheck runindir skip].each do |action|
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
                'stdout' => { 'path' => out }, 'stderr' => { 'path' => err } }
      record = { 'modes' => { 'baseline' => { 'mode' => 'baseline', 'stages' => [stage] } } }
      result = GoFullProduct.exact_upstream_output(record, { 'expected_output' => { 'present' => false, 'path' => 'case.out' } }, dir)
      assert_equal 'FAIL', result['status']
      assert_match(/ordering/, result['reason'])
      stage['exit'] = 1
      result = GoFullProduct.exact_upstream_output(record, { 'expected_output' => { 'present' => false, 'path' => 'case.out' } }, dir)
      assert_equal 'FAIL', result['status']
      assert_match(/unsuccessful/, result['reason'])
    end
  end
end
