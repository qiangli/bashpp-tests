# frozen_string_literal: true
# Sprint: #148; Packet: 148.1; Story-ID: 07091aa9a5d4

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/corpus/executor'

class ProcessLineageTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('process-lineage-')
    @ledger = File.join(@tmp, 'lineage.jsonl')
    @env = { 'PATH' => ENV.fetch('PATH', ''), 'LC_ALL' => 'C', 'TOKEN' => 'must-not-leak' }
    @sequence = 0
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def capture(code, timeout: 2, parent: nil, root: 'testdir:lineage.go', command: nil)
    @sequence += 1
    Corpus.capture(command || [RbConfig.ruby, '-e', code], cwd: @tmp, env: @env, timeout: timeout,
                   log_prefix: File.join(@tmp, 'logs', "stage-#{@sequence}"),
                   lineage: { path: @ledger, root_id: root, stage_id: "mode/stage-#{@sequence}",
                              parent_launch_id: parent })
  end

  def records
    Corpus::ProcessLineage.authenticate!(@ledger)
  end

  def rewrite
    envelopes = File.readlines(@ledger, chomp: true).map { |line| JSON.parse(line) }
    yield envelopes
    envelopes.each { |entry| entry['payload_sha256'] = Corpus::ProcessLineage.payload_sha256(entry.fetch('payload')) }
    File.write(@ledger, envelopes.map { |entry| Corpus::ProcessLineage.canonical(entry) }.join("\n") + "\n")
  end

  def fresh_verify
    Open3.capture3(RbConfig.ruby, File.expand_path('../../tools/corpus/process_lineage.rb', __dir__), @ledger)
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_common_capture_persists_full_versioned_contract_without_environment_values
    result = capture("STDOUT.write('ok')")
    payload = records.fetch(0)
    assert_equal Corpus::ProcessLineage::SCHEMA, payload['schema']
    assert_equal 'testdir:lineage.go', payload['root_id']
    assert_equal 'mode/stage-1', payload['stage_id']
    assert_match Corpus::ProcessLineage::LAUNCH_ID, payload['launch_id']
    assert_nil payload['parent_launch_id']
    assert_equal payload.dig('launch', 'pid'), payload.dig('launch', 'pgid')
    assert_equal @env.keys.sort, payload.dig('launch', 'environment', 'allowlisted_keys')
    assert_match Corpus::ProcessLineage::SHA256, payload.dig('launch', 'environment', 'sha256')
    refute_includes File.binread(@ledger), 'must-not-leak'
    Time.iso8601(payload.dig('launch', 'wall_started'))
    Time.iso8601(payload.dig('terminal', 'wall_finished'))
    assert_equal false, payload.dig('terminal', 'descendants_survived')
    assert_equal 1, payload['reap_events'].length
    assert_equal [], payload['kill_events']
    assert_equal result.dig('lineage', 'launch_id'), payload['launch_id']
    _out, error, status = fresh_verify
    assert status.success?, error
  end

  def test_launch_failure_is_a_durable_attempted_launch_record
    result = capture('', command: ['/certainly/not/a/tool'])
    refute result['spawned']
    assert_equal 'launch_failure', result['state']
    payload = records.fetch(0)
    assert_nil payload.dig('launch', 'pid')
    assert_equal 'Errno::ENOENT', payload.dig('launch', 'launch_failure', 'class')
    assert_equal [], payload['reap_events']
    assert_equal %w[stderr stdout], payload['artifacts'].keys.sort
  end

  def test_deadline_and_leak_have_explicit_kill_and_reap_events_and_no_survivor
    deadline = capture("STDOUT.sync=true; puts fork { sleep 30 }; sleep 30", timeout: 0.1)
    deadline_child = Integer(File.read(deadline.dig('stdout', 'path')).strip, 10)
    leak = capture("STDOUT.sync=true; puts fork { sleep 30 }; exit! 0")
    leak_child = Integer(File.read(leak.dig('stdout', 'path')).strip, 10)
    first, second = records
    assert_equal 'deadline', first.dig('terminal', 'state')
    assert_equal 'deadline', first.dig('kill_events', 0, 'reason')
    assert_equal 'leader_wait_after_deadline', first.dig('reap_events', 0, 'reason')
    assert_equal 'process_leak', second.dig('terminal', 'state')
    assert_equal 'descendant_sweep', second.dig('kill_events', 0, 'reason')
    [first, second].each { |payload| assert_equal false, payload.dig('terminal', 'descendants_survived') }
    refute alive?(deadline_child)
    refute alive?(leak_child)
  end

  def test_nested_launch_and_generated_artifact_parent_join_reauthenticate
    parent = capture("STDOUT.write('package main')")
    parent_id = parent.dig('lineage', 'launch_id')
    generated = File.join(@tmp, 'generated.go')
    File.write(generated, 'package main')
    @sequence += 1
    Corpus::ProcessLineage.run([RbConfig.ruby, '-e', 'exit 0'], cwd: @tmp, env: @env, timeout: 2,
                               lineage_path: @ledger, log_prefix: File.join(@tmp, 'logs', "stage-#{@sequence}"),
                               root_id: 'testdir:lineage.go', stage_id: "mode/stage-#{@sequence}", parent_launch_id: parent_id,
                               artifact_paths: { 'generated_source' => generated },
                               artifact_parents: { 'generated_source' => { 'launch_id' => parent_id, 'artifact' => 'stdout' } })
    assert_equal parent_id, records.last['parent_launch_id']
    assert_equal parent_id, records.last.dig('artifacts', 'generated_source', 'parent_artifact', 'launch_id')
    _out, error, status = fresh_verify
    assert status.success?, error
  end

  def test_missing_cross_root_forward_and_duplicate_parent_joins_fail_closed
    parent = capture('exit 0')
    capture('exit 0', parent: parent.dig('lineage', 'launch_id'))
    mutations = {
      'missing' => ->(rows) { rows[1]['payload']['parent_launch_id'] = SecureRandom.uuid },
      'forward' => ->(rows) { rows[0]['payload']['parent_launch_id'] = rows[1]['payload']['launch_id'] },
      'cross-root' => ->(rows) { rows[1]['payload']['root_id'] = 'other:root' },
      'duplicate' => ->(rows) { rows[1]['payload']['launch_id'] = rows[0]['payload']['launch_id']; rows[1]['payload']['artifacts'].each_value { |a| a['producer_launch_id'] = rows[0]['payload']['launch_id'] } }
    }
    original = File.binread(@ledger)
    mutations.each do |label, mutation|
      File.binwrite(@ledger, original)
      rewrite { |rows| mutation.call(rows) }
      assert_raises(Corpus::ContractError, label) { records }
    end
  end

  def test_resigned_kill_and_reap_event_tampering_fails_semantic_authentication
    capture("STDOUT.sync=true; puts fork { sleep 30 }; sleep 30", timeout: 0.1)
    original = File.binread(@ledger)
    {
      'kill target' => ->(payload) { payload['kill_events'][0]['target_pgid'] += 1 },
      'reap pid' => ->(payload) { payload['reap_events'][0]['waited_pid'] += 1 },
      'missing deadline kill' => ->(payload) { payload['kill_events'].clear }
    }.each do |label, mutation|
      File.binwrite(@ledger, original)
      rewrite { |rows| mutation.call(rows[0]['payload']) }
      assert_raises(Corpus::ContractError, label) { records }
    end
  end

  def test_digest_semantic_and_artifact_tampering_fail_in_a_fresh_process
    result = capture("STDOUT.write('original')")
    original = File.binread(@ledger)
    envelope = JSON.parse(original)
    envelope['payload']['stage_id'] = 'changed'
    File.write(@ledger, JSON.generate(envelope) + "\n")
    assert_match(/payload digest mismatch/, fresh_verify[1])

    File.binwrite(@ledger, original)
    rewrite { |rows| rows[0]['payload']['deadline']['monotonic_expires_ns'] += 1 }
    assert_match(/deadline arithmetic differs/, fresh_verify[1])

    File.binwrite(@ledger, original)
    File.binwrite(result.dig('stdout', 'path'), 'changed')
    assert_match(/artifact changed: stdout/, fresh_verify[1])
  end
end
