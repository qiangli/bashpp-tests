# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
require_relative '../corpus/validate'
require 'find'

module GoFullModuleContext
  module_function
  REVIEWED_SHA256 = 'a886a3618bcacccbb5df4030ad9e0f58442f3440a75dab3b6e62e6e0a4550dd6'

  def within!(path, root)
    path = File.expand_path(path); root = File.realpath(root)
    raise Corpus::ContractError, 'module input outside declared cache' unless path.start_with?(root + '/')
    Corpus.safe_path(root, path.delete_prefix(root + '/'))
  end

  def tree!(directory, files)
    raise Corpus::ContractError, 'module directory absent/symlink' unless File.directory?(directory) && !File.symlink?(directory)
    expected = files.map { |record| record.fetch('path') }
    raise Corpus::ContractError, 'duplicate module tree input' unless expected.uniq == expected
    actual = []
    Find.find(directory) do |path|
      raise Corpus::ContractError, 'module tree symlink' if File.symlink?(path)
      actual << path.delete_prefix(directory + '/') if File.file?(path)
    end
    raise Corpus::ContractError, 'module tree membership differs' unless actual.sort == expected.sort
    files.each do |record|
      Corpus::Validation.file!(record.merge('path' => Corpus.safe_path(directory, record.fetch('path'))))
    end
  end

  # The reviewed manifest binds both the official download sums and each actual
  # extracted input. Sharing a cache never substitutes an unverified source tree.
  def load(path, candidate_path:, sdk_path:, cache_root: nil, bashy: nil, expected_sha256: REVIEWED_SHA256)
    raise Corpus::ContractError, 'reviewed module context digest required' unless expected_sha256&.match?(/\A[0-9a-f]{64}\z/)
    Corpus.authenticate_file(path, expected_sha256)
    manifest = JSON.parse(File.read(path))
    raise Corpus::ContractError, 'unknown module context schema' unless manifest['schema'] == 'go-full-module-context/v1'
    { 'candidate_manifest' => candidate_path, 'sdk_identity' => sdk_path }.each do |key, actual|
      record = manifest.fetch(key); Corpus::Validation.file!(record)
      raise Corpus::ContractError, key + ' does not bind current input' unless Corpus.digest(actual) == record.fetch('sha256') && File.size(actual) == record.fetch('bytes')
    end
    candidate = JSON.parse(File.read(candidate_path)); sdk = JSON.parse(File.read(sdk_path))
    Corpus::Validation.file!(sdk.fetch('go').merge('path' => File.join(sdk.fetch('root'), 'bin/go')))
    Corpus.authenticate_candidate(bashy, candidate) if bashy
    replacement = manifest.fetch('replacement')
    raise Corpus::ContractError, 'replacement is not frozen candidate sh' unless replacement['module'] == 'mvdan.cc/sh/v3' && candidate.fetch('repositories').any? { |repo| repo['path'] == replacement['path'] && repo['commit'] == replacement['commit'] }
    %w[original_go_mod original_go_sum].each { |key| Corpus::Validation.file!(replacement.fetch(key)) }
    raise Corpus::ContractError, 'replacement module metadata path differs' unless replacement.dig('original_go_mod', 'path') == File.join(replacement.fetch('path'), 'go.mod') && replacement.dig('original_go_sum', 'path') == File.join(replacement.fetch('path'), 'go.sum')
    record = manifest.fetch('module_files_argument'); Corpus::Validation.file!(record)
    modules = JSON.parse(File.read(record.fetch('path')))
    raise Corpus::ContractError, 'scaffold must contain exactly go.mod/go.sum' unless modules.keys.sort == %w[go.mod go.sum] && manifest.fetch('module_files').keys.sort == modules.keys.sort
    manifest.fetch('module_files').each do |name, file|
      Corpus::Validation.file!(file)
      raise Corpus::ContractError, 'declared scaffold bytes differ' unless modules.fetch(name) == File.binread(file.fetch('path'))
    end
    sums = modules.fetch('go.sum').lines.to_h do |line|
      name, version, sum = line.split
      raise Corpus::ContractError, 'invalid scaffold checksum row' unless name && version && sum&.match?(/\Ah1:[A-Za-z0-9+\/=]+\z/)
      [[name, version], sum]
    end
    cache = File.realpath(manifest.fetch('gomodcache'))
    environment = manifest.fetch('environment')
    raise Corpus::ContractError, 'module environment differs from readonly contract' unless environment == { 'GOENV' => 'off', 'GOWORK' => 'off', 'GOFLAGS' => '-mod=readonly -p=2', 'GOMODCACHE' => cache }
    dependencies = manifest.fetch('modules')
    ids = dependencies.map { |row| [row.fetch('module'), row.fetch('version')] }
    raise Corpus::ContractError, 'duplicate module dependency' unless ids.uniq == ids
    dependencies.each do |row|
      name = row.fetch('module'); version = row.fetch('version')
      raise Corpus::ContractError, 'module sums differ from scaffold' unless sums[[name, version]] == row.fetch('sum') && sums[[name, version + '/go.mod']] == row.fetch('gomod_sum')
      directory = within!(row.fetch('directory'), cache)
      %w[archive gomod].each do |key|
        record = row.fetch(key); within!(record.fetch('path'), cache); Corpus::Validation.file!(record)
      end
      tree!(directory, row.fetch('files'))
    end
    manifest.fetch('provisioning_evidence').each_value { |record| Corpus::Validation.file!(record) }
    raise Corpus::ContractError, 'module context permits source edits/delegation' unless manifest['original_program_edits'] == false && manifest['whole_original_native_delegation'] == false
    base = File.expand_path(cache_root || manifest.fetch('cache_root'))
    ancestor = base; suffix = []
    until File.exist?(ancestor)
      suffix.unshift(File.basename(ancestor)); ancestor = File.dirname(ancestor)
    end
    raise Corpus::ContractError, 'build cache ancestor is not directory' unless File.directory?(ancestor)
    base = File.join(File.realpath(ancestor), *suffix)
    # Build cache is disposable output; it cannot overlap immutable inputs.
    protected = [cache, sdk.fetch('root'), File.dirname(sdk.fetch('source_archive').fetch('path'))] + candidate.fetch('repositories').map { |repo| repo.fetch('path') }
    protected.each do |root|
      root = File.expand_path(root)
      raise Corpus::ContractError, 'build cache overlaps authenticated input' if base == root || base.start_with?(root + '/') || root.start_with?(base + '/')
    end
    raise Corpus::ContractError, 'build cache root is a symlink' if File.symlink?(base)
    { 'manifest' => Corpus.file_record(path), 'module_files' => modules, 'environment' => environment,
      'cache_root' => File.join(base, expected_sha256),
      'proof' => { 'schema' => 'go-full-module-authentication/v1', 'manifest' => Corpus.file_record(path),
        'module_files_argument' => manifest.fetch('module_files_argument'), 'candidate_manifest' => manifest.fetch('candidate_manifest'),
        'sdk_identity' => manifest.fetch('sdk_identity'), 'dependency_modules' => dependencies.length,
        'dependency_files' => dependencies.sum { |row| row.fetch('files').length }, 'environment' => environment,
        'cache_root' => base, 'cache_policy' => 'Shared Go build cache keyed by authenticated module manifest, candidate, SDK and exact environment; original and generated inputs remain checked per phase.' } }
  rescue KeyError, TypeError, JSON::ParserError, SystemCallError => error
    raise Corpus::ContractError, 'malformed module context: ' + error.message
  end
end
