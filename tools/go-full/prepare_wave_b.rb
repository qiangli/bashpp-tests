# frozen_string_literal: true
# Sprint: #148; Story: #32; Story-ID: 28a477b38fed

require 'fileutils'
require 'json'
require 'optparse'
require_relative 'product'

# Deterministically prepares the reviewed packet projection and the exact
# per-stage execution identities consumed by the Wave B product path. It does
# not execute a selected root or create its evidence directory.
module GoFullWaveBPrepare
  module_function

  def runner_paths
    [File.join(__dir__, 'product.rb'), File.join(__dir__, 'packet_manifest.rb'), File.join(__dir__, 'router.rb'),
     File.join(__dir__, 'stage_resolver.rb'), File.expand_path('../corpus/executor.rb', __dir__),
     File.expand_path('../corpus/process_lineage.rb', __dir__)]
  end

  def stage_plan(packet, root_id)
    raise Corpus::ContractError, 'unsupported Wave B packet' unless %w[148.4 148.6].include?(packet)
    raise Corpus::ContractError, 'Wave B root ID is required' unless root_id.is_a?(String) && !root_id.empty?
    executions = packet == '148.4' ? 3.times.map { |index| "#{root_id}:ordered-#{index + 1}" } : [root_id]
    plan = executions.flat_map do |execution_id|
      { 'baseline' => %w[build run], 'interpreted' => %w[run], 'compiled' => %w[transpile build run] }.flat_map do |mode, stages|
        stages.map { |stage| [execution_id, mode, stage, "#{execution_id}/#{mode}/#{stage}"] }
      end
    end
    unless plan.map(&:last) == GoFullProduct.anchor_stage_ids(packet, root_id)
      raise Corpus::ContractError, 'preflight and product stage plans differ'
    end
    plan
  end

  def execute(options)
    packet = options.fetch(:packet)
    expected_manifest = GoFullProduct::PACKET_MANIFEST_SHA256.fetch(packet)
    inventory_dir = File.expand_path(options.fetch(:inventory))
    roots = %w[testdir-roots.jsonl typechecker-roots.jsonl package-roots.jsonl].flat_map do |name|
      axis = name.delete_suffix('-roots.jsonl')
      File.foreach(File.join(inventory_dir, name)).map { |line| JSON.parse(line).merge('axis' => axis) }
    end
    catalog = GoFullPacketManifest.authenticate_index(path: options.fetch(:packet_index),
      expected_sha256: options.fetch(:packet_index_sha256), causal_partition_path: options.fetch(:causal_partition))
    selection = GoFullPacketManifest.select(catalog, packet, roots, expected_manifest_sha256: expected_manifest)
    raise Corpus::ContractError, 'Wave B preparation requires exactly one root' unless selection.fetch('ids').length == 1
    root_id = selection.fetch('ids').first

    candidate = JSON.parse(File.binread(options.fetch(:candidate)))
    sdk_identity = JSON.parse(File.binread(options.fetch(:sdk_identity)))
    setup = GoFullProduct.execution_setup(options, File.expand_path(options.fetch(:evidence)), candidate, sdk_identity)
    executor = setup.fetch(:executor)
    module_context = setup.fetch(:module_context)
    importcfg = executor.send(:import_configuration)
    manifest = JSON.parse(File.binread(options.fetch(:module_context)))
    identity_dir = File.expand_path(options.fetch(:identity_directory))
    raise Corpus::ContractError, 'projection already exists' if File.exist?(File.expand_path(options.fetch(:projection)))
    raise Corpus::ContractError, 'identity directory already exists' if File.exist?(identity_dir)
    FileUtils.mkdir_p(identity_dir)

    inventory = %w[summary.json package-roots.jsonl testdir-roots.jsonl typechecker-roots.jsonl].to_h do |name|
      path = File.join(inventory_dir, name); [name, Corpus.file_record(path)]
    end
    runners = runner_paths.to_h { |path| [File.basename(path), Corpus.file_record(path)] }
    raise Corpus::ContractError, 'runner basenames collide' unless runners.length == runner_paths.length
    base = setup.dig(:runtime, 'base_environment')
    cache = setup.dig(:runtime, 'cache_path')
    entries = {}
    stage_plan(packet, root_id).each do |execution_id, mode, stage, stage_id|
      directory = File.join(File.expand_path(options.fetch(:evidence)), 'executions', execution_id, mode)
      environment = base.merge('HOME' => File.join(directory, 'home'), 'TMPDIR' => File.join(directory, 'tmp'), 'GOCACHE' => cache)
      environment = environment.merge('PATH' => File.join(directory, 'empty-path')) if stage == 'run'
      controlled = environment.slice(*GoFullExecutionIdentity::CONTROLLED_ENVIRONMENT)
      receipt = GoFullExecutionIdentity.prepare!(root_id: root_id, stage_id: stage_id,
        candidate_manifest: options.fetch(:candidate), candidate_manifest_sha256: Corpus.digest(options.fetch(:candidate)),
        launcher: options.fetch(:bashy), payload: options.fetch(:bashy) + '.real',
        sdk_identity: options.fetch(:sdk_identity), sdk_identity_sha256: Corpus.digest(options.fetch(:sdk_identity)),
        bin_go: File.join(sdk_identity.fetch('root'), 'bin/go'), inventory: inventory, runners: runners,
        module_context: options.fetch(:module_context), module_context_sha256: Corpus.digest(options.fetch(:module_context)),
        module_files: manifest.fetch('module_files_argument').fetch('path'),
        go_mod: manifest.dig('module_files', 'go.mod', 'path'), go_sum: manifest.dig('module_files', 'go.sum', 'path'),
        importcfg_receipt: File.join(File.dirname(importcfg.fetch('path')), Corpus::IMPORTCFG_RECEIPT),
        importcfg_receipt_sha256: Corpus.digest(File.join(File.dirname(importcfg.fetch('path')), Corpus::IMPORTCFG_RECEIPT)),
        timeout_seconds: options.fetch(:timeout), environment: controlled)
      path = File.join(identity_dir, Digest::SHA256.hexdigest(stage_id) + '.json')
      entries[stage_id] = GoFullExecutionIdentity.persist!(path, receipt).slice('path', 'sha256')
    end
    index_path = File.join(identity_dir, 'index.json')
    File.write(index_path, Corpus.canonical('schema' => 'go-full-execution-identity-index/v1',
      'root_id' => root_id, 'entries' => entries) + "\n", mode: 'wx')

    inventory_paths = inventory.values.map { |record| record.fetch('path') }
    projection = GoFullPacketManifest.projection(selection: selection, attempt: File.basename(options.fetch(:evidence)),
      evidence: options.fetch(:evidence), inventory_paths: inventory_paths, runner_paths: runner_paths,
      candidate_path: options.fetch(:candidate))
    projection_path = File.expand_path(options.fetch(:projection))
    FileUtils.mkdir_p(File.dirname(projection_path))
    File.write(projection_path, Corpus.canonical(projection) + "\n", mode: 'wx')
    puts Corpus.canonical('packet' => packet, 'root_id' => root_id,
      'projection' => Corpus.file_record(projection_path), 'execution_identity_index' => Corpus.file_record(index_path))
  rescue KeyError => error
    raise Corpus::ContractError, "incomplete Wave B preparation: #{error.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { timeout: 60 }
  OptionParser.new do |parser|
    %i[bashy candidate sdk_identity inventory module_context packet_index causal_partition evidence projection identity_directory].each do |key|
      parser.on("--#{key.to_s.tr('_', '-')} PATH") { |value| options[key] = File.expand_path(value) }
    end
    parser.on('--packet NAME') { |value| options[:packet] = value }
    parser.on('--packet-index-sha256 SHA256') { |value| options[:packet_index_sha256] = value }
    parser.on('--module-context-sha256 SHA256') { |value| options[:module_context_sha256] = value }
    parser.on('--cache-root PATH') { |value| options[:cache_root] = File.expand_path(value) }
    parser.on('--timeout N', Integer) { |value| options[:timeout] = value }
  end.parse!
  begin
    GoFullWaveBPrepare.execute(options)
  rescue Corpus::ContractError, JSON::ParserError, SystemCallError => error
    warn "FATAL: #{error.message}"
    exit 2
  end
end
