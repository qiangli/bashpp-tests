# frozen_string_literal: true
# Sprint: #148; Story: #30; Story-ID: cdfb5e220f8e

require 'json'
require 'digest'
require 'fileutils'
require_relative '../corpus/executor'
require_relative 'module_context'

# The immutable identity gate between root selection and process launch.
#
# `prepare!` authenticates every input before returning an authorization.  The
# authorization can be persisted and `load!`ed by a different process; load!
# re-authenticates the outer receipt and every referenced byte before allowing
# a verdict to be consumed.  Callers retain the returned receipt file digest as
# the trust anchor (for example in the root/stage lineage record).
module GoFullExecutionIdentity
  module_function

  SCHEMA = 'go-full-execution-identity/v1'
  SHA256 = /\A[0-9a-f]{64}\z/.freeze
  MAX_STAGE_TIMEOUT_SECONDS = 60
  INVENTORY_FILES = %w[summary.json package-roots.jsonl testdir-roots.jsonl typechecker-roots.jsonl].freeze
  CONTROLLED_ENVIRONMENT = %w[
    BASHY_HINTS GOENV GOFLAGS GOMAXPROCS GOMODCACHE GOPROXY GOROOT GOSUMDB
    GOTOOLCHAIN GOWORK LC_ALL PATH TZ
  ].freeze

  def prepare!(root_id:, stage_id:, candidate_manifest:, candidate_manifest_sha256:,
               launcher:, payload:, sdk_identity:, sdk_identity_sha256:, bin_go:,
               inventory:, runners:, module_context:, module_context_sha256:,
               module_files:, go_mod:, go_sum:, importcfg_receipt:, importcfg_receipt_sha256:,
               timeout_seconds:, environment:)
    require_id!(root_id, 'root'); require_id!(stage_id, 'stage')
    require_digest!(candidate_manifest_sha256, 'candidate manifest')
    require_digest!(sdk_identity_sha256, 'SDK identity')
    require_digest!(module_context_sha256, 'module context')
    require_digest!(importcfg_receipt_sha256, 'importcfg receipt')
    require_timeout!(timeout_seconds)
    environment = controlled_environment!(environment)

    candidate_record = exact_file!(candidate_manifest, candidate_manifest_sha256, 'candidate manifest')
    candidate = json_file!(candidate_record, 'candidate manifest')
    launcher_record = exact_file!(launcher, candidate.fetch('launcher_sha256'), 'candidate launcher')
    payload_record = exact_file!(payload, candidate.fetch('payload_sha256'), 'candidate payload')

    sdk_record = exact_file!(sdk_identity, sdk_identity_sha256, 'SDK identity')
    sdk = json_file!(sdk_record, 'SDK identity')
    expected_go = sdk.fetch('go')
    go_path = File.join(sdk.fetch('root'), 'bin/go')
    raise Corpus::ContractError, 'SDK bin/go path differs' unless same_path!(bin_go, go_path)
    go_record = exact_file!(bin_go, expected_go.fetch('sha256'), 'SDK bin/go')
    if expected_go.key?('bytes') && expected_go.fetch('bytes') != go_record.fetch('bytes')
      raise Corpus::ContractError, 'SDK bin/go size differs'
    end
    source_archive = manifest_file!(sdk.fetch('source_archive'), 'SDK source archive')
    distribution_archive = manifest_file!(sdk.fetch('distribution_archive'), 'SDK distribution archive')
    sdk_version = "go version #{sdk.fetch('release')} #{sdk.fetch('goos')}/#{sdk.fetch('goarch')}"

    inventory_records = named_files!(inventory, 'inventory', required: INVENTORY_FILES)
    runner_records = named_files!(runners, 'runner', nonempty: true)

    module_record = exact_file!(module_context, module_context_sha256, 'module context')
    authenticated_module = GoFullModuleContext.load(
      module_record.fetch('path'), candidate_path: candidate_record.fetch('path'),
      sdk_path: sdk_record.fetch('path'), bashy: launcher_record.fetch('path'),
      expected_sha256: module_context_sha256
    )
    module_files_record = exact_file!(module_files, nil, 'module-files argument')
    proof = authenticated_module.fetch('proof')
    assert_record_identity!(proof.fetch('module_files_argument'), module_files_record, 'module-files argument')
    module_values = authenticated_module.fetch('module_files')
    raise Corpus::ContractError, 'module-files argument differs' unless json_file!(module_files_record, 'module-files argument') == module_values
    mod_record = exact_file!(go_mod, Digest::SHA256.hexdigest(module_values.fetch('go.mod')), 'go.mod')
    sum_record = exact_file!(go_sum, Digest::SHA256.hexdigest(module_values.fetch('go.sum')), 'go.sum')
    manifest = json_file!(module_record, 'module context')
    assert_record_identity!(manifest.fetch('module_files').fetch('go.mod'), mod_record, 'go.mod')
    assert_record_identity!(manifest.fetch('module_files').fetch('go.sum'), sum_record, 'go.sum')

    import_record = exact_file!(importcfg_receipt, importcfg_receipt_sha256, 'importcfg receipt')
    importcfg = json_file!(import_record, 'importcfg receipt')
    Corpus.authenticate_import_configuration!(importcfg, tool: go_record)

    receipt = {
      'schema' => SCHEMA, 'root_id' => root_id, 'stage_id' => stage_id,
      'candidate' => { 'manifest' => candidate_record, 'launcher' => launcher_record, 'payload' => payload_record },
      'sdk' => { 'identity_manifest' => sdk_record, 'identity' => sdk_version, 'bin_go' => go_record,
                 'source_archive' => source_archive, 'distribution_archive' => distribution_archive },
      'inventory' => collection(inventory_records), 'runners' => collection(runner_records),
      'module' => { 'context' => module_record, 'module_files' => module_files_record,
                    'go.mod' => mod_record, 'go.sum' => sum_record },
      'importcfg' => { 'receipt' => import_record, 'configuration' => importcfg.slice('path', 'sha256', 'bytes'),
                       'packages' => importcfg.fetch('packages') },
      'timeout_seconds' => timeout_seconds, 'environment' => environment
    }
    receipt.merge('identity_sha256' => identity_sha256(receipt))
  rescue KeyError, TypeError, JSON::ParserError, SystemCallError => error
    raise Corpus::ContractError, "malformed execution identity: #{error.message}"
  end

  def persist!(path, receipt)
    validate!(receipt)
    target = File.expand_path(path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, Corpus.canonical(receipt) + "\n", mode: 'wx')
    File.chmod(0o444, target)
    Corpus.file_record(target)
  rescue Errno::EEXIST
    raise Corpus::ContractError, "execution identity receipt already exists: #{path}"
  end

  # Fresh-process entry point. expected_sha256 must come from the parent
  # lineage/checkpoint, never from the receipt itself.
  def load!(path, expected_sha256:)
    record = exact_file!(path, expected_sha256, 'execution identity receipt')
    receipt = json_file!(record, 'execution identity receipt')
    validate!(receipt)
  end

  # Integration guard: no product verdict is returned until the persisted
  # identity has been independently re-authenticated.
  def authenticate_verdict!(path, expected_sha256:, root_id:, stage_id:, verdict:)
    receipt = load!(path, expected_sha256: expected_sha256)
    raise Corpus::ContractError, 'execution identity root/stage differs' unless receipt['root_id'] == root_id && receipt['stage_id'] == stage_id
    raise Corpus::ContractError, 'unknown product verdict' unless %w[PASS FAIL UPSTREAM_SKIP].include?(verdict)
    verdict
  end

  # Explicit pre-spawn guard for integrators that retain the prepared object in
  # memory before the receipt is persisted by the lineage owner.
  def authorize_launch!(receipt, root_id:, stage_id:, timeout_seconds:, environment:)
    validate!(receipt)
    unless receipt['root_id'] == root_id && receipt['stage_id'] == stage_id &&
           receipt['timeout_seconds'] == timeout_seconds && receipt['environment'] == controlled_environment!(environment)
      raise Corpus::ContractError, 'launch identity differs from prepared execution identity'
    end
    receipt.fetch('identity_sha256')
  end

  def validate!(receipt)
    raise Corpus::ContractError, 'unknown execution identity schema' unless receipt.is_a?(Hash) && receipt['schema'] == SCHEMA
    require_id!(receipt.fetch('root_id'), 'root'); require_id!(receipt.fetch('stage_id'), 'stage')
    sealed = receipt.reject { |key, _| key == 'identity_sha256' }
    raise Corpus::ContractError, 'execution identity seal differs' unless receipt['identity_sha256'] == identity_sha256(sealed)
    require_timeout!(receipt.fetch('timeout_seconds'))
    controlled_environment!(receipt.fetch('environment'))

    candidate = receipt.fetch('candidate')
    raise Corpus::ContractError, 'candidate identity fields differ' unless candidate.keys.sort == %w[launcher manifest payload]
    candidate.each_value { |record| validate_record!(record) }
    candidate_manifest = json_file!(candidate.fetch('manifest'), 'candidate manifest')
    assert_digest!(candidate.fetch('launcher'), candidate_manifest.fetch('launcher_sha256'), 'candidate launcher')
    assert_digest!(candidate.fetch('payload'), candidate_manifest.fetch('payload_sha256'), 'candidate payload')

    sdk = receipt.fetch('sdk')
    raise Corpus::ContractError, 'SDK identity fields differ' unless sdk.keys.sort == %w[bin_go distribution_archive identity identity_manifest source_archive]
    sdk.values_at('identity_manifest', 'bin_go', 'source_archive', 'distribution_archive').each { |record| validate_record!(record) }
    sdk_manifest = json_file!(sdk.fetch('identity_manifest'), 'SDK identity')
    expected_identity = "go version #{sdk_manifest.fetch('release')} #{sdk_manifest.fetch('goos')}/#{sdk_manifest.fetch('goarch')}"
    raise Corpus::ContractError, 'SDK identity string differs' unless sdk.fetch('identity') == expected_identity
    raise Corpus::ContractError, 'SDK bin/go path differs' unless same_path!(sdk.fetch('bin_go').fetch('path'), File.join(sdk_manifest.fetch('root'), 'bin/go'))
    assert_digest!(sdk.fetch('bin_go'), sdk_manifest.fetch('go').fetch('sha256'), 'SDK bin/go')
    %w[source_archive distribution_archive].each do |key|
      assert_record_identity!(sdk_manifest.fetch(key), sdk.fetch(key), "SDK #{key}")
    end

    validate_collection!(receipt.fetch('inventory'), 'inventory', required: INVENTORY_FILES)
    validate_collection!(receipt.fetch('runners'), 'runner', nonempty: true)

    mod = receipt.fetch('module')
    raise Corpus::ContractError, 'module identity fields differ' unless mod.keys.sort == %w[context go.mod go.sum module_files]
    mod.each_value { |record| validate_record!(record) }
    authenticated = GoFullModuleContext.load(
      mod.fetch('context').fetch('path'), candidate_path: candidate.fetch('manifest').fetch('path'),
      sdk_path: sdk.fetch('identity_manifest').fetch('path'), bashy: candidate.fetch('launcher').fetch('path'),
      expected_sha256: mod.fetch('context').fetch('sha256')
    )
    assert_record_identity!(authenticated.fetch('proof').fetch('module_files_argument'), mod.fetch('module_files'), 'module-files argument')
    values = authenticated.fetch('module_files')
    raise Corpus::ContractError, 'module-files argument differs' unless json_file!(mod.fetch('module_files'), 'module-files argument') == values
    assert_digest!(mod.fetch('go.mod'), Digest::SHA256.hexdigest(values.fetch('go.mod')), 'go.mod')
    assert_digest!(mod.fetch('go.sum'), Digest::SHA256.hexdigest(values.fetch('go.sum')), 'go.sum')

    import = receipt.fetch('importcfg'); validate_record!(import.fetch('receipt'))
    importcfg = json_file!(import.fetch('receipt'), 'importcfg receipt')
    Corpus.authenticate_import_configuration!(importcfg, tool: sdk.fetch('bin_go'))
    raise Corpus::ContractError, 'importcfg configuration differs' unless import.fetch('configuration') == importcfg.slice('path', 'sha256', 'bytes')
    raise Corpus::ContractError, 'importcfg archives differ' unless import.fetch('packages') == importcfg.fetch('packages')
    receipt
  rescue KeyError, TypeError, JSON::ParserError, SystemCallError => error
    raise Corpus::ContractError, "malformed execution identity: #{error.message}"
  end

  def identity_sha256(value)
    Digest::SHA256.hexdigest(Corpus.canonical(value))
  end

  def collection(records)
    { 'files' => records, 'count' => records.length, 'sha256' => identity_sha256(records) }
  end

  def named_files!(paths, label, required: nil, nonempty: false)
    raise Corpus::ContractError, "#{label} file map required" unless paths.is_a?(Hash)
    names = paths.keys
    raise Corpus::ContractError, "#{label} names must be unique strings" unless names.all? { |name| name.is_a?(String) && !name.empty? }
    raise Corpus::ContractError, "#{label} file set differs" if required && names.sort != required.sort
    raise Corpus::ContractError, "#{label} file set is empty" if nonempty && names.empty?
    names.sort.to_h do |name|
      expected = paths.fetch(name)
      raise Corpus::ContractError, "#{label} #{name} requires an expected path/digest/size record" unless expected.is_a?(Hash)
      record = exact_file!(expected.fetch('path'), expected.fetch('sha256'), "#{label} #{name}")
      assert_record_identity!(expected, record, "#{label} #{name}")
      [name, record]
    end
  end

  def validate_collection!(value, label, required: nil, nonempty: false)
    records = value.fetch('files')
    raise Corpus::ContractError, "#{label} file map required" unless records.is_a?(Hash)
    raise Corpus::ContractError, "#{label} file set differs" if required && records.keys.sort != required.sort
    raise Corpus::ContractError, "#{label} file set is empty" if nonempty && records.empty?
    records.each_value { |record| validate_record!(record) }
    raise Corpus::ContractError, "#{label} count differs" unless value.fetch('count') == records.length
    raise Corpus::ContractError, "#{label} collection digest differs" unless value.fetch('sha256') == identity_sha256(records)
  end

  def exact_file!(path, expected_sha256, label)
    path = File.expand_path(path)
    raise Corpus::ContractError, "#{label} is a symlink" if File.symlink?(path)
    record = Corpus.file_record(path)
    assert_digest!(record, expected_sha256, label) if expected_sha256
    record
  end


  def manifest_file!(record, label)
    actual = exact_file!(record.fetch('path'), record.fetch('sha256'), label)
    if record.key?('bytes') && record.fetch('bytes') != actual.fetch('bytes')
      raise Corpus::ContractError, "#{label} size differs"
    end
    actual
  end

  def validate_record!(record)
    raise Corpus::ContractError, 'file record has extra/missing fields' unless record.is_a?(Hash) && record.keys.sort == %w[bytes path sha256]
    require_digest!(record.fetch('sha256'), 'file')
    raise Corpus::ContractError, 'file size is invalid' unless record.fetch('bytes').is_a?(Integer) && record.fetch('bytes') >= 0
    raise Corpus::ContractError, "file path is not absolute: #{record.fetch('path')}" unless record.fetch('path') == File.expand_path(record.fetch('path'))
    Corpus::Validation.file!(record)
  end

  def assert_record_identity!(expected, actual, label)
    %w[path sha256 bytes].each do |key|
      raise Corpus::ContractError, "#{label} #{key} differs" unless expected.fetch(key) == actual.fetch(key)
    end
  end

  def assert_digest!(record, expected, label)
    require_digest!(expected, label)
    raise Corpus::ContractError, "#{label} digest differs" unless record.fetch('sha256') == expected
  end

  def json_file!(record, label)
    JSON.parse(File.binread(record.fetch('path')))
  rescue JSON::ParserError => error
    raise Corpus::ContractError, "invalid #{label} JSON: #{error.message}"
  end

  def same_path!(one, other)
    File.realpath(one) == File.realpath(other)
  rescue SystemCallError
    false
  end

  def controlled_environment!(environment)
    raise Corpus::ContractError, 'controlled environment must be a string map' unless environment.is_a?(Hash) && environment.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
    raise Corpus::ContractError, 'controlled environment keys differ' unless environment.keys.sort == CONTROLLED_ENVIRONMENT
    raise Corpus::ContractError, 'controlled environment permits non-local toolchain' unless environment['GOTOOLCHAIN'] == 'local'
    raise Corpus::ContractError, 'controlled environment permits network module resolution' unless environment['GOPROXY'] == 'off' && environment['GOSUMDB'] == 'off'
    raise Corpus::ContractError, 'controlled environment permits ambient Go configuration' unless environment['GOENV'] == 'off' && environment['GOWORK'] == 'off'
    environment.sort.to_h
  end

  def require_timeout!(value)
    unless value.is_a?(Numeric) && value.positive? && value <= MAX_STAGE_TIMEOUT_SECONDS
      raise Corpus::ContractError, "stage timeout must be within 1..#{MAX_STAGE_TIMEOUT_SECONDS} seconds"
    end
  end

  def require_digest!(value, label)
    raise Corpus::ContractError, "#{label} SHA-256 required" unless value.is_a?(String) && value.match?(SHA256)
  end

  def require_id!(value, label)
    raise Corpus::ContractError, "#{label} identity required" unless value.is_a?(String) && !value.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.length == 3 && ARGV.first == 'verify'
    warn 'usage: execution_identity.rb verify RECEIPT EXPECTED_SHA256'
    exit 64
  end
  GoFullExecutionIdentity.load!(ARGV[1], expected_sha256: ARGV[2])
  puts 'authenticated'
end
