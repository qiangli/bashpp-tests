#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story: #16; Story-ID: 82a8a7687fec

require 'minitest/autorun'
require 'tmpdir'
require_relative 'native'

class BridgeCorpusNativeTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @inventory = File.join(@tmpdir, 'stdlib-inventory.tsv')
    FileUtils.cp(File.expand_path('../../docs/bridge-corpus/stdlib-inventory.tsv', __dir__), @inventory)
    @rows = File.readlines(@inventory).reject { |line| line.start_with?('#') || line.strip.empty? }
    @identity = {
      'schema' => 'go-full-sdk/v1', 'release' => 'go1.27.0', 'root' => @tmpdir,
      'go' => { 'sha256' => BridgeCorpus::GO_SHA256 },
      'distribution_archive' => { 'path' => File.join(@tmpdir, 'archive.tar.gz') },
      'goos' => 'darwin', 'goarch' => 'arm64'
    }
    @identity_path = File.join(@tmpdir, 'identity.json')
    File.write(@identity_path, JSON.generate(@identity))
    @evidence = File.join(@tmpdir, 'evidence')
    @options = { inventory: @inventory, evidence: @evidence, sdk_identity: @identity_path,
                 source_cache: @tmpdir, python: 'python3' }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_authenticated_inventory_retains_all_paths_and_refusals
    inventory = BridgeCorpus.authenticated_inventory(@inventory)
    assert_equal 178, inventory['packages'].uniq.length
    assert_equal %w[plugin syscall/js], inventory['policy_refusals'].map { |r| r['package'] }
    assert_equal Corpus.digest(@inventory), inventory['file']['sha256']
  end

  def reject_rows(rows)
    File.write(@inventory, rows.join)
    assert_raises(Corpus::ContractError) { BridgeCorpus.authenticated_inventory(@inventory) }
  end

  def test_duplicate_rows_cannot_inflate_coverage
    reject_rows(Array.new(180, @rows.first))
  end

  def test_same_count_path_substitution_is_rejected
    reject_rows(@rows.map { |row| row.sub(/^archive\/tar\t/, "archive/FAKE\t") })
  end

  def test_policy_tamper_is_rejected
    reject_rows(@rows.map { |row| row.sub("\treviewed-stdlib\ttoolchain\t", "\treviewed-stdlib\trefuse\t") })
  end

  def test_source_fact_tamper_is_rejected
    rows = @rows.dup
    parts = rows[0].chomp.split("\t", -1)
    parts[3] = (parts[3].to_i + 1).to_s
    rows[0] = parts.join("\t") + "\n"
    reject_rows(rows)
  end

  def test_dropped_refusal_is_rejected
    reject_rows(@rows.reject { |row| row.start_with?("plugin\t") })
  end

  def test_malformed_row_is_rejected
    reject_rows(@rows + ["malformed\n"])
  end

  def test_wrong_sdk_host_is_rejected_before_execution
    @identity['goarch'] = 'amd64'
    File.write(@identity_path, JSON.generate(@identity))
    assert_raises(Corpus::ContractError) { BridgeCorpus.native(@options) }
    refute File.exist?(@evidence)
  end

  def run_events(events, exit_code: 0)
    stdout = File.join(@tmpdir, 'stdout.jsonl')
    File.write(stdout, events.map { |event| JSON.generate(event) + "\n" }.join)
    stage = { 'stdout' => { 'path' => stdout }, 'spawned' => true, 'state' => 'exited', 'exit' => exit_code, 'signal' => nil }
    Open3.stub :capture3, [JSON.generate(@identity), '', Struct.new(:success?).new(true)] do
      Corpus.stub :authenticate_file, true do
        Corpus.stub :capture, stage do
          capture_io { @result = BridgeCorpus.native(@options) }
        end
      end
    end
    JSON.parse(File.read(File.join(@evidence, 'summary.json')))
  end

  def package_events
    BridgeCorpus.authenticated_inventory(@inventory)['packages'].map { |path| { 'Action' => 'pass', 'Package' => path } }
  end

  def test_complete_native_result_carries_pinned_denominator_without_product_credit
    summary = run_events(package_events)
    assert_equal 0, @result
    assert_equal 'PASS', summary['native_verdict']
    assert_equal false, summary['product_execution_claim']
    assert_equal 178, summary['counts_by_axis']['package']['pass']
    assert_equal 2, summary['inventory']['policy_refusals'].length
  end

  def test_missing_package_terminal_fails
    summary = run_events(package_events.drop(1))
    assert_equal 1, @result
    assert_equal 1, summary['counts_by_axis']['package']['missing']
  end

  def test_unexpected_package_fails
    summary = run_events(package_events + [{ 'Action' => 'pass', 'Package' => 'unreviewed/package' }])
    assert_equal 'FAIL', summary['native_verdict']
    assert_match(/outside expected/, summary['parse_error'])
  end

  def test_duplicate_terminal_fails
    events = package_events
    summary = run_events(events + [events.first])
    assert_equal 'FAIL', summary['native_verdict']
    assert_match(/duplicate native terminal/, summary['parse_error'])
  end

  def test_unfinished_runtime_test_fails
    summary = run_events(package_events + [{ 'Action' => 'run', 'Package' => 'fmt', 'Test' => 'TestUnfinished' }])
    assert_equal 'FAIL', summary['native_verdict']
    assert_equal [['fmt', 'TestUnfinished']], summary['incomplete_test_events']
  end

  def test_failed_child_cannot_be_hidden_by_successful_parent_and_exit
    events = package_events + [
      { 'Action' => 'run', 'Package' => 'fmt', 'Test' => 'TestFailed' },
      { 'Action' => 'fail', 'Package' => 'fmt', 'Test' => 'TestFailed' }
    ]
    summary = run_events(events)
    assert_equal 'FAIL', summary['native_verdict']
    assert_equal 1, @result
  end

  def test_sdk_reauthentication_failure_prevents_execution
    Open3.stub :capture3, ['', 'tampered SDK', Struct.new(:success?).new(false)] do
      Corpus.stub :authenticate_file, true do
        error = assert_raises(Corpus::ContractError) { BridgeCorpus.native(@options) }
        assert_match(/SDK reauthentication failed/, error.message)
      end
    end
    refute File.exist?(@evidence)
  end

  def test_native_failures_are_not_reclassified_as_success
    events = package_events
    events.first['Action'] = 'fail'
    summary = run_events(events, exit_code: 1)
    assert_equal 1, @result
    assert_equal 'FAIL', summary['native_verdict']
    assert_equal 1, summary['counts_by_axis']['package']['fail']
  end
end
