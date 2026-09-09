#!/usr/bin/env ruby
# frozen_string_literal: true
# Sprint: #118; Story-ID: 82a8a7687fec

require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require_relative '../corpus/executor'
require_relative '../go-full/native'

module BridgeCorpus
  module_function
  # Reviewed darwin/arm64 derivation in docs/bridge-corpus/bridge-pin.tsv.
  # Changing this profile requires rederivation and review, not a caller override.
  INVENTORY_DATA_SHA256 = 'a59a535e4418a4332d0087e3e39878495705aefc7798da0facccb6c1858486c5'
  INVENTORY_LIST_SHA256 = 'de444f71390a90f274b5176d8da92480ab72e2992d8885823712cd927e289f6c'
  GO_SHA256 = 'a19a71df81715c12d9a7e81bab036c12696fec1ddbd4258b48a2131a9080b267'

  def authenticated_inventory(path)
    data = File.binread(path).lines.reject { |line| line.start_with?('#') || line.strip.empty? }
    rows = data.map { |line| line.chomp.split("\t", -1) }
    raise Corpus::ContractError, 'expected 180 complete inventory rows' unless rows.length == 180 && rows.all? { |row| row.length == 11 }
    paths = rows.map(&:first)
    raise Corpus::ContractError, 'duplicate inventory package' unless paths.uniq.length == paths.length
    raise Corpus::ContractError, 'inventory path order or membership drift' unless paths == paths.sort && Digest::SHA256.hexdigest(paths.join("\n") + "\n") == INVENTORY_LIST_SHA256
    rows.each do |row|
      capability, policy = row.values_at(8, 9)
      expected = capability == 'reviewed-stdlib' ? 'toolchain' : 'refuse'
      raise Corpus::ContractError, 'inventory policy drift' unless policy == expected
    end
    raise Corpus::ContractError, 'inventory data authentication failed' unless Digest::SHA256.hexdigest(data.join) == INVENTORY_DATA_SHA256
    packages = rows.select { |row| row[9] == 'toolchain' }.map(&:first)
    refusals = rows.select { |row| row[9] == 'refuse' }.map { |row| { 'package' => row[0], 'capability' => row[8], 'policy' => row[9], 'reason' => row[10] } }
    raise Corpus::ContractError, 'inventory exposure denominator drift' unless packages.length == 178 && refusals.map { |row| row['package'] } == %w[plugin syscall/js]
    { 'file' => Corpus.file_record(path), 'data_sha256' => INVENTORY_DATA_SHA256,
      'list_sha256' => INVENTORY_LIST_SHA256, 'packages' => packages, 'policy_refusals' => refusals }
  end

  def authenticated_fixtures(options, identity)
    command = [options.fetch(:python), File.join(__dir__, 'fixtures.py'), 'validate',
               '--sdk-identity', options.fetch(:sdk_identity), '--path', options.fetch(:fixtures)]
    out, err, status = Open3.capture3(*command)
    raise Corpus::ContractError, "fixture authentication failed: #{err}" unless status.success?
    result = JSON.parse(out)
    unless result['verified'] == true && result['modules'] == 5 && result['sdk_manifest_sha256'] == identity.fetch('manifest_sha256')
      raise Corpus::ContractError, 'fixture identity/denominator mismatch'
    end
    result
  end

  def native(options)
    inventory_path = File.expand_path(options.fetch(:inventory))
    evidence = File.expand_path(options.fetch(:evidence))
    raise Corpus::ContractError, 'evidence path already exists' if File.exist?(evidence)
    inventory = authenticated_inventory(inventory_path)
    packages = inventory.fetch('packages')
    identity = JSON.parse(File.read(options.fetch(:sdk_identity)))
    raise Corpus::ContractError, 'unknown SDK identity schema' unless identity['schema'] == 'go-full-sdk/v1'
    unless identity.values_at('release', 'goos', 'goarch') == %w[go1.27.0 darwin arm64] && identity.dig('go', 'sha256') == GO_SHA256
      raise Corpus::ContractError, 'SDK does not match reviewed inventory host profile'
    end
    sdk = identity.fetch('root')
    go = File.join(sdk, 'bin/go')
    Corpus.authenticate_file(go, identity.fetch('go').fetch('sha256'))

    prepare = [options.fetch(:python), File.expand_path('../go-full/sdk.py', __dir__), '--source-cache', options.fetch(:source_cache),
               '--cache', File.dirname(identity.fetch('distribution_archive').fetch('path')),
               '--output', sdk, '--goos', identity.fetch('goos'), '--goarch', identity.fetch('goarch')]
    check, err, status = Open3.capture3(*prepare)
    raise Corpus::ContractError, "SDK reauthentication failed: #{err}" unless status.success? && JSON.parse(check) == identity

    fixtures = authenticated_fixtures(options, identity)
    FileUtils.mkdir_p(evidence)
    environment = {
      'PATH' => File.join(sdk, 'bin') + ':/usr/bin:/bin', 'GOROOT' => sdk,
      'HOME' => File.join(evidence, 'home'), 'TMPDIR' => File.join(evidence, 'tmp'),
      'GOCACHE' => File.join(evidence, 'gocache'), 'GOTOOLCHAIN' => 'local', 'GOENV' => 'off',
      'GOFLAGS' => '-p=1', 'GOWORK' => 'off', 'GOMODCACHE' => fixtures.fetch('gomodcache'), 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'GOMAXPROCS' => '4'
    }
    %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(environment.fetch(key)) }

    argv = [go, 'test', '-json', '-count=1', '-p=1', '-parallel=2', '-timeout=20m', *packages]
    stage = Corpus.capture(argv, cwd: sdk, log_prefix: File.join(evidence, 'native'), env: environment, timeout: 1800)

    events = GoFull::NativeEvents.new
    parse_error = nil
    begin
      File.foreach(stage.fetch('stdout').fetch('path')) do |line|
        record = JSON.parse(line)
        raise Corpus::ContractError, 'event outside expected package inventory' unless packages.include?(record['Package'])
        events.consume(line)
      end
    rescue JSON::ParserError, Corpus::ContractError => error
      parse_error = error.message
    end

    roots = packages.map do |package|
      { 'id' => package, 'axis' => 'package', 'observation' => events.observation(package) }
    end

    sources_intact = Open3.capture3(*prepare)
    integrity = sources_intact[2].success? && JSON.parse(sources_intact[0]) == identity

    fixtures_after = authenticated_fixtures(options, identity)
    raise Corpus::ContractError, 'fixtures changed during native execution' unless fixtures_after == fixtures
    inventory_after = authenticated_inventory(inventory_path)
    raise Corpus::ContractError, 'inventory changed during native execution' unless inventory_after == inventory

    summary = {
      'schema' => 'bridge-native/v1', 'native_only' => true, 'product_execution_claim' => false,
      'fixtures' => fixtures, 'fixture_integrity_after' => true, 'inventory' => inventory, 'sdk' => identity, 'native_stage' => stage, 'parse_error' => parse_error, 'sdk_integrity_after' => integrity,
      'events' => events.events, 'runtime_test_starts' => events.started.size,
      'runtime_test_terminals' => events.terminals.keys.count { |_pkg, test| test },
      'incomplete_test_events' => events.incomplete,
      'counts_by_axis' => roots.group_by { |r| r['axis'] }.transform_values { |rows| rows.group_by { |r| r.dig('observation', 'status') }.transform_values(&:length) },
    }
    complete = Corpus.success?(stage) && parse_error.nil? && integrity && events.incomplete.empty? &&
               events.terminals.values.none? { |event| event['Action'] == 'fail' } && roots.none? { |r| %w[fail missing].include?(r.dig('observation', 'status')) }
    summary['native_verdict'] = complete ? 'PASS' : 'FAIL'

    File.write(File.join(evidence, 'roots.jsonl'), roots.map { |r| Corpus.canonical(r) + "\n" }.join)
    File.write(File.join(evidence, 'summary.json'), Corpus.canonical(summary) + "\n")
    puts JSON.generate(summary)
    complete ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  options = { python: 'python3', source_cache: File.expand_path('../../.cache/go-full', __dir__) }
  OptionParser.new do |parser|
    parser.on('--sdk-identity PATH') { |v| options[:sdk_identity] = v }
    parser.on('--evidence PATH') { |v| options[:evidence] = v }
    parser.on('--inventory PATH') { |v| options[:inventory] = v }
    parser.on('--fixtures PATH') { |v| options[:fixtures] = v }
    parser.on('--source-cache PATH') { |v| options[:source_cache] = v }
  end.parse!
  begin
    exit BridgeCorpus.native(options)
  rescue KeyError, Corpus::ContractError, JSON::ParserError, SystemCallError => error
    warn "FATAL: #{error.message}"
    exit 2
  end
end
