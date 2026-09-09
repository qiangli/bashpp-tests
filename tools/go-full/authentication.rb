# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
require 'find'
require_relative '../corpus/executor'

module GoFullAuthentication
  module_function
  REVIEWED_RELOCATION_SHA256 = '3d061c0322b546005acf7ce1878aee4e4382a7dd2820feeb4c570fa267a23c2e'

  def identity_without_locations(identity)
    copy = Marshal.load(Marshal.dump(identity))
    copy.delete('root')
    %w[source_archive distribution_archive].each { |key| copy.fetch(key).delete('path') }
    copy
  end

  def derive_identity(identity)
    root = identity.fetch('root')
    source_cache = File.dirname(identity.fetch('source_archive').fetch('path'))
    cache = File.dirname(identity.fetch('distribution_archive').fetch('path'))
    # sdk.py can materialize/download absent inputs. Reauthentication must never
    # reach those branches, especially through obsolete native-evidence paths.
    [root, File.join(source_cache, 'go'), cache].each do |path|
      raise Corpus::ContractError, "existing SDK directory required: #{path}" unless File.directory?(path) && !File.symlink?(path)
    end
    %w[source_archive distribution_archive].each do |key|
      record = identity.fetch(key)
      raise Corpus::ContractError, 'SDK archive symlink rejected' if File.symlink?(record.fetch('path'))
      Corpus.authenticate_file(record.fetch('path'), record.fetch('sha256'))
    end
    raise Corpus::ContractError, 'SDK binary symlink rejected' if File.symlink?(File.join(root, 'bin/go'))
    Corpus.authenticate_file(File.join(root, 'bin/go'), identity.fetch('go').fetch('sha256'))
    output, error, status = Open3.capture3('python3', File.join(__dir__, 'sdk.py'), '--source-cache', source_cache,
                                         '--cache', cache, '--output', root, '--verify-existing',
                                         '--goos', identity.fetch('goos'), '--goarch', identity.fetch('goarch'))
    raise Corpus::ContractError, "SDK reauthentication failed: #{error}" unless status.success?
    JSON.parse(output)
  end

  def relocation!(path, expected_sha256)
    raise Corpus::ContractError, 'reviewed relocation digest required' unless expected_sha256&.match?(/\A[0-9a-f]{64}\z/)
    Corpus.authenticate_file(path, expected_sha256)
    manifest = JSON.parse(File.read(path))
    raise Corpus::ContractError, 'incomplete/untrusted relocation' unless manifest['schema'] == 'sprint118-cache-relocation/v1' && manifest['state'] == 'complete' && manifest['original_identity_bytes_preserved'] == true && manifest['raw_evidence_rewritten'] == false
    moves = manifest.fetch('moves')
    raise Corpus::ContractError, 'duplicate relocation endpoints' unless moves.map { |m| m.fetch('old') }.uniq.length == moves.length && moves.map { |m| m.fetch('new') }.uniq.length == moves.length
    moves.each do |move|
      entries = move.fetch('entries')
      raise Corpus::ContractError, 'relocation entry manifest differs' unless Digest::SHA256.hexdigest(JSON.generate(Corpus.sort(entries), ascii_only: true)) == move.fetch('entry_manifest_sha256') && move['verified_after'] == true
      names = entries.map { |entry| entry.fetch('path') }
      raise Corpus::ContractError, 'duplicate relocation entry' unless names.uniq == names
      destination = move.fetch('new')
      # Inspect only new destinations; old paths are strings, never opened.
      actual = if File.directory?(destination) && !File.symlink?(destination)
                 Find.find(destination).reject { |p| p == destination }.map { |p| p.delete_prefix(destination + '/') }.sort
               else
                 ['.']
               end
      raise Corpus::ContractError, 'relocated tree membership differs' unless actual == names.sort
      files = 0; bytes = 0
      entries.each do |entry|
        relative = entry.fetch('path')
        target = relative == '.' ? destination : Corpus.safe_path(destination, relative)
        raise Corpus::ContractError, "relocated symlink: #{target}" if File.symlink?(target)
        raise Corpus::ContractError, "relocated mode differs: #{target}" unless (File.stat(target).mode & 0o777) == entry.fetch('mode')
        case entry.fetch('kind')
        when 'directory'
          raise Corpus::ContractError, "relocated directory missing: #{target}" unless File.directory?(target)
        when 'file'
          raise Corpus::ContractError, "relocated bytes differ: #{target}" unless Corpus.digest(target) == entry.fetch('sha256') && File.size(target) == entry.fetch('bytes')
          files += 1; bytes += entry.fetch('bytes')
        else raise Corpus::ContractError, 'unknown relocation entry kind'
        end
      end
      raise Corpus::ContractError, 'relocation denominator differs' unless files == move.fetch('files') && bytes == move.fetch('bytes')
    end
    manifest
  end

  def verify_sdk_identity(native, current, relocation_file = nil, relocation_sha256: REVIEWED_RELOCATION_SHA256)
    raise Corpus::ContractError, 'SDK non-location identity differs' unless identity_without_locations(native) == identity_without_locations(current)
    paths = [[native.fetch('root'), current.fetch('root')]] + %w[source_archive distribution_archive].map { |key| [native.fetch(key).fetch('path'), current.fetch(key).fetch('path')] }
    if paths.any? { |old, new| old != new }
      raise Corpus::ContractError, 'SDK relocation mapping required' unless relocation_file
      relocation = relocation!(relocation_file, relocation_sha256)
      paths.each do |old, new|
        next if old == new
        matches = relocation.fetch('moves').select do |move|
          prefix = move.fetch('old')
          (old == prefix || old.start_with?(prefix + '/')) && new == move.fetch('new') + old.delete_prefix(prefix)
        end
        raise Corpus::ContractError, "SDK path lacks one exact relocation: #{old}" unless matches.length == 1
      end
    end
    # Re-derive only the current identity, then compare the entire object. This
    # rejects claimed digests/extra fields rather than comparing two new claims.
    actual = derive_identity(current)
    raise Corpus::ContractError, 'claimed SDK identity differs from authenticated current bytes' unless actual == current
    { 'schema' => 'go-full-sdk-authentication/v1', 'native_identity_sha256' => Digest::SHA256.hexdigest(Corpus.canonical(native)),
      'current_identity_sha256' => Digest::SHA256.hexdigest(Corpus.canonical(actual)),
      'relocation' => relocation_file ? Corpus.file_record(relocation_file) : nil,
      'reauthenticator' => Corpus.file_record(File.join(__dir__, 'sdk.py')), 'current' => actual }
  rescue KeyError, TypeError, JSON::ParserError, SystemCallError => error
    raise Corpus::ContractError, "malformed SDK authentication: #{error.message}"
  end
end
