# frozen_string_literal: true
# Sprint: #142; Story: #25; Story-ID: f3d6a18d5039

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/go-full/recipe_adapters'

class RecipeAdapterRegistryTests < Minitest::Test
  Adapter = Struct.new(:eligibility, :result, :calls) do
    def eligible?(root)
      calls << [:eligible, root.fetch('id')]
      eligibility
    end

    def execute(root:, context:)
      calls << [:execute, root.fetch('id'), context.fetch(:token)]
      result
    end
  end

  def setup
    @directory = File.realpath(Dir.mktmpdir('recipe-adapter'))
    @source = File.join(@directory, 'case.go')
    File.write(@source, "package main\n")
    @root = { 'id' => 'testdir:case.go', 'axis' => 'testdir', 'path' => 'case.go',
              'input_files' => ['case.go'], 'recipe' => { 'action' => 'future-action' } }
    @context = { source_root: @directory, token: 'lane-context', native_observation: { 'status' => 'pass' } }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def capture_attempt
    executable = File.realpath(RbConfig.ruby)
    stage = Corpus.capture([executable, '-e', 'exit 0'], cwd: @directory,
                           log_prefix: File.join(@directory, 'adapter'), env: { 'PATH' => '' }, timeout: 2)
    { 'inputs' => { 'case.go' => Corpus.file_record(@source) },
      'executable' => Corpus.file_record(executable), 'stage' => stage }
  end

  def result(attempts = [capture_attempt])
    { 'root_id' => @root.fetch('id'), 'product_verdict' => 'PASS',
      'row' => { 'future_evidence' => { 'exact_recipe' => true } }, 'attempt_evidence' => attempts }
  end

  def adapter(result: self.result, eligibility: true)
    Adapter.new(eligibility, result, [])
  end

  def test_registered_adapter_dispatches_and_retains_authenticated_attempts
    registry = GoFullRecipeAdapters::Registry.new
    implementation = adapter
    registry.register(lane: 'testdir', action: 'future-action', name: 'recipe_future', adapter: implementation)

    dispatched = registry.dispatch(root: @root, context: @context)

    assert_equal 'PASS', dispatched['product_verdict']
    assert_equal({ 'exact_recipe' => true }, dispatched['future_evidence'])
    assert_equal 'recipe_future', dispatched.dig('adapter_evidence', 'adapter', 'name')
    assert_equal 1, dispatched.dig('adapter_evidence', 'attempts').length
    assert_equal [[:eligible, @root.fetch('id')], [:execute, @root.fetch('id'), 'lane-context']], implementation.calls
  end

  def test_unknown_and_ineligible_actions_are_rejected
    registry = GoFullRecipeAdapters::Registry.new
    error = assert_raises(Corpus::ContractError) { registry.dispatch(root: @root, context: @context) }
    assert_match(/unregistered/, error.message)

    registry.register(lane: 'testdir', action: 'future-action', name: 'recipe_future', adapter: adapter(eligibility: false))
    refute registry.eligible?(@root)
    error = assert_raises(Corpus::ContractError) { registry.dispatch(root: @root, context: @context) }
    assert_match(/rejected root/, error.message)
  end

  def test_duplicate_lane_action_registration_is_rejected
    registry = GoFullRecipeAdapters::Registry.new
    registry.register(lane: 'testdir', action: 'future-action', name: 'first', adapter: adapter)
    error = assert_raises(Corpus::ContractError) do
      registry.register(lane: 'testdir', action: 'future-action', name: 'second', adapter: adapter)
    end
    assert_match(/duplicate/, error.message)
  end

  def test_registration_listing_is_deterministic
    registry = GoFullRecipeAdapters::Registry.new
    registry.register(lane: 'typechecker', action: 'zeta', name: 'third', adapter: adapter)
    registry.register(lane: 'testdir', action: 'zeta', name: 'second', adapter: adapter)
    registry.register(lane: 'testdir', action: 'alpha', name: 'first', adapter: adapter)

    assert_equal [%w[testdir alpha first], %w[testdir zeta second], %w[typechecker zeta third]],
                 registry.registrations.map { |entry| entry.values_at('lane', 'action', 'name') }
  end

  def test_subset_runner_binding_includes_the_adapter_spine
    paths = GoFullRecipeAdapters.runner_paths(File.expand_path('../../tools/go-full', __dir__))

    assert_equal [File.realpath(File.expand_path('../../tools/go-full/recipe_adapters.rb', __dir__))], paths
  end

  def test_adapter_cannot_claim_a_root_without_authenticated_attempt_evidence
    registry = GoFullRecipeAdapters::Registry.new
    registry.register(lane: 'testdir', action: 'future-action', name: 'recipe_future', adapter: adapter(result: result([])))
    error = assert_raises(Corpus::ContractError) { registry.dispatch(root: @root, context: @context) }
    assert_match(/no attempt evidence/, error.message)

    tampered = capture_attempt
    tampered.fetch('executable')['sha256'] = '0' * 64
    registry = GoFullRecipeAdapters::Registry.new
    registry.register(lane: 'testdir', action: 'future-action', name: 'recipe_future', adapter: adapter(result: result([tampered])))
    assert_raises(Corpus::ContractError) { registry.dispatch(root: @root, context: @context) }
  end

  def test_malformed_attempt_evidence_is_rejected_as_a_contract_error
    registry = GoFullRecipeAdapters::Registry.new
    malformed = capture_attempt
    malformed['stage'] = 'not a capture record'
    registry.register(lane: 'testdir', action: 'future-action', name: 'recipe_future', adapter: adapter(result: result([malformed])))

    assert_raises(Corpus::ContractError) { registry.dispatch(root: @root, context: @context) }
  end

  # A capture stream file is the receipt of one independent execution. The
  # sibling evidence gate (Corpus::Validation.validate!) refuses two stages that
  # share a stdout/stderr path anywhere in a validation, so one process cannot be
  # presented as many. The adapter authentication only checks stdout != stderr
  # WITHIN an attempt; it never rejects two attempts backed by the same physical
  # capture, so a single run can be inflated into N distinct "attempts".
  def test_attempts_may_not_reuse_one_captures_stream_files
    registry = GoFullRecipeAdapters::Registry.new
    shared = capture_attempt
    duplicate = capture_attempt.merge('stage' => shared.fetch('stage'))
    registry.register(lane: 'testdir', action: 'future-action', name: 'recipe_future',
                      adapter: adapter(result: result([shared, duplicate])))

    assert_raises(Corpus::ContractError) { registry.dispatch(root: @root, context: @context) }
  end
end
