# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
#
# Product adapter for the official Go type-checker roots (go/types TestCheck,
# TestSpec, TestExamples, TestFixedbugs, TestLocal and their cmd/compile types2
# twins). The two obligations these roots carry are executed for real:
#
#   check-original-fixture             the candidate GoSource frontend checks the
#                                      unmodified fixture bytes, in both the
#                                      interpreted (--check) and the compiled
#                                      (transpile) checking phase;
#   match-source-positioned-diagnostics the emitted diagnostics are adjudicated
#                                      against the ERROR/ERRORx annotations in
#                                      the original source, at their positions.
#
# Deliberate non-goals, so that no root can acquire an unearned PASS:
#   * the pinned native go/types checker is never run as the product; it is only
#     read as source of truth for the harness semantics that are ported here;
#   * no fixture body is forwarded, rewritten, reformatted or regenerated;
#   * an exit status alone never establishes a PASS - every observed diagnostic
#     must consume an annotation and every annotation must be reported;
#   * exact recipe options this adapter cannot honour (other harness flags, build-tag
#     gating, multi-file packages) FAIL with their obligations named as
#     unfinished phases. They are never converted into a new skip.
require 'json'
require 'fileutils'
require 'digest'

module GoFullTypechecker
  module_function

  PHASES = %w[check-original-fixture match-source-positioned-diagnostics].freeze
  MODES = %w[interpreted compiled].freeze
  MATCHER_DIR = File.join(__dir__, 'typecheck-diagnostics')
  MAX_FLAG_LINE = 256

  # Port of check_test.go parseFlags: only a first line that is a line comment
  # whose first non-blank character after "//" is "-" carries harness flags.
  def recipe_flags(source)
    text = source.dup.force_encoding(Encoding::BINARY)
    return [] unless text.start_with?('//')
    rest = text[2..]
    cut = rest.index('-')
    return [] if cut.nil? || !rest[0...cut].strip.empty?
    stop = rest.index("\n")
    raise Corpus::ContractError, 'flags comment line too long' if stop.nil? || stop > MAX_FLAG_LINE
    rest[0...stop].split
  end

  # Parse the supported upstream flag without changing any fixture bytes.
  # Like flag.FlagSet, repeated -lang values use the last value. Everything
  # else remains an explicit unsupported option, never a silent default.
  def checker_flags(source)
    flags = recipe_flags(source)
    unsupported = []
    version = nil
    index = 0
    while index < flags.length
      flag = flags[index]
      if flag == '-lang'
        index += 1
        version = flags[index]
        unsupported << 'harness-flag:-lang:missing-value' unless version
      elsif flag.start_with?('-lang=')
        version = flag.delete_prefix('-lang=')
      else
        unsupported << "harness-flag:#{flag.split('=', 2).first}"
      end
      index += 1
    end
    if version && !/\Ago1\.(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*))?\z/.match?(version)
      unsupported << 'harness-flag:-lang:invalid-value'
    end
    { 'flags' => flags, 'go_version' => version, 'unsupported' => unsupported.uniq.sort }
  end

  # Every exact recipe option of this root that the adapter cannot execute.
  # An empty list means both phases can be attempted for real.
  def unsupported_options(root, source_root)
    reasons = []
    files = root.fetch('input_files')
    reasons << 'joint-multi-file-package-check' unless files.length == 1
    root.fetch('build_constraints').each do |file, constraints|
      reasons << "build-tag-applicability:#{file}" unless constraints.empty?
    end
    files.each do |relative|
      begin
        reasons.concat(checker_flags(File.binread(Corpus.safe_path(source_root, relative))).fetch('unsupported'))
      rescue Corpus::ContractError, SystemCallError
        # An unreadable or unparsable recipe header is an unexecutable option,
        # never a reason to abandon the surrounding root accounting.
        reasons << "unreadable-recipe-header:#{relative}"
      end
    end
    reasons.uniq.sort
  end

  def adaptable?(root, source_root)
    root['axis'] == 'typechecker' && unsupported_options(root, source_root).empty?
  end

  # Builds the positioned matcher from its own immutable sources. This is a
  # separate binary from tools/go-full/diagnostics, whose testdir errorcheck
  # semantics are different and stay untouched.
  def build_matcher(evidence, sdk_identity, runtime = nil)
    inputs = (Dir[File.join(MATCHER_DIR, '*.go')] + [File.join(MATCHER_DIR, 'go.mod')]).sort
    raise Corpus::ContractError, 'typechecker matcher sources are missing' if inputs.length < 4
    before = inputs.to_h { |path| [path, Corpus.file_record(path)] }
    directory = File.join(evidence, 'typecheck-diagnostics-tool')
    FileUtils.mkdir_p(directory)
    env = { 'PATH' => '/usr/bin:/bin', 'GOTOOLCHAIN' => 'local', 'GOROOT' => sdk_identity.fetch('root'), 'GOMAXPROCS' => '1',
            'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'GOENV' => 'off', 'GOFLAGS' => '',
            'HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => File.join(directory, 'gocache') }
    env = GoFullProduct.stage_environment(runtime, directory) if runtime
    %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(env.fetch(key)) }
    binary = File.join(directory, 'typecheck-diagnostics')
    stage = Corpus.capture([File.join(sdk_identity.fetch('root'), 'bin/go'), 'build', '-p=1', '-trimpath', '-o', binary, '.'],
                           cwd: MATCHER_DIR, log_prefix: File.join(directory, 'build'), env: env, timeout: 180)
    raise Corpus::ContractError, 'typechecker matcher failed to build' unless Corpus.success?(stage) && File.executable?(binary) && File.size?(binary)
    raise Corpus::ContractError, 'typechecker matcher sources changed during build' unless before.all? { |path, record| Corpus.digest(path) == record.fetch('sha256') }
    { 'binary' => Corpus.file_record(binary), 'sources' => before, 'build_stage' => stage, 'runtime' => runtime,
      'semantics' => 'ported from the pinned SDK src/go/types/check_test.go and commentMap_test.go',
      'scope' => 'adjudicates retained product output only; never type-checks and never runs a fixture' }
  end

  def checking_argv(bashy, mode, selector, generated, go_version = nil)
    version_flags = go_version ? ["--go-version=#{go_version}"] : []
    if mode == 'interpreted'
      [bashy, '--bashpp', '--source=go', '--check', *version_flags, selector]
    else
      [bashy, 'transpile', '--bashpp', '--source=go', *version_flags, selector, '-o', generated, '--map', generated + '.map']
    end
  end

  def checking_environment(directory, sdk_identity, runtime = nil)
    return GoFullProduct.stage_environment(runtime, directory) if runtime
    { 'PATH' => '/usr/bin:/bin', 'GOROOT' => sdk_identity.fetch('root'), 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'GOENV' => 'off',
      'HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => File.join(directory, 'gocache'),
      'GOMAXPROCS' => '2', 'GOFLAGS' => '-p=2', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'BASHY_HINTS' => 'off' }
  end

  # Runs the matcher over one retained checking phase and returns its response.
  def adjudicate(matcher, request, directory, timeout)
    FileUtils.mkdir_p(directory)
    payload = File.join(directory, 'match-request.json')
    File.write(payload, Corpus.canonical(request) + "\n")
    environment = matcher['runtime'] ? GoFullProduct.stage_environment(matcher.fetch('runtime'), directory) : { 'PATH' => '/usr/bin:/bin', 'LC_ALL' => 'C', 'TZ' => 'UTC' }
    stage = Corpus.capture([matcher.fetch('binary').fetch('path')], cwd: directory,
                           log_prefix: File.join(directory, 'match'), env: environment,
                           timeout: timeout, stdin: payload)
    raise Corpus::ContractError, 'positioned matcher did not terminate' unless stage['spawned'] && stage['state'] == 'exited' && stage['signal'].nil?
    body = File.binread(stage.fetch('stdout').fetch('path'))
    response = JSON.parse(body)
    raise Corpus::ContractError, 'positioned matcher returned an unknown verdict' unless %w[PASS FAIL].include?(response['verdict'])
    raise Corpus::ContractError, 'positioned matcher exit disagrees with its verdict' unless (stage['exit'] == 0) == (response['verdict'] == 'PASS')
    { 'request' => Corpus.file_record(payload), 'stage' => stage, 'response' => response }
  end

  # Executes both checking phases of one adaptable root against the original,
  # byte-identical fixture and adjudicates each against the source annotations.
  def execute(root:, options:, source_root:, evidence:, sdk_identity:, candidate:, matcher:)
    unsupported = unsupported_options(root, source_root)
    raise Corpus::ContractError, "unsupported typechecker recipe: #{unsupported.join(', ')}" unless unsupported.empty?
    relative = root.fetch('input_files').fetch(0)
    original = Corpus.safe_path(source_root, relative)
    record = Corpus.file_record(original)
    configuration = checker_flags(File.binread(original))
    modes = MODES.to_h do |mode|
      directory = Corpus.safe_path(File.join(evidence, 'typechecker'), root.fetch('id') + '/' + mode)
      work = File.join(directory, 'work')
      copy = Corpus.safe_path(work, relative)
      FileUtils.mkdir_p(File.dirname(copy))
      FileUtils.cp(original, copy)
      # The checked input is the complete original file, byte for byte.
      raise Corpus::ContractError, 'fixture copy is not byte-identical' unless Corpus.digest(copy) == record.fetch('sha256') && File.size(copy) == record.fetch('bytes')
      scaffold = options[:runtime] ? options[:runtime].fetch('module_files') : {}
      raise Corpus::ContractError, 'scaffold overlaps original fixture' if scaffold.key?(relative)
      scaffold.each { |name, bytes| File.binwrite(Corpus.safe_path(work, name), bytes) }
      generated = File.join(directory, 'generated.go')
      env = checking_environment(directory, sdk_identity, options[:runtime])
      %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(env.fetch(key)) }
      Corpus.authenticate_file(options.fetch(:bashy), candidate.fetch('launcher_sha256'))
      Corpus.authenticate_file(options.fetch(:bashy) + '.real', candidate.fetch('payload_sha256'))
      argv = checking_argv(options.fetch(:bashy), mode, relative, generated, configuration.fetch('go_version'))
      stage = Corpus.capture(argv, cwd: work, log_prefix: File.join(directory, 'check'), env: env, timeout: options.fetch(:timeout))
      intact = Corpus.digest(copy) == record.fetch('sha256') && Corpus.digest(original) == record.fetch('sha256')
      intact &&= scaffold.all? { |name, bytes| File.binread(Corpus.safe_path(work, name)) == bytes }
      observation = { 'checker_configuration' => configuration, 'module_files' => scaffold.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }, 'mode' => mode, 'stage_role' => 'checking-phase', 'phases' => PHASES, 'stage' => stage,
                      'input_integrity' => intact, 'inputs' => { relative => record }, 'verdict' => 'FAIL' }
      if !intact
        next [mode, observation.merge('reason' => 'fixture bytes changed across the checking phase')]
      end
      if stage['state'] != 'exited' || !stage['spawned'] || stage['signal']
        next [mode, observation.merge('reason' => "checking phase did not exit normally: #{stage['state']}")]
      end
      request = { 'family' => root.fetch('family'), 'mode' => mode, 'column_tolerance' => root.fetch('column_tolerance'),
                  'sources' => [{ 'path' => copy, 'short' => relative, 'sha256' => record.fetch('sha256') }],
                  'stdout' => stage.fetch('stdout').slice('path', 'sha256'), 'stderr' => stage.fetch('stderr').slice('path', 'sha256'),
                  'process' => { 'spawned' => stage.fetch('spawned'), 'state' => stage.fetch('state'), 'exit' => stage.fetch('exit'), 'signal' => stage.fetch('signal') } }
      adjudication = adjudicate(matcher, request, directory, options.fetch(:timeout))
      observation['match'] = adjudication
      observation['verdict'] = adjudication.dig('response', 'verdict')
      observation['reason'] = adjudication.dig('response', 'reason') unless observation['verdict'] == 'PASS'
      [mode, observation]
    end
    # Both checking phases must independently satisfy both obligations; a single
    # agreeing mode is not a complete recipe.
    complete = modes.keys.sort == MODES.sort && modes.values.all? { |m| m['verdict'] == 'PASS' }
    { 'verdict' => complete ? 'PASS' : 'FAIL', 'modes' => modes,
      'evidence' => { 'adapter' => 'go-full-typechecker/v1', 'checker_configuration' => configuration, 'phases' => PHASES, 'checked_fixture' => record,
                      'column_tolerance' => root.fetch('column_tolerance'), 'family' => root.fetch('family'),
                      'runner_contract' => root.fetch('runner'), 'runner_sha256' => root.fetch('runner_sha256'),
                      'mode_denominator' => { 'expected' => MODES.length, 'observed' => modes.length },
                      'measured_process_seconds' => modes.values.sum { |m| m.dig('stage', 'duration_seconds') || 0 },
                      'native_oracle_binding' => 'the retained native observation gates PASS; it never supplies diagnostics',
                      'credit_rule' => 'PASS requires every observed diagnostic matched and every source annotation reported, in both checking phases' } }
  end
end
