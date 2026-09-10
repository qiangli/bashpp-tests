# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../tools/go-full/stage_resolver'

class Sprint148StageResolverTest < Minitest::Test
  def native(status)
    { 'status' => status, 'evidence_kind' => 'native-go-only' }
  end

  def stage(state: 'exited', spawned: true, exit_status: 0, signal: nil)
    { 'state' => state, 'spawned' => spawned, 'exit' => exit_status, 'signal' => signal,
      'duration_seconds' => 0.01, 'descendants_survived' => false }
  end

  def adjudicate(**overrides)
    GoFullStageResolver.adjudicate!(**{
      root_id: 'testdir:example.go', stage_id: 'interpreted:run', decision: 'execute',
      native_observation: native('pass'), stage_role: 'run', stage: stage
    }.merge(overrides))
  end

  def test_native_applicable_root_cannot_be_excluded
    assert_raises(Corpus::ContractError) do
      adjudicate(decision: 'upstream-skip', stage: nil)
    end
  end

  def test_only_retained_native_skip_can_resolve_to_skip
    result = adjudicate(decision: 'upstream-skip', native_observation: native('skip'),
                        stage_role: nil, stage: nil)
    assert_equal 'UPSTREAM_SKIP', result.fetch('verdict')
    refute result.fetch('execution_credited')
    assert_equal 'retained-native-skip', result.dig('decisive', 'rule')
    assert_equal native('skip').merge('requested_applicability' => 'upstream-skip'), {
      'status' => result.dig('decisive', 'inputs', 'native_status'),
      'evidence_kind' => result.dig('decisive', 'inputs', 'native_evidence_kind'),
      'requested_applicability' => result.dig('decisive', 'inputs', 'requested_applicability')
    }
    assert_raises(Corpus::ContractError) do
      adjudicate(decision: 'upstream-skip', native_observation: native('skip'), stage: stage)
    end
    assert_raises(Corpus::ContractError) do
      adjudicate(decision: 'upstream-skip', native_observation: native('skip'),
                 stage_role: 'run', stage: nil)
    end
  end

  def test_timeout_is_a_failure_and_never_a_skip
    result = adjudicate(stage: stage(state: 'deadline', exit_status: nil, signal: 9))
    assert_equal 'FAIL', result.fetch('verdict')
    assert_match(/not a skip/, result.fetch('reason'))
    assert_equal 'deadline-is-failed-execution', result.dig('decisive', 'rule')
    assert_equal 'deadline', result.dig('decisive', 'inputs', 'terminal_state')
  end

  def test_probe_cannot_count_as_execution
    assert_raises(Corpus::ContractError) { adjudicate(stage_role: 'probe') }
    assert_raises(Corpus::ContractError) { adjudicate(stage_role: 'diagnostic-probe') }
  end

  def test_unknown_and_contradictory_states_reject
    assert_raises(Corpus::ContractError) { adjudicate(native_observation: native('maybe')) }
    assert_raises(Corpus::ContractError) { adjudicate(native_observation: native('pass').merge('hint' => 'skip')) }
    assert_raises(Corpus::ContractError) { adjudicate(decision: 'maybe') }
    assert_raises(Corpus::ContractError) do
      adjudicate(decision: 'execute', native_observation: native('ancestor-skip'))
    end
    assert_raises(Corpus::ContractError) { adjudicate(stage: stage(state: 'unknown')) }
    assert_raises(Corpus::ContractError) { adjudicate(stage: stage(state: 'deadline', exit_status: 0)) }
    assert_raises(Corpus::ContractError) do
      adjudicate(stage: stage(state: 'process_leak', exit_status: 0))
    end
  end

  def test_budget_is_finite_absolute_and_single_use
    now = 1_000_000_000
    clock = -> { now }
    budget = GoFullStageResolver::StageBudget.new(2, clock: clock)
    assert_equal 3_000_000_000, budget.expires_ns
    now += 250_000_000
    assert_in_delta 1.75, budget.claim!, 0.000001
    assert_raises(Corpus::ContractError) { budget.claim! }
    [0, -1, Float::INFINITY, Float::NAN, 61].each do |seconds|
      assert_raises(Corpus::ContractError) { GoFullStageResolver::StageBudget.new(seconds) }
    end
  end

  def test_expired_budget_rejects_before_launch
    ticks = [1_000_000_000, 2_000_000_000]
    budget = GoFullStageResolver::StageBudget.new(0.5, clock: -> { ticks.shift })
    assert_raises(Corpus::ContractError) { budget.claim! }
  end

  def test_launch_failure_is_not_execution_and_malformed_terminals_reject
    result = adjudicate(stage: stage(state: 'launch_failure', spawned: false, exit_status: nil))
    assert_equal 'FAIL', result.fetch('verdict')
    refute result.fetch('execution_credited'), 'an unspawned launch must not receive execution credit'
    assert_raises(Corpus::ContractError) { adjudicate(stage: stage(spawned: false)) }
  end

  def test_run_reauthenticates_identity_and_delegates_to_lineage_once
    receipt = { 'root_id' => 'testdir:example.go', 'stage_id' => 'interpreted:run',
                'timeout_seconds' => 2, 'environment' => {} }
    calls = []
    payload = {
      'root_id' => receipt['root_id'], 'stage_id' => receipt['stage_id'], 'launch_id' => 'launch-1',
      'launch' => { 'pid' => 123 },
      'terminal' => { 'state' => 'exited', 'exit' => 0, 'signal' => nil,
                      'descendant_observed' => false },
      'artifacts' => { 'execution_identity' => { 'path' => '/receipt', 'sha256' => 'a' * 64 } }
    }
    terminal = stage.merge('lineage' => {
      'path' => '/lineage', 'root_id' => receipt['root_id'], 'stage_id' => receipt['stage_id'],
      'launch_id' => 'launch-1', 'payload_sha256' => Corpus::ProcessLineage.payload_sha256(payload)
    })
    verdict_calls = []
    GoFullExecutionIdentity.stub(:load!, receipt) do
      GoFullExecutionIdentity.stub(:controlled_environment!, {}) do
        GoFullExecutionIdentity.stub(:authenticate_verdict!, ->(*args, **keywords) { verdict_calls << [args, keywords]; keywords.fetch(:verdict) }) do
          Corpus::ProcessLineage.stub(:authenticate!, [payload]) do
            Corpus::ProcessLineage.stub(:run, ->(*args, **keywords) { calls << [args, keywords]; terminal }) do
              result = GoFullStageResolver.run!(
                identity_path: '/receipt', identity_sha256: 'a' * 64,
                root_id: receipt['root_id'], stage_id: receipt['stage_id'],
                native_observation: native('pass'), decision: 'execute', stage_role: 'run',
                argv: ['/tool'], cwd: '/work', environment: {}, lineage_path: '/lineage', log_prefix: '/log'
              )
              assert_equal 'PASS', result.fetch('verdict')
              assert_equal 'zero-exit-is-pass', result.dig('decisive', 'rule')
              assert_equal 1, calls.length
              assert_equal 1, verdict_calls.length
              assert_equal '/receipt', calls.first.last.dig(:artifact_paths, 'execution_identity')
              timeout = calls.first.last.fetch(:timeout)
              assert_operator timeout, :>, 0
              assert_operator timeout, :<=, 2
              assert_equal GoFullStageResolver::CLOCK, result.dig('budget', 'clock')
            end
          end
        end
      end
    end
  end

  def test_resolved_skip_never_launches
    receipt = { 'root_id' => 'testdir:example.go', 'stage_id' => 'interpreted:run',
                'timeout_seconds' => 2, 'environment' => {} }
    GoFullExecutionIdentity.stub(:load!, receipt) do
      GoFullExecutionIdentity.stub(:controlled_environment!, {}) do
        GoFullExecutionIdentity.stub(:authenticate_verdict!, 'UPSTREAM_SKIP') do
          Corpus::ProcessLineage.stub(:run, ->(*) { flunk 'skip launched a process' }) do
            result = GoFullStageResolver.run!(
              identity_path: '/receipt', identity_sha256: 'a' * 64,
              root_id: receipt['root_id'], stage_id: receipt['stage_id'],
              native_observation: native('skip'), decision: 'upstream-skip', stage_role: nil,
              argv: ['/tool'], cwd: '/work', environment: {}, lineage_path: '/lineage', log_prefix: '/log'
            )
            assert_equal 'UPSTREAM_SKIP', result.fetch('verdict')
          end
        end
      end
    end
  end
end
