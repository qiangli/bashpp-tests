# frozen_string_literal: true
# Sprint: #148; Packet: 148.5; Story-ID: 3e561455641a

require_relative '../corpus/process_lineage'
require_relative 'execution_identity'

# The fail-closed boundary between an authenticated stage description and the
# process-lineage primitive. Recipe adapters decide what a stage means; this
# module decides only whether it may run, how long it may run, and whether its
# terminal can count as execution.
module GoFullStageResolver
  module_function

  SCHEMA = 'go-full-stage-resolution/v1'
  CLOCK = Corpus::ProcessLineage::CLOCK
  DECISIONS = %w[execute upstream-skip].freeze
  NATIVE_STATUSES = %w[pass fail skip ancestor-skip missing].freeze
  EXECUTION_ROLES = %w[compile build run check execute].freeze
  NON_EXECUTION_ROLES = %w[probe diagnostic-probe discovery].freeze
  TERMINAL_STATES = Corpus::ProcessLineage::TERMINAL_STATES
  NATIVE_OBSERVATION_KEYS = %w[evidence_kind status].freeze

  # A budget is absolute and single-use. A caller cannot accidentally reset a
  # timeout by asking for the remaining duration before each retry.
  class StageBudget
    attr_reader :seconds, :started_ns, :expires_ns

    def initialize(seconds, clock: nil)
      unless seconds.is_a?(Numeric) && seconds.finite? && seconds.positive? &&
             seconds <= GoFullExecutionIdentity::MAX_STAGE_TIMEOUT_SECONDS
        raise Corpus::ContractError,
              "stage budget must be finite, positive, and at most #{GoFullExecutionIdentity::MAX_STAGE_TIMEOUT_SECONDS} seconds"
      end
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) }
      @seconds = seconds
      @started_ns = monotonic_ns
      @expires_ns = @started_ns + (seconds * 1_000_000_000).to_i
      @claimed = false
    end

    def claim!
      raise Corpus::ContractError, 'stage budget already claimed' if @claimed
      now = monotonic_ns
      raise Corpus::ContractError, 'stage budget expired before launch' if now >= @expires_ns
      @claimed = true
      (@expires_ns - now) / 1_000_000_000.0
    end

    def record
      { 'clock' => CLOCK, 'seconds' => @seconds, 'monotonic_started_ns' => @started_ns,
        'monotonic_expires_ns' => @expires_ns }
    end

    private

    def monotonic_ns
      value = @clock.call
      raise Corpus::ContractError, 'monotonic clock returned an invalid value' unless value.is_a?(Integer) && value >= 0
      value
    end
  end

  # Native evidence answers whether upstream considered a root applicable.
  # It cannot be overridden by a product adapter: an observed native terminal
  # is applicable, while a retained skip is the only finite exclusion.
  def applicability!(native_observation:, decision:)
    raise Corpus::ContractError, 'native observation must be an object' unless native_observation.is_a?(Hash)
    unless native_observation.keys.sort == NATIVE_OBSERVATION_KEYS
      raise Corpus::ContractError, 'native applicability inputs have extra or missing fields'
    end
    status = native_observation.fetch('status')
    raise Corpus::ContractError, "unknown native applicability state #{status.inspect}" unless NATIVE_STATUSES.include?(status)
    raise Corpus::ContractError, "unknown applicability decision #{decision.inspect}" unless DECISIONS.include?(decision)
    raise Corpus::ContractError, 'native observation is not native-only evidence' unless native_observation['evidence_kind'] == 'native-go-only'

    expected = case status
               when 'pass', 'fail' then 'execute'
               when 'skip', 'ancestor-skip' then 'upstream-skip'
               when 'missing'
                 raise Corpus::ContractError, 'missing native terminal has unknown applicability'
               end
    if decision != expected
      raise Corpus::ContractError,
            "contradictory applicability: native #{status.inspect} requires #{expected.inspect}, got #{decision.inspect}"
    end
    { 'rule' => expected == 'execute' ? 'native-terminal-requires-execution' : 'retained-native-skip',
      'inputs' => { 'native_status' => status,
                    'native_evidence_kind' => native_observation.fetch('evidence_kind'),
                    'requested_applicability' => decision } }
  rescue KeyError => error
    raise Corpus::ContractError, "incomplete native applicability: #{error.message}"
  end

  # Convert one authenticated terminal into the only three public outcomes.
  # A deadline is always FAIL, never a skip. A probe is evidence that a probe
  # ran, not evidence that the required product stage executed.
  def adjudicate!(root_id:, stage_id:, decision:, native_observation:, stage_role:, stage: nil)
    require_id!(root_id, 'root'); require_id!(stage_id, 'stage')
    applicability = applicability!(native_observation: native_observation, decision: decision)

    if decision == 'upstream-skip'
      raise Corpus::ContractError, 'upstream skip cannot declare an execution role' unless stage_role.nil?
      raise Corpus::ContractError, 'upstream skip contradicts spawned stage evidence' unless stage.nil?
      return resolution(root_id, stage_id, decision, 'UPSTREAM_SKIP', nil, nil,
                        decisive: applicability)
    end

    raise Corpus::ContractError, "unknown stage role #{stage_role.inspect}" unless
      (EXECUTION_ROLES + NON_EXECUTION_ROLES).include?(stage_role)
    raise Corpus::ContractError, 'probe evidence cannot satisfy a product execution obligation' if NON_EXECUTION_ROLES.include?(stage_role)
    validate_stage!(stage)

    verdict = stage['state'] == 'exited' && stage['exit'] == 0 && stage['signal'].nil? ? 'PASS' : 'FAIL'
    reason = case stage['state']
             when 'deadline' then 'stage deadline exceeded; timeout is a failed execution, not a skip'
             when 'process_leak' then 'stage left a descendant process'
             when 'launch_failure' then 'stage did not spawn'
             when 'exited' then verdict == 'PASS' ? nil : 'stage exited unsuccessfully'
             end
    resolution(root_id, stage_id, decision, verdict, stage_role, stage, reason,
               decisive: terminal_decision(applicability, stage_role, stage, verdict))
  end

  # The sole launch entry point of this mechanism. It reauthenticates the
  # immutable identity, resolves applicability before spawning, claims exactly
  # one absolute stage budget, and delegates process-group kill/reap to the
  # durable lineage implementation from packet 148.1.
  def run!(identity_path:, identity_sha256:, root_id:, stage_id:, native_observation:, decision:,
           stage_role:, argv:, cwd:, environment:, lineage_path:, log_prefix:, stdin: File::NULL,
           parent_launch_id: nil, artifact_paths: {}, artifact_parents: {}, combined_output: false)
    receipt = GoFullExecutionIdentity.load!(identity_path, expected_sha256: identity_sha256)
    applicability!(native_observation: native_observation, decision: decision)
    unless receipt.values_at('root_id', 'stage_id') == [root_id, stage_id]
      raise Corpus::ContractError, 'stage resolver root/stage differs from execution identity'
    end
    raise Corpus::ContractError, 'spawn environment must be a string map' unless environment.is_a?(Hash) && environment.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
    controlled_environment = GoFullExecutionIdentity.controlled_environment!(environment.slice(*GoFullExecutionIdentity::CONTROLLED_ENVIRONMENT))
    raise Corpus::ContractError, 'stage resolver environment differs from execution identity' unless
      receipt.fetch('environment') == controlled_environment

    if decision == 'upstream-skip'
      answer = adjudicate!(root_id: root_id, stage_id: stage_id, decision: decision,
                           native_observation: native_observation, stage_role: stage_role, stage: nil)
      GoFullExecutionIdentity.authenticate_verdict!(
        identity_path, expected_sha256: identity_sha256, root_id: root_id,
        stage_id: stage_id, verdict: answer.fetch('verdict')
      )
      return answer
    end
    raise Corpus::ContractError, 'probe evidence cannot satisfy a product execution obligation' if NON_EXECUTION_ROLES.include?(stage_role)
    raise Corpus::ContractError, "unknown stage role #{stage_role.inspect}" unless EXECUTION_ROLES.include?(stage_role)

    budget = StageBudget.new(receipt.fetch('timeout_seconds'))
    remaining = budget.claim!
    unless artifact_paths.is_a?(Hash) && artifact_parents.is_a?(Hash)
      raise Corpus::ContractError, 'lineage artifact inputs must be maps'
    end
    if artifact_paths.key?('execution_identity') || artifact_parents.key?('execution_identity')
      raise Corpus::ContractError, 'execution_identity is a reserved lineage artifact'
    end
    lineage_artifacts = artifact_paths.merge('execution_identity' => identity_path)
    stage = Corpus::ProcessLineage.run(argv, cwd: cwd, env: environment, timeout: remaining,
      lineage_path: lineage_path, log_prefix: log_prefix, root_id: root_id, stage_id: stage_id,
      parent_launch_id: parent_launch_id, artifact_paths: lineage_artifacts,
      artifact_parents: artifact_parents, stdin: stdin, combined_output: combined_output)
    authenticate_lineage_stage!(lineage_path, stage, root_id, stage_id,
                                identity_path, identity_sha256)
    answer = adjudicate!(root_id: root_id, stage_id: stage_id, decision: decision,
                         native_observation: native_observation, stage_role: stage_role, stage: stage)
    answer['budget'] = budget.record
    GoFullExecutionIdentity.authenticate_verdict!(
      identity_path, expected_sha256: identity_sha256, root_id: root_id,
      stage_id: stage_id, verdict: answer.fetch('verdict')
    )
    answer
  end

  def authenticate_lineage_stage!(lineage_path, stage, root_id, stage_id,
                                  identity_path, identity_sha256)
    reference = stage.fetch('lineage')
    unless reference.is_a?(Hash) && reference['path'] == File.expand_path(lineage_path) &&
           reference.values_at('root_id', 'stage_id') == [root_id, stage_id]
      raise Corpus::ContractError, 'stage lineage reference differs from resolver inputs'
    end
    records = Corpus::ProcessLineage.authenticate!(lineage_path)
    matches = records.select { |payload| payload['launch_id'] == reference['launch_id'] }
    raise Corpus::ContractError, 'stage lineage launch is missing or ambiguous' unless matches.length == 1
    payload = matches.first
    unless payload.values_at('root_id', 'stage_id') == [root_id, stage_id] &&
           Corpus::ProcessLineage.payload_sha256(payload) == reference['payload_sha256']
      raise Corpus::ContractError, 'stage lineage payload differs from resolver inputs'
    end
    identity = payload.dig('artifacts', 'execution_identity')
    unless identity.is_a?(Hash) && identity['path'] == File.expand_path(identity_path) &&
           identity['sha256'] == identity_sha256
      raise Corpus::ContractError, 'lineage does not bind the authenticated execution identity'
    end
    terminal = payload.fetch('terminal')
    expected = {
      'spawned' => !payload.dig('launch', 'pid').nil?, 'state' => terminal.fetch('state'),
      'exit' => terminal['exit'], 'signal' => terminal['signal'],
      'descendants_survived' => terminal.fetch('descendant_observed')
    }
    actual = expected.keys.to_h { |key| [key, stage.fetch(key)] }
    raise Corpus::ContractError, 'stage terminal differs from authenticated lineage' unless actual == expected
    payload
  rescue KeyError, TypeError => error
    raise Corpus::ContractError, "incomplete stage lineage: #{error.message}"
  end

  def validate_stage!(stage)
    raise Corpus::ContractError, 'required execution stage is absent' unless stage.is_a?(Hash)
    state = stage.fetch('state')
    raise Corpus::ContractError, "unknown stage terminal state #{state.inspect}" unless TERMINAL_STATES.include?(state)
    spawned = stage.fetch('spawned')
    raise Corpus::ContractError, 'stage spawned state is not boolean' unless [true, false].include?(spawned)
    duration = stage.fetch('duration_seconds')
    raise Corpus::ContractError, 'stage duration is not finite' unless duration.is_a?(Numeric) && duration.finite? && duration >= 0
    raise Corpus::ContractError, 'stage lacks exit/signal fields' unless stage.key?('exit') && stage.key?('signal')
    descendants = stage.fetch('descendants_survived')
    raise Corpus::ContractError, 'descendant state is not boolean' unless [true, false].include?(descendants)
    case state
    when 'launch_failure'
      raise Corpus::ContractError, 'launch failure contradicts spawned/process status' if spawned || !stage['exit'].nil? || !stage['signal'].nil?
      raise Corpus::ContractError, 'unspawned launch reports descendants' if descendants
    when 'exited'
      raise Corpus::ContractError, 'terminal stage was not spawned' unless spawned
      raise Corpus::ContractError, 'exited stage has invalid status' unless stage['exit'].is_a?(Integer) && stage['exit'] >= 0 && stage['signal'].nil?
      raise Corpus::ContractError, 'exited stage contradicts observed descendants' if descendants
    when 'deadline'
      raise Corpus::ContractError, 'deadline stage has invalid status' unless spawned && stage['exit'].nil? && stage['signal'].is_a?(Integer) && stage['signal'].positive?
    when 'process_leak'
      raise Corpus::ContractError, 'process leak did not observe a descendant' unless spawned && descendants
      unless [stage['exit'], stage['signal']].one? { |value| value.is_a?(Integer) && value >= 0 }
        raise Corpus::ContractError, 'process leak lacks a process result'
      end
    end
    stage
  rescue KeyError => error
    raise Corpus::ContractError, "incomplete stage terminal: #{error.message}"
  end

  def terminal_decision(applicability, role, stage, verdict)
    terminal_rule = case stage.fetch('state')
                    when 'deadline' then 'deadline-is-failed-execution'
                    when 'process_leak' then 'descendant-leak-is-failed-execution'
                    when 'launch_failure' then 'launch-failure-is-not-execution'
                    when 'exited' then verdict == 'PASS' ? 'zero-exit-is-pass' : 'nonzero-or-signaled-exit-is-fail'
                    end
    { 'rule' => terminal_rule,
      'inputs' => applicability.fetch('inputs').merge(
        'applicability_rule' => applicability.fetch('rule'), 'stage_role' => role,
        'spawned' => stage.fetch('spawned'), 'terminal_state' => stage.fetch('state'),
        'exit' => stage['exit'], 'signal' => stage['signal']
      ) }
  end

  def resolution(root_id, stage_id, decision, verdict, role, stage, reason = nil, decisive:)
    value = { 'schema' => SCHEMA, 'root_id' => root_id, 'stage_id' => stage_id,
              'applicability' => decision, 'verdict' => verdict, 'stage_role' => role,
              'execution_credited' => stage.is_a?(Hash) && stage['spawned'] == true && EXECUTION_ROLES.include?(role),
              'decisive' => decisive, 'stage' => stage }
    value['reason'] = reason if reason
    value
  end

  def require_id!(value, label)
    raise Corpus::ContractError, "#{label} identity required" unless value.is_a?(String) && !value.empty?
  end
end
