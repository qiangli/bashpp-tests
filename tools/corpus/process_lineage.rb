# frozen_string_literal: true
# Sprint: #148; Packet: 148.1; Story-ID: 07091aa9a5d4

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module Corpus
  class ContractError < StandardError; end unless const_defined?(:ContractError)

  # Append-only launch records used by the shared corpus capture primitive.
  # Environment values are authenticated but never copied into evidence.
  module ProcessLineage
    SCHEMA = 'corpus-process-lineage/v3'
    CLOCK = 'CLOCK_MONOTONIC'
    TERMINAL_STATES = %w[exited deadline process_leak launch_failure].freeze
    LAUNCH_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    REAP_GRACE_SECONDS = 1.0
    module_function

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
    def wall_time
      Time.now.utc.iso8601(9)
    end
    def canonical(value)
      JSON.generate(sort(value))
    end
    def sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, sort(value.fetch(key))] }
      when Array then value.map { |item| sort(item) }
      else value
      end
    end
    def payload_sha256(payload)
      Digest::SHA256.hexdigest(canonical(payload))
    end

    def environment_record(env)
      sorted = env.sort.to_h
      { 'allowlisted_keys' => sorted.keys, 'sha256' => Digest::SHA256.hexdigest(canonical(sorted)) }
    end

    def artifact(path, producer_launch_id:, parent_artifact: nil)
      expanded = File.expand_path(path)
      raise ContractError, "lineage artifact is not a regular file: #{expanded}" unless File.file?(expanded) && !File.symlink?(expanded)
      { 'path' => expanded, 'bytes' => File.size(expanded), 'sha256' => Digest::SHA256.file(expanded).hexdigest,
        'producer_launch_id' => producer_launch_id, 'parent_artifact' => parent_artifact }
    end

    def group_alive?(pgid)
      return false unless pgid.is_a?(Integer) && pgid.positive?
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def signal_group(signal, pgid, events, reason)
      error = nil
      delivered = begin
        Process.kill(signal, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM => exception
        # Losing permission to signal a group is evidence of non-delivery, not
        # permission to discard the attempted-launch receipt. Keep sweeping and
        # let the terminal descendant-survival field fail the launch closed.
        error = exception.class.name
        false
      end
      events << { 'signal' => signal, 'target_pgid' => pgid, 'reason' => reason,
                  'delivered' => delivered, 'error' => error,
                  'monotonic_ns' => monotonic_ns, 'wall' => wall_time }
      delivered
    end

    def wait_group_empty(pgid, seconds = REAP_GRACE_SECONDS)
      stop = monotonic_ns + (seconds * 1_000_000_000).to_i
      loop do
        return true unless group_alive?(pgid)
        return false if monotonic_ns >= stop
        sleep 0.005
      end
    end

    # Returns the ordinary Corpus.capture result and atomically appends its
    # authenticated receipt. Parent launch IDs join generated/nested harness
    # launches; process-group ownership joins OS descendants.
    def run(argv, cwd:, env:, timeout:, lineage_path:, log_prefix:, root_id:, stage_id:,
            parent_launch_id: nil, artifact_paths: {}, artifact_parents: {}, stdin: File::NULL,
            combined_output: false)
      validate_arguments!(argv, cwd, env, timeout, lineage_path, log_prefix, root_id, stage_id,
                          parent_launch_id, artifact_paths, artifact_parents, combined_output)
      FileUtils.mkdir_p(File.dirname(File.expand_path(lineage_path)))
      FileUtils.mkdir_p(File.dirname(File.expand_path(log_prefix)))
      stdout_path = File.expand_path(log_prefix + '.stdout')
      stderr_path = File.expand_path(log_prefix + '.stderr')
      combined_path = File.expand_path(log_prefix + '.combined')
      launch_id = SecureRandom.uuid
      parent_pid = Process.pid
      started_ns = monotonic_ns
      started_wall = wall_time
      timeout_ns = (timeout * 1_000_000_000).to_i
      expires_ns = started_ns + timeout_ns
      pid = status = launch_error = nil
      state = 'launch_failure'
      descendant_observed = false
      kill_events = []
      reap_events = []

      open_output_sinks(stdout_path, stderr_path, combined_path, combined_output) do |stdout, stderr|
          begin
            pid = Process.spawn(env, *argv, chdir: cwd, in: stdin, out: stdout, err: stderr,
                                pgroup: true, unsetenv_others: true)
            state = 'exited'
            loop do
              waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
              if waited_pid
                reap_events << reap_event(waited_pid, status, 'leader_wait')
                break
              end
              if monotonic_ns >= expires_ns
                state = 'deadline'
                signal_group('KILL', pid, kill_events, 'deadline')
                waited_pid, status = Process.waitpid2(pid)
                reap_events << reap_event(waited_pid, status, 'leader_wait_after_deadline')
                break
              end
              sleep 0.005
            end
            descendant_observed = group_alive?(pid)
            if descendant_observed
              state = 'process_leak' if state == 'exited'
              signal_group('KILL', pid, kill_events, 'descendant_sweep')
            end
          rescue SystemCallError => error
            launch_error = { 'class' => error.class.name, 'message' => error.message,
                             'errno' => error.respond_to?(:errno) ? error.errno : nil }
            stderr.write("#{error.class}: #{error.message}\n")
          ensure
            signal_group('KILL', pid, kill_events, 'ensure_sweep') if pid && group_alive?(pid)
          end
      end

      group_empty = pid.nil? || wait_group_empty(pid)
      finished_ns = monotonic_ns
      artifacts = if combined_output
                    { 'combined' => artifact(combined_path, producer_launch_id: launch_id) }
                  else
                    { 'stdout' => artifact(stdout_path, producer_launch_id: launch_id),
                      'stderr' => artifact(stderr_path, producer_launch_id: launch_id) }
                  end
      artifact_paths.keys.sort.each do |label|
        raise ContractError, "reserved lineage artifact label: #{label}" if %w[stdout stderr combined].include?(label)
        next unless File.file?(artifact_paths.fetch(label)) && !File.symlink?(artifact_paths.fetch(label))
        artifacts[label] = artifact(artifact_paths.fetch(label), producer_launch_id: launch_id,
                                    parent_artifact: artifact_parents[label])
      end
      payload = {
        'schema' => SCHEMA, 'root_id' => root_id, 'stage_id' => stage_id, 'launch_id' => launch_id,
        'output_mode' => combined_output ? 'kernel-combined' : 'separate-nonordering',
        'parent_launch_id' => parent_launch_id,
        'launch' => { 'argv' => argv, 'cwd' => File.realpath(cwd), 'environment' => environment_record(env),
                      'pid' => pid, 'parent_pid' => parent_pid, 'pgid' => pid,
                      'monotonic_started_ns' => started_ns, 'wall_started' => started_wall,
                      'launch_failure' => launch_error },
        'deadline' => { 'clock' => CLOCK, 'timeout_ns' => timeout_ns, 'monotonic_expires_ns' => expires_ns },
        'artifacts' => artifacts, 'kill_events' => kill_events, 'reap_events' => reap_events,
        'terminal' => { 'monotonic_finished_ns' => finished_ns, 'wall_finished' => wall_time,
                        'state' => state, 'exit' => status&.exitstatus, 'signal' => status&.termsig,
                        'descendant_observed' => descendant_observed, 'descendants_survived' => !group_empty }
      }
      append!(lineage_path, 'payload' => payload, 'payload_sha256' => payload_sha256(payload))
      capture_result(payload, timeout, artifacts, lineage_path, env, cwd)
    end

    # In combined mode both descriptors are installed from this one IO object,
    # hence one open file description. No observer-side merge is possible.
    def open_output_sinks(stdout_path, stderr_path, combined_path, combined_output)
      if combined_output
        File.open(combined_path, File::WRONLY | File::CREAT | File::EXCL | File::APPEND, 0o600) do |sink|
          yield sink, sink
        end
      else
        File.open(stdout_path, 'wb') { |stdout| File.open(stderr_path, 'wb') { |stderr| yield stdout, stderr } }
      end
    end

    def reap_event(pid, status, reason)
      { 'waited_pid' => pid, 'exit' => status.exitstatus, 'signal' => status.termsig, 'reason' => reason,
        'monotonic_ns' => monotonic_ns, 'wall' => wall_time }
    end

    def capture_result(payload, timeout, artifacts, lineage_path, env, cwd)
      terminal = payload.fetch('terminal')
      result = { 'argv' => payload.dig('launch', 'argv'), 'cwd' => cwd,
        'environment' => env.sort.to_h, 'timeout_seconds' => timeout,
        'spawned' => !payload.dig('launch', 'pid').nil?, 'state' => terminal.fetch('state'),
        'exit' => terminal['exit'], 'signal' => terminal['signal'],
        # Historical capture callers use this as "a descendant survived the
        # leader". The durable terminal field separately proves none survived
        # the final sweep.
        'descendants_survived' => terminal.fetch('descendant_observed'),
        'duration_seconds' => (terminal.fetch('monotonic_finished_ns') - payload.dig('launch', 'monotonic_started_ns')) / 1_000_000_000.0,
        'lineage' => { 'path' => File.expand_path(lineage_path), 'root_id' => payload.fetch('root_id'),
                       'stage_id' => payload.fetch('stage_id'), 'launch_id' => payload.fetch('launch_id'),
                       'parent_launch_id' => payload['parent_launch_id'], 'payload_sha256' => payload_sha256(payload) } }
      if payload['output_mode'] == 'kernel-combined'
        result['combined'] = artifacts.fetch('combined').slice('path', 'sha256', 'bytes')
      else
        result['stdout'] = artifacts.fetch('stdout').slice('path', 'sha256', 'bytes')
        result['stderr'] = artifacts.fetch('stderr').slice('path', 'sha256', 'bytes')
      end
      result
    end

    def validate_arguments!(argv, cwd, env, timeout, lineage_path, log_prefix, root_id, stage_id,
                            parent_launch_id, artifact_paths, artifact_parents, combined_output)
      raise ContractError, 'lineage argv must be a nonempty string array' unless argv.is_a?(Array) && !argv.empty? && argv.all? { |v| v.is_a?(String) }
      raise ContractError, 'lineage cwd must be a directory' unless cwd.is_a?(String) && File.directory?(cwd)
      raise ContractError, 'lineage environment must be a string map' unless env.is_a?(Hash) && env.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
      raise ContractError, 'lineage deadline must be finite and positive' unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
      raise ContractError, 'lineage paths must be strings' unless [lineage_path, log_prefix].all? { |v| v.is_a?(String) && !v.empty? }
      raise ContractError, 'lineage root/stage IDs must be nonempty strings' unless [root_id, stage_id].all? { |v| v.is_a?(String) && !v.empty? }
      raise ContractError, 'invalid parent launch ID' unless parent_launch_id.nil? || parent_launch_id.match?(LAUNCH_ID)
      raise ContractError, 'lineage artifacts must be a string map' unless artifact_paths.is_a?(Hash) && artifact_paths.all? { |k, v| k.is_a?(String) && !k.empty? && v.is_a?(String) }
      raise ContractError, 'artifact parents must name declared artifacts' unless artifact_parents.is_a?(Hash) && (artifact_parents.keys - artifact_paths.keys).empty?
      raise ContractError, 'combined output selection must be boolean' unless [true, false].include?(combined_output)
    end

    def append!(path, envelope)
      File.open(File.expand_path(path), File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(canonical(envelope) + "\n")
        file.flush
        file.fsync
      ensure
        file.flock(File::LOCK_UN)
      end
      envelope
    end

    def authenticate!(path)
      expanded = File.expand_path(path)
      raise ContractError, 'lineage ledger must be a regular non-symlink file' unless File.file?(expanded) && !File.symlink?(expanded)
      records = File.readlines(expanded, chomp: true).map.with_index do |line, index|
        raise ContractError, "empty lineage record #{index + 1}" if line.empty?
        envelope = JSON.parse(line)
        exact_keys!(envelope, %w[payload payload_sha256], 'envelope')
        payload = envelope.fetch('payload')
        unless envelope['payload_sha256'].is_a?(String) && envelope['payload_sha256'].match?(SHA256) && payload_sha256(payload) == envelope['payload_sha256']
          raise ContractError, "lineage payload digest mismatch at record #{index + 1}"
        end
        validate_payload!(payload)
        payload
      end
      raise ContractError, 'lineage ledger is empty' if records.empty?
      validate_joins!(records)
      records
    rescue JSON::ParserError => error
      raise ContractError, "invalid lineage JSON: #{error.message}"
    end

    def reauthenticate!(path)
      records = authenticate!(path)
      raise ContractError, 'lineage reauthentication requires a fresh process' if records.any? { |p| [p.dig('launch', 'pid'), p.dig('launch', 'parent_pid')].include?(Process.pid) }
      raise ContractError, 'lineage process group is not empty' if records.any? { |p| group_alive?(p.dig('launch', 'pgid')) }
      records
    end

    def validate_joins!(records)
      ids = records.map { |p| p.fetch('launch_id') }
      raise ContractError, 'duplicate lineage launch ID' unless ids.uniq == ids
      raise ContractError, 'lineage ledger crosses roots' unless records.map { |p| p.fetch('root_id') }.uniq.length == 1
      positions = ids.each_with_index.to_h
      by_id = records.to_h { |record| [record.fetch('launch_id'), record] }
      records.each_with_index do |payload, index|
        parent = payload['parent_launch_id']
        raise ContractError, 'lineage parent is missing or not earlier' if parent && (!positions.key?(parent) || positions.fetch(parent) >= index)
        payload.fetch('artifacts').each_value do |record|
          raise ContractError, 'artifact producer differs from launch' unless record.fetch('producer_launch_id') == payload.fetch('launch_id')
          artifact_parent = record['parent_artifact']
          next unless artifact_parent
          parent_position = artifact_parent.is_a?(Hash) && positions[artifact_parent['launch_id']]
          raise ContractError, 'artifact parent launch is missing or not earlier' unless parent_position && parent_position < index
          exact_keys!(artifact_parent, %w[artifact launch_id], 'artifact parent')
          parent_record = by_id.fetch(artifact_parent.fetch('launch_id'))
          raise ContractError, 'artifact parent is missing' unless parent_record.fetch('artifacts').key?(artifact_parent.fetch('artifact'))
        end
      end
    end

    def validate_payload!(payload)
      exact_keys!(payload, %w[artifacts deadline kill_events launch launch_id output_mode parent_launch_id reap_events root_id schema stage_id terminal], 'payload')
      raise ContractError, 'unsupported lineage schema' unless payload.fetch('schema') == SCHEMA
      raise ContractError, 'invalid lineage launch ID' unless payload.fetch('launch_id').is_a?(String) && payload.fetch('launch_id').match?(LAUNCH_ID)
      raise ContractError, 'invalid lineage root/stage ID' unless [payload['root_id'], payload['stage_id']].all? { |v| v.is_a?(String) && !v.empty? }
      launch = payload.fetch('launch'); deadline = payload.fetch('deadline'); terminal = payload.fetch('terminal')
      exact_keys!(launch, %w[argv cwd environment launch_failure monotonic_started_ns parent_pid pgid pid wall_started], 'launch')
      exact_keys!(deadline, %w[clock monotonic_expires_ns timeout_ns], 'deadline')
      exact_keys!(terminal, %w[descendant_observed descendants_survived exit monotonic_finished_ns signal state wall_finished], 'terminal')
      raise ContractError, 'invalid lineage terminal state' unless TERMINAL_STATES.include?(terminal.fetch('state'))
      raise ContractError, 'lineage deadline clock differs' unless deadline['clock'] == CLOCK
      raise ContractError, 'lineage deadline arithmetic differs' unless launch.fetch('monotonic_started_ns') + deadline.fetch('timeout_ns') == deadline.fetch('monotonic_expires_ns')
      raise ContractError, 'lineage finished before launch' unless terminal.fetch('monotonic_finished_ns') >= launch.fetch('monotonic_started_ns')
      wall_started = Time.iso8601(launch.fetch('wall_started'))
      wall_finished = Time.iso8601(terminal.fetch('wall_finished'))
      raise ContractError, 'lineage wall clock finished before launch' if wall_finished < wall_started
      raise ContractError, 'lineage argv is invalid' unless launch['argv'].is_a?(Array) && !launch['argv'].empty? && launch['argv'].all? { |value| value.is_a?(String) }
      raise ContractError, 'lineage cwd is not absolute' unless launch['cwd'].is_a?(String) && launch['cwd'].start_with?('/')
      raise ContractError, 'lineage parent PID is invalid' unless launch['parent_pid'].is_a?(Integer) && launch['parent_pid'].positive?
      env = launch.fetch('environment'); exact_keys!(env, %w[allowlisted_keys sha256], 'environment')
      raise ContractError, 'invalid environment digest' unless env['sha256'].is_a?(String) && env['sha256'].match?(SHA256) && env['allowlisted_keys'].is_a?(Array) && env['allowlisted_keys'].sort == env['allowlisted_keys'].uniq
      if terminal['state'] == 'launch_failure'
        raise ContractError, 'launch failure has a PID or lacks failure detail' unless launch['pid'].nil? && launch['pgid'].nil? && launch['launch_failure'].is_a?(Hash)
        raise ContractError, 'launch failure cannot have a reap event' unless payload.fetch('reap_events').empty?
      else
        raise ContractError, 'spawned launch lacks PID/PGID' unless launch['pid'].is_a?(Integer) && launch['pid'].positive? && launch['pgid'] == launch['pid']
        raise ContractError, 'spawned launch lacks reap event' if payload.fetch('reap_events').empty?
        raise ContractError, 'successful launch reports surviving descendants' if terminal['state'] == 'exited' && terminal['descendants_survived'] != false
      end
      raise ContractError, 'event lists are invalid' unless payload['kill_events'].is_a?(Array) && payload['reap_events'].is_a?(Array)
      payload['kill_events'].each do |event|
        exact_keys!(event, %w[delivered error monotonic_ns reason signal target_pgid wall], 'kill event')
        raise ContractError, 'kill event targets another process group' unless event['target_pgid'] == launch['pgid']
        raise ContractError, 'kill event signal is invalid' unless event['signal'] == 'KILL' && [true, false].include?(event['delivered'])
        raise ContractError, 'kill event delivery/error disagree' unless event['delivered'] ? event['error'].nil? : [nil, 'Errno::EPERM'].include?(event['error'])
        raise ContractError, 'kill event time is invalid' unless event['monotonic_ns'].is_a?(Integer) && event['monotonic_ns'] >= launch['monotonic_started_ns'] && Time.iso8601(event['wall'])
      end
      payload['reap_events'].each do |event|
        exact_keys!(event, %w[exit monotonic_ns reason signal waited_pid wall], 'reap event')
        raise ContractError, 'reap event waited for another leader' unless event['waited_pid'] == launch['pid']
        raise ContractError, 'reap event status is invalid' unless [event['exit'], event['signal']].one? { |value| value.is_a?(Integer) }
        raise ContractError, 'reap event time is invalid' unless event['monotonic_ns'].is_a?(Integer) && event['monotonic_ns'] >= launch['monotonic_started_ns'] && Time.iso8601(event['wall'])
      end
      raise ContractError, 'deadline lacks deadline kill event' if terminal['state'] == 'deadline' && !payload['kill_events'].any? { |event| event['reason'] == 'deadline' }
      raise ContractError, 'process leak lacks descendant sweep' if terminal['state'] == 'process_leak' && !payload['kill_events'].any? { |event| event['reason'] == 'descendant_sweep' }
      unless terminal['state'] == 'launch_failure'
        event = payload['reap_events'].last
        raise ContractError, 'terminal status differs from reap event' unless terminal.values_at('exit', 'signal') == event.values_at('exit', 'signal')
      end
      artifacts = payload.fetch('artifacts')
      required_streams = case payload.fetch('output_mode')
                         when 'kernel-combined' then %w[combined]
                         when 'separate-nonordering' then %w[stdout stderr]
                         else raise ContractError, 'unknown lineage output mode'
                         end
      raise ContractError, 'lineage stream artifacts differ from output mode' unless artifacts.is_a?(Hash) && (required_streams - artifacts.keys).empty? &&
                                                                                 (%w[stdout stderr combined] & artifacts.keys).sort == required_streams.sort
      artifacts.each do |label, record|
        exact_keys!(record, %w[bytes parent_artifact path producer_launch_id sha256], "artifact #{label}")
        actual = artifact(record.fetch('path'), producer_launch_id: record.fetch('producer_launch_id'), parent_artifact: record['parent_artifact'])
        raise ContractError, "lineage artifact changed: #{label}" unless actual == record
      end
    rescue KeyError, TypeError, ArgumentError => error
      raise ContractError, "incomplete lineage payload: #{error.message}"
    end

    def exact_keys!(value, keys, label)
      raise ContractError, "#{label} is not an object" unless value.is_a?(Hash)
      raise ContractError, "#{label} fields differ" unless value.keys.sort == keys.sort
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    records = Corpus::ProcessLineage.reauthenticate!(ARGV.fetch(0))
    puts Corpus::ProcessLineage.canonical('schema' => Corpus::ProcessLineage::SCHEMA,
                                          'root_id' => records.first.fetch('root_id'),
                                          'launches' => records.length,
                                          'launch_ids' => records.map { |record| record.fetch('launch_id') })
  rescue IndexError, Corpus::ContractError => error
    warn "process-lineage: #{error.message}"
    exit 1
  end
end
