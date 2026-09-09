#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story: #16; Story-ID: 82a8a7687fec
# Verify recorded native evidence; never launches go test or product execution.
require_relative 'native'

module BridgeCorpus
  module_function

  def replay(options)
    native = File.expand_path(options.fetch(:native))
    summary_path = File.join(native, 'summary.json')
    summary = JSON.parse(File.read(summary_path))
    unless summary['schema'] == 'bridge-native/v1' && summary['native_only'] == true && summary['product_execution_claim'] == false
      raise Corpus::ContractError, 'not native-only bridge evidence'
    end
    inventory = authenticated_inventory(File.expand_path(options.fetch(:inventory)))
    recorded_inventory = summary.fetch('inventory')
    %w[data_sha256 list_sha256 packages policy_refusals].each do |key|
      raise Corpus::ContractError, "recorded inventory differs: #{key}" unless inventory.fetch(key) == recorded_inventory.fetch(key)
    end
    Corpus.authenticate_file(options.fetch(:inventory), recorded_inventory.fetch('file').fetch('sha256'))
    identity = JSON.parse(File.read(options.fetch(:sdk_identity)))
    raise Corpus::ContractError, 'recorded SDK differs from supplied identity' unless identity == summary.fetch('sdk')
    # This reauthenticates both official SDK archives, the merged source tree,
    # and every fixture against the checked-in lock. It performs no tests.
    checked_fixtures = authenticated_fixtures(options.merge(fixtures: summary.fetch('fixtures').fetch('manifest').fetch('path')), identity)
    raise Corpus::ContractError, 'recorded fixtures differ' unless checked_fixtures == summary.fetch('fixtures')
    raise Corpus::ContractError, 'missing successful after-run integrity checks' unless summary['sdk_integrity_after'] == true && summary['fixture_integrity_after'] == true
    stage = summary.fetch('native_stage')
    %w[stdout stderr].each do |stream|
      record = stage.fetch(stream)
      raise Corpus::ContractError, "#{stream} file identity changed" unless Corpus.file_record(record.fetch('path')) == record
    end
    packages = inventory.fetch('packages')
    expected_argv = [File.join(identity.fetch('root'), 'bin/go'), 'test', '-json', '-count=1', '-p=1', '-parallel=2', '-timeout=20m', *packages]
    raise Corpus::ContractError, 'native command differs from complete reviewed profile' unless stage.fetch('argv') == expected_argv
    required_env = { 'GOMAXPROCS' => '4', 'GOFLAGS' => '-p=1', 'GOPROXY' => 'off', 'GOTOOLCHAIN' => 'local',
                     'GOROOT' => identity.fetch('root'), 'GOMODCACHE' => checked_fixtures.fetch('gomodcache') }
    required_env.each do |key, value|
      raise Corpus::ContractError, "native environment differs: #{key}" unless stage.fetch('environment')[key] == value
    end
    events = GoFull::NativeEvents.new
    File.foreach(stage.fetch('stdout').fetch('path')) do |line|
      event = JSON.parse(line)
      raise Corpus::ContractError, 'event package outside inventory' unless packages.include?(event['Package'])
      events.consume(line)
    end
    roots = packages.map { |package| { 'id' => package, 'axis' => 'package', 'observation' => events.observation(package) } }
    recorded_roots = File.foreach(File.join(native, 'roots.jsonl')).map { |line| JSON.parse(line) }
    raise Corpus::ContractError, 'recorded package observations differ from raw events' unless recorded_roots == roots
    counts = { 'package' => roots.group_by { |row| row.dig('observation', 'status') }.transform_values(&:length) }
    recomputed = { 'events' => events.events, 'runtime_test_starts' => events.started.size,
                   'runtime_test_terminals' => events.terminals.keys.count { |_pkg, test| test },
                   'incomplete_test_events' => events.incomplete, 'counts_by_axis' => counts }
    recomputed.each do |key, value|
      raise Corpus::ContractError, "summary disagrees with raw events: #{key}" unless summary.fetch(key) == value
    end
    complete = Corpus.success?(stage) && stage['descendants_survived'] == false && events.incomplete.empty? &&
               events.terminals.values.none? { |event| event['Action'] == 'fail' } &&
               roots.none? { |row| %w[fail missing].include?(row.dig('observation', 'status')) }
    verdict = complete ? 'PASS' : 'FAIL'
    raise Corpus::ContractError, 'recorded verdict or parse status disagrees with replay' unless summary['native_verdict'] == verdict && summary['parse_error'].nil?
    result = recomputed.merge('schema' => 'bridge-native-replay/v1', 'evidence_valid' => true, 'native_verdict' => verdict,
                              'product_execution_claim' => false, 'summary' => Corpus.file_record(summary_path),
                              'roots' => Corpus.file_record(File.join(native, 'roots.jsonl')), 'native_stdout' => stage['stdout'])
    puts JSON.generate(result)
    0
  end
end

if $PROGRAM_NAME == __FILE__
  options = { python: 'python3', inventory: File.expand_path('../../docs/bridge-corpus/stdlib-inventory.tsv', __dir__) }
  OptionParser.new do |parser|
    parser.on('--native PATH') { |v| options[:native] = v }
    parser.on('--sdk-identity PATH') { |v| options[:sdk_identity] = v }
    parser.on('--inventory PATH') { |v| options[:inventory] = v }
  end.parse!
  begin
    exit BridgeCorpus.replay(options)
  rescue KeyError, Corpus::ContractError, JSON::ParserError, SystemCallError => error
    warn "FATAL: #{error.message}"
    exit 2
  end
end
