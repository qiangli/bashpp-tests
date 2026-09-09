# frozen_string_literal: true
# Sprint: #118; Story-ID: 3abd77da923c
# Runs upstream test harnesses unchanged. Output is native-oracle evidence only.
require 'json'
require 'optparse'
require 'fileutils'
require 'digest'
require ENV.fetch('GO_FULL_CORPUS_LIB', File.expand_path('../corpus/executor.rb', __dir__))

module GoFull
  class NativeEvents
    TERMINAL = %w[pass fail skip].freeze
    attr_reader :terminals, :started, :events

    def initialize
      @terminals, @started, @events = {}, {}, 0
    end

    def consume(line)
      record = JSON.parse(line)
      raise Corpus::ContractError, 'native event missing package/action' unless record['Package'].is_a?(String) && record['Action'].is_a?(String)
      @events += 1
      key = [record['Package'], record['Test']]
      if record['Action'] == 'run'
        raise Corpus::ContractError, "duplicate native test start: #{key}" if @started.key?(key)
        @started[key] = record
      end
      if TERMINAL.include?(record['Action'])
        raise Corpus::ContractError, "native test terminal without start: #{key}" if record['Test'] && !@started.key?(key)
        raise Corpus::ContractError, "duplicate native terminal: #{key}" if @terminals.key?(key)
        @terminals[key] = record
      end
    end

    def observation(package, test = nil)
      terminal = @terminals[[package, test]]
      return { 'status' => terminal.fetch('Action'), 'event' => terminal, 'evidence_kind' => 'native-go-only' } if terminal
      # A real skipped parent explains absent registration; it cannot confer a
      # successful execution on the child. Retain that exact parent event.
      parts = test&.split('/') || []
      until parts.empty?
        parts.pop
        ancestor = @terminals[[package, parts.empty? ? nil : parts.join('/')]]
        if ancestor && ancestor['Action'] == 'skip'
          return { 'status' => 'ancestor-skip', 'event' => ancestor, 'evidence_kind' => 'native-go-only' }
        end
      end
      { 'status' => 'missing', 'evidence_kind' => 'native-go-only', 'reason' => 'expected terminal event absent' }
    end

    def incomplete
      @started.keys.reject { |key| @terminals.key?(key) }
    end
  end

  module_function

  def jsonlines(path)
    File.foreach(path).map { |line| JSON.parse(line) }
  end

  def native(options)
    inventory_dir = File.expand_path(options.fetch(:inventory))
    evidence = File.expand_path(options.fetch(:evidence))
    raise Corpus::ContractError, 'evidence path already exists' if File.exist?(evidence)
    identity = JSON.parse(File.read(options.fetch(:sdk_identity)))
    raise Corpus::ContractError, 'unknown SDK identity schema' unless identity['schema'] == 'go-full-sdk/v1'
    sdk = identity.fetch('root')
    go = File.join(sdk, 'bin/go')
    Corpus.authenticate_file(go, identity.fetch('go').fetch('sha256'))
    # Reauthenticate and rederive the merged SDK; no installed toolchain is
    # trusted on a go-version assertion. This helper does not execute Go.
    prepare = [options.fetch(:python), File.join(__dir__, 'sdk.py'), '--source-cache', options.fetch(:source_cache),
               '--cache', File.dirname(identity.fetch('distribution_archive').fetch('path')),
               '--output', sdk, '--goos', identity.fetch('goos'), '--goarch', identity.fetch('goarch')]
    check, err, status = Open3.capture3(*prepare)
    raise Corpus::ContractError, "SDK reauthentication failed: #{err}" unless status.success? && JSON.parse(check) == identity
    inventory_check = [options.fetch(:python), File.join(__dir__, 'inventory.py'), 'validate', '--cache', options.fetch(:source_cache), '--output', inventory_dir]
    _out, err, status = Open3.capture3(*inventory_check)
    raise Corpus::ContractError, "inventory validation failed: #{err}" unless status.success?
    package_rows = jsonlines(File.join(inventory_dir, 'package-roots.jsonl'))
    packages = package_rows.map { |r| r.fetch('package') }
    FileUtils.mkdir_p(evidence)
    environment = {
      'PATH' => File.join(sdk, 'bin') + ':/usr/bin:/bin', 'GOROOT' => sdk,
      'HOME' => File.join(evidence, 'home'), 'TMPDIR' => File.join(evidence, 'tmp'),
      'GOCACHE' => File.join(evidence, 'gocache'), 'GOTOOLCHAIN' => 'local', 'GOENV' => 'off',
      'GOFLAGS' => '', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'GOMAXPROCS' => '2'
    }
    %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(environment.fetch(key)) }
    # Serial packages plus bounded intra-package parallelism. All 26 package
    # roots are run; this naturally includes all historical and checker roots.
    argv = [go, 'test', '-json', '-count=1', '-p=1', "-parallel=#{options.fetch(:parallel)}", "-timeout=#{options.fetch(:timeout)}s", *packages]
    stage = Corpus.capture(argv, cwd: sdk, log_prefix: File.join(evidence, 'native'), env: environment,
                           timeout: options.fetch(:timeout) * packages.length + 60)
    events = NativeEvents.new
    parse_error = nil
    begin
      File.foreach(stage.fetch('stdout').fetch('path')) { |line| events.consume(line) }
    rescue JSON::ParserError, Corpus::ContractError => error
      parse_error = error.message
    end
    roots = jsonlines(File.join(inventory_dir, 'testdir-roots.jsonl')).map do |root|
      { 'id' => root.fetch('id'), 'axis' => 'testdir', 'observation' => events.observation('cmd/internal/testdir', root.fetch('upstream_subtest')) }
    end
    roots.concat(jsonlines(File.join(inventory_dir, 'typechecker-roots.jsonl')).map do |root|
      package, test = root.fetch('id').split(':', 2)
      { 'id' => root.fetch('id'), 'axis' => 'typechecker', 'observation' => events.observation(package, test) }
    end)
    roots.concat(package_rows.map do |root|
      { 'id' => root.fetch('id'), 'axis' => 'package', 'observation' => events.observation(root.fetch('package')) }
    end)
    sources_intact = Open3.capture3(*prepare)
    integrity = sources_intact[2].success? && JSON.parse(sources_intact[0]) == identity
    summary = {
      'schema' => 'go-full-native/v1', 'evidence_kind' => 'native-go-only', 'product_execution_claim' => false,
      'sdk' => identity, 'native_stage' => stage, 'parse_error' => parse_error, 'sdk_integrity_after' => integrity,
      'events' => events.events, 'runtime_test_starts' => events.started.size,
      'runtime_test_terminals' => events.terminals.keys.count { |_pkg, test| test },
      'incomplete_test_events' => events.incomplete,
      'inventory' => %w[summary.json package-roots.jsonl testdir-roots.jsonl typechecker-roots.jsonl].to_h { |name| [name, Corpus.file_record(File.join(inventory_dir, name))] },
      'counts_by_axis' => roots.group_by { |r| r['axis'] }.transform_values { |rows| rows.group_by { |r| r.dig('observation', 'status') }.transform_values(&:length) },
      'nested_process_instrumentation' => 'not-instrumented', 'generated_programs_observed' => nil,
      'remaining_obligation' => 'Native Go harness outcomes do not establish product execution or nested generated-program coverage.'
    }
    complete = Corpus.success?(stage) && parse_error.nil? && integrity && events.incomplete.empty? && roots.none? { |r| %w[fail missing].include?(r.dig('observation', 'status')) }
    summary['native_verdict'] = complete ? 'PASS' : 'FAIL'
    File.write(File.join(evidence, 'roots.jsonl'), roots.map { |r| Corpus.canonical(r) + "\n" }.join)
    File.write(File.join(evidence, 'summary.json'), Corpus.canonical(summary) + "\n")
    puts JSON.generate(summary.slice('native_verdict', 'evidence_kind', 'product_execution_claim', 'counts_by_axis', 'runtime_test_starts', 'runtime_test_terminals'))
    complete ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  options = { inventory: File.expand_path('../../docs/go-full', __dir__), source_cache: File.expand_path('../../.cache/go-full', __dir__), python: 'python3', parallel: 2, timeout: 1800 }
  OptionParser.new do |parser|
    parser.on('--sdk-identity PATH') { |v| options[:sdk_identity] = v }
    parser.on('--evidence PATH') { |v| options[:evidence] = v }
    parser.on('--inventory PATH') { |v| options[:inventory] = v }
    parser.on('--source-cache PATH') { |v| options[:source_cache] = v }
    parser.on('--parallel N', Integer) { |v| options[:parallel] = v }
    parser.on('--timeout N', Integer) { |v| options[:timeout] = v }
  end.parse!
  begin
    raise Corpus::ContractError, 'positive timeout/parallel required' unless options[:parallel].positive? && options[:timeout].positive?
    exit GoFull.native(options)
  rescue KeyError, Corpus::ContractError, JSON::ParserError, SystemCallError => error
    warn "FATAL: #{error.message}"
    exit 2
  end
end
