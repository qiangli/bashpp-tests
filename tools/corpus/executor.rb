# frozen_string_literal: true
# Sprint: #118; Story: #11; Story-ID: e29305614139
require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'rbconfig'
require_relative 'process_lineage'

module Corpus
  SCHEMA = 'corpus-execution/v1'
  MODES = %w[baseline interpreted compiled].freeze
  class ContractError < StandardError; end
  module_function

  def canonical(value)
    JSON.generate(sort(value))
  end

  def sort(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, sort(value[key])] }
    when Array then value.map { |v| sort(v) }
    else value
    end
  end

  def digest(path)
    raise ContractError, "not a regular file: #{path}" unless File.file?(path) && !File.symlink?(path)
    Digest::SHA256.file(path).hexdigest
  end

  def file_record(path)
    { 'path' => File.expand_path(path), 'sha256' => digest(path), 'bytes' => File.size(path) }
  end

  def safe_path(root, relative)
    raise ContractError, "unsafe relative path #{relative.inspect}" unless relative.is_a?(String) && !relative.empty? && !relative.start_with?('/') && relative.split('/', -1).none? { |s| ['', '.', '..'].include?(s) }
    path = File.expand_path(relative, root)
    cursor = root
    relative.split('/', -1).each do |part|
      cursor = File.join(cursor, part)
      raise ContractError, "symlink input #{relative}" if File.symlink?(cursor)
    end
    path
  end

  def package_argument(value)
    return nil if value.nil?
    return '.' if value == '.' || value == './'
    relative = value.delete_prefix('./')
    safe_path('/unused', relative)
    './' + relative
  end

  def native_binary?(path)
    return false unless File.file?(path) && !File.symlink?(path) && File.executable?(path)
    File.open(path, 'rb') do |io|
      header = io.read(64).to_s
      return true if header.start_with?("\x7fELF".b) && [1, 2].include?(header.getbyte(4)) && header.bytesize >= 52
      magic = header.byteslice(0, 4).to_s.unpack('H*').first
      return true if %w[feedface cefaedfe feedfacf cffaedfe cafebabe bebafeca].include?(magic) && header.bytesize == 64
      if header.start_with?('MZ') && header.bytesize == 64
        io.seek(header.byteslice(60, 4).unpack('V').first)
        return io.read(4) == "PE\x00\x00".b
      end
      false
    end
  end

  ARCHIVE_HEADER = "!<arch>\n".b.freeze
  ARCHIVE_ENTRY_BYTES = 60
  GO_OBJECT_HEADER = 'go object '.b.freeze
  GO_OBJECT_MEMBERS = %w[__.PKGDEF _go_.o].freeze

  # A compile-only obligation retains a real Go object archive, never merely a
  # nonempty file. The ar container must parse exactly to its own length, carry
  # the package export member and the compiled object member, and the object
  # member must hold the toolchain's own goobj magic.
  def go_object_archive?(path)
    return false unless File.file?(path) && !File.symlink?(path)
    bytes = File.binread(path)
    return false unless bytes.start_with?(ARCHIVE_HEADER)
    members = {}
    offset = ARCHIVE_HEADER.bytesize
    while offset < bytes.bytesize
      header = bytes.byteslice(offset, ARCHIVE_ENTRY_BYTES)
      return false unless header && header.bytesize == ARCHIVE_ENTRY_BYTES && header.byteslice(58, 2) == "`\n".b
      size = header.byteslice(48, 10).to_s.strip
      return false unless size.match?(/\A\d+\z/)
      size = Integer(size, 10)
      body = bytes.byteslice(offset + ARCHIVE_ENTRY_BYTES, size)
      return false unless body && body.bytesize == size
      name = header.byteslice(0, 16).to_s.rstrip
      return false if name.empty? || members.key?(name)
      members[name] = body
      offset += ARCHIVE_ENTRY_BYTES + size + (size.odd? ? 1 : 0)
    end
    return false unless offset == bytes.bytesize
    return false unless GO_OBJECT_MEMBERS.all? { |name| members[name]&.start_with?(GO_OBJECT_HEADER) }
    members.fetch('_go_.o').match?(/\x00go\d+ld/n)
  rescue SystemCallError
    false
  end

  def valid_source_map?(mapping, generated_record, source_records = {})
    return false unless mapping.is_a?(Hash) && mapping['schema_version'] == 'bashy-transpile-map-v1'
    return false unless mapping['origin'].is_a?(String) && !mapping['origin'].empty?

    return false unless generated_record.is_a?(Hash) && source_records.is_a?(Hash) && !source_records.empty?
    actual_generated = file_record(generated_record.fetch('path'))
    return false unless %w[sha256 bytes].all? { |key| generated_record[key] == actual_generated[key] }
    return false unless mapping['go_digest'] == 'sha256:' + actual_generated['sha256']
    return false unless mapping['mappings'].is_a?(Array)
    return false unless mapping['source_kind'] == 'go' && mapping['front_end'] == 'gosource-v1'
    return false unless mapping['sources'].is_a?(Array)
    generated_bytes = File.binread(generated_record['path'])
    generated_lines = generated_bytes.split("\n", -1)

    # 2. unique exact source-name set
    mapped_sources = mapping['sources']
    return false unless mapped_sources.all? { |src| src.is_a?(Hash) && src['name'].is_a?(String) }
    return false unless mapped_sources.map { |src| src['name'] } == source_records.keys.sort

    source_files_content = {}
    current_base = 0

    mapped_sources.each do |src|
      return false unless src.is_a?(Hash)
      name = src['name']
      rec = source_records[name]
      return false unless rec

      actual_source = file_record(rec.fetch('path'))
      return false unless %w[sha256 bytes].all? { |key| rec[key] == actual_source[key] }
      return false unless src['sha256'] == actual_source['sha256']
      return false unless src['size'] == actual_source['bytes']

      # 3. Base must equal ordered file concatenation actual go source contract
      return false unless src['base'].is_a?(Integer) && src['size'].is_a?(Integer)
      return false unless src['base'] == current_base

      source_files_content[name] = File.binread(rec.fetch('path'))

      current_base += src['size'] + 1
    end

    # Match the lowerer's next-nonempty-line marker contract. Checking every
    # emitted position prevents a nonempty but truncated map from certifying.
    expected_positions = []
    pending_marker = false
    generated_lines.each_with_index do |line, index|
      if line.strip.start_with?('// lower:')
        return false unless line.strip.match?(/\A\/\/ lower:\d+\z/)
        pending_marker = true
      elsif pending_marker && !line.strip.empty?
        expected_positions << [index + 1, line.bytesize - line.sub(/\A[\t ]*/, '').bytesize + 1]
        pending_marker = false
      end
    end
    return false if pending_marker
    return false unless mapping['mappings'].all? { |entry| entry.is_a?(Hash) }
    return false unless mapping['mappings'].map { |entry| entry.values_at('go_line', 'go_col') } == expected_positions

    mapping['mappings'].each do |entry|
      return false unless entry.is_a?(Hash) && %w[go_line go_col source_line source_col].all? { |key| entry[key].is_a?(Integer) && entry[key].positive? }
      return false unless entry['source_offset'].is_a?(Integer) && entry['source_offset'] >= 0 && entry['node'].is_a?(String) && !entry['node'].empty?

      return false unless entry['source_file'].is_a?(String) && entry['source_file_offset'].is_a?(Integer)
      return false unless source_records.key?(entry['source_file'])

      src_meta = mapped_sources.find { |s| s['name'] == entry['source_file'] }

      # 4. source_file_offset + source.base == source_offset
      return false unless entry['source_file_offset'] + src_meta['base'] == entry['source_offset']

      content = source_files_content[entry['source_file']]
      return false unless entry['source_file_offset'] >= 0 && entry['source_file_offset'] <= content.bytesize

      prefix = content.byteslice(0, entry['source_file_offset'])
      expected_source_line = prefix.count("\n") + 1
      last_newline_idx = prefix.rindex("\n")
      line_start_idx = last_newline_idx ? last_newline_idx + 1 : 0
      expected_source_col = entry['source_file_offset'] - line_start_idx + 1

      return false unless entry['source_line'] == expected_source_line
      return false unless entry['source_col'] == expected_source_col

      go_line = entry['go_line']
      return false unless go_line <= generated_lines.length
      gen_line_str = generated_lines[go_line - 1]
      return false unless entry['go_col'] <= gen_line_str.bytesize + 1
    end

    true
  rescue ContractError, StandardError
    false
  end

  def snapshot(root)
    entries = {}
    Find.find(root) do |path|
      next if path == root
      relative = path.delete_prefix(root + '/')
      stat = File.lstat(path)
      entries[relative] = if stat.symlink?
                            { 'kind' => 'symlink', 'target' => File.readlink(path) }
                          elsif stat.file?
                            { 'kind' => 'file', 'sha256' => digest(path), 'bytes' => stat.size }
                          elsif stat.directory?
                            { 'kind' => 'directory' }
                          else
                            { 'kind' => 'special' }
                          end
    end
    entries
  end

  # No shell, no inherited secrets, file-backed streams, bounded process-group lifetime.
  # A surviving descendant is a failure even when its parent exited successfully.
  def capture(argv, cwd:, log_prefix:, env:, timeout:, stdin: File::NULL, lineage: {})
    root_id = lineage.fetch(:root_id, "standalone:#{Digest::SHA256.hexdigest(File.expand_path(log_prefix))[0, 16]}")
    stage_id = lineage.fetch(:stage_id, File.basename(log_prefix))
    ProcessLineage.run(argv, cwd: cwd, env: env, timeout: timeout, stdin: stdin,
                       lineage_path: lineage.fetch(:path, log_prefix + '.lineage.jsonl'),
                       log_prefix: log_prefix, root_id: root_id, stage_id: stage_id,
                       parent_launch_id: lineage[:parent_launch_id],
                       artifact_paths: lineage.fetch(:artifact_paths, {}),
                       artifact_parents: lineage.fetch(:artifact_parents, {}),
                       combined_output: lineage.fetch(:combined_output, false))
  end

  def kill_group(pid)
    Process.kill('KILL', -pid)
  rescue Errno::ESRCH
    nil
  end

  def success?(stage)
    stage && stage['spawned'] && stage['state'] == 'exited' && stage['exit'] == 0 && stage['signal'].nil?
  end

  def authenticate_file(path, expected)
    record = file_record(File.realpath(path))
    raise ContractError, "digest mismatch: #{path}" unless record['sha256'] == expected
    record
  end

  # candidate: launcher_sha256, payload_sha256, frontend_version, build_recipe,
  # repositories: [{path:, commit:}]. Keys are strings, matching JSON manifests.
  def authenticate_candidate(bashy, candidate)
    %w[launcher_sha256 payload_sha256 frontend_version build_recipe repositories].each do |key|
      raise ContractError, "candidate missing #{key}" if candidate[key].nil? || candidate[key].respond_to?(:empty?) && candidate[key].empty?
    end
    launcher = authenticate_file(bashy, candidate.fetch('launcher_sha256'))
    payload = authenticate_file(bashy + '.real', candidate.fetch('payload_sha256'))
    candidate.fetch('repositories').each do |repo|
      revision, status = Open3.capture2('git', '-C', repo.fetch('path'), 'rev-parse', 'HEAD')
      raise ContractError, "candidate revision mismatch: #{repo['path']}" unless status.success? && revision.strip == repo.fetch('commit')
      dirt, status = Open3.capture2('git', '-C', repo.fetch('path'), 'status', '--porcelain', '--untracked-files=all')
      raise ContractError, "candidate repository is dirty: #{repo['path']}" unless status.success? && dirt.empty?
    end
    candidate.merge('launcher' => launcher, 'payload' => payload)
  end

  # Compile-only phases resolve their imports exactly the way the pinned SDK's
  # own testdir harness does: `go list -export` publishes the standard library
  # archives once and the resulting packagefile map is handed to the compiler.
  # Nothing here executes an original program body.
  IMPORTCFG_SCHEMA = 'corpus-importcfg/v2'
  IMPORTCFG_TEMPLATE = '{{if .Export}}packagefile {{.ImportPath}}={{.Export}}{{end}}'
  IMPORTCFG_RECIPE = %w[list -export -f].freeze
  IMPORTCFG_NAME = 'importcfg-std'
  IMPORTCFG_RECEIPT = 'importcfg-std.receipt.json'
  IMPORTCFG_HOME = 'importcfg-home'
  IMPORTCFG_TMP = 'importcfg-tmp'
  IMPORTCFG_LOGS = 'importcfg-logs'
  IMPORTCFG_LOG = 'list-export'

  # The retained preparation stdout is the only source of package rows:
  # preparation derives its package set from it and writes the configuration
  # from that same set. Parsing lives here so authentication re-derives the rows
  # exactly the way preparation did.
  def importcfg_rows(bytes)
    bytes.to_s.lines.map(&:chomp).reject(&:empty?).map do |line|
      name, separator, archive = line.delete_prefix('packagefile ').partition('=')
      raise ContractError, "malformed importcfg row: #{line}" unless line.start_with?('packagefile ') && !name.empty? && !separator.empty? && !archive.empty?
      [name, File.expand_path(archive)]
    end
  end

  def importcfg_row(name, archive)
    "packagefile #{name}=#{archive}"
  end

  # The pinned toolchain lives at <GOROOT>/bin/go, so the SDK root is derived
  # from the binary whose digest provenance already authenticates rather than
  # from anything the receipt claims about itself.
  def sdk_root(tool_path)
    File.dirname(File.dirname(tool_path))
  end

  def sdk_platform(identity)
    fields = identity.to_s.split(' ')
    unless fields.length == 4 && fields[0, 2] == %w[go version] && fields[3].match?(%r{\A[^/\s]+/[^/\s]+\z})
      raise ContractError, "unusable SDK identity: #{identity.inspect}"
    end
    fields[3].split('/')
  end

  def same_path?(one, other)
    return false unless one.is_a?(String) && other.is_a?(String)
    return true if File.expand_path(one) == File.expand_path(other)
    File.realpath(one) == File.realpath(other)
  rescue SystemCallError
    false
  end

  # The preparation environment is a pure function of the known context, so the
  # captured environment must equal this map key for key. GOENV/GOWORK are
  # disabled the way the upstream testdir harness does it, GOOS/GOARCH are bound
  # to the SDK identity and HOME/TMPDIR/GOCACHE to the cache that holds the
  # configuration; the executor's own GOFLAGS survive, since they carry the
  # authenticated readonly/parallelism contract.
  def importcfg_environment(context)
    cache = context.fetch('cache')
    context.fetch('environment').merge(
      'GOROOT' => context.fetch('goroot'), 'GOOS' => context.fetch('goos'), 'GOARCH' => context.fetch('goarch'),
      'GOENV' => 'off', 'GOWORK' => 'off', 'GOCACHE' => cache,
      'HOME' => File.join(cache, IMPORTCFG_HOME), 'TMPDIR' => File.join(cache, IMPORTCFG_TMP)
    ).sort.to_h
  end

  # Reconstruct the executor's cache key using the independently supplied run
  # provenance. A receipt and preparation can agree about a forged GOFLAGS;
  # their environment must also produce the cache identity sealed by the run.
  def importcfg_provenance_context!(receipt, provenance)
    environment = receipt.fetch('context').fetch('environment')
    raise ContractError, 'import configuration retains no build environment' unless environment.is_a?(Hash)
    cache = provenance.fetch('cache')
    before_cache = provenance.reject { |key, _| key == 'cache' }
    expected_key = Digest::SHA256.hexdigest(canonical(before_cache.merge('build_environment' => environment)))
    unless cache.fetch('key') == expected_key && File.basename(cache.fetch('path')) == expected_key
      raise ContractError, 'import configuration build environment differs from the provenance cache key'
    end
    { 'identity' => provenance.fetch('sdk').fetch('identity'), 'cache' => cache.fetch('path'), 'environment' => environment }
  rescue KeyError, TypeError => error
    raise ContractError, "malformed import configuration provenance: #{error.message}"
  end

  # The known context is what the preparation environment is judged against, and
  # it is itself anchored outside the receipt: the SDK root is derived from the
  # authenticated toolchain binary's own path, the platform from the SDK
  # identity, and the cache from the directory the configuration actually lives
  # in. A caller already holding a validated context -- the executor about to
  # compile, or a manager replaying with provenance in hand -- supplies it, and
  # every supplied key must match exactly.
  def authenticate_import_context!(receipt, tool_path, supplied)
    context = receipt['context']
    raise ContractError, 'import configuration retains no known context' unless context.is_a?(Hash)
    (supplied || {}).each do |key, value|
      next if value.nil?
      raise ContractError, "import configuration #{key} differs from the validated context: #{context[key].inspect}" unless context[key] == value
    end
    root = sdk_root(tool_path)
    raise ContractError, "import configuration GOROOT is not the pinned SDK root: #{context.fetch('goroot').inspect}" unless same_path?(context.fetch('goroot'), root)
    goos, goarch = sdk_platform(context.fetch('identity'))
    unless [context.fetch('goos'), context.fetch('goarch')] == [goos, goarch]
      raise ContractError, "import configuration platform differs from the SDK identity: #{context.fetch('goos')}/#{context.fetch('goarch')}"
    end
    unless same_path?(context.fetch('cache'), File.dirname(receipt.fetch('path')))
      raise ContractError, "import configuration cache differs from the directory holding it: #{context.fetch('cache').inspect}"
    end
    environment = context.fetch('environment')
    raise ContractError, 'import configuration retains no build environment' unless environment.is_a?(Hash)
    { 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off' }.each do |key, value|
      raise ContractError, "import configuration build environment #{key} is not #{value.inspect}: #{environment[key].inspect}" unless environment[key] == value
    end
    unless environment['GOROOT'].nil? || same_path?(environment['GOROOT'], root)
      raise ContractError, "import configuration build environment GOROOT is not the pinned SDK root: #{environment['GOROOT'].inspect}"
    end
    context
  end

  # An import configuration is usable only when it still authenticates end to
  # end. A shared cache that merely holds a file named importcfg-std proves
  # nothing: the rows name archive paths, and both the archives and the file
  # itself outlive the process that wrote them. Reuse therefore re-checks that
  # the configuration was prepared by this executor's authenticated SDK binary
  # with the exact upstream recipe, in the exact known toolchain environment
  # anchored to that binary and to the SDK identity, that the preparation was a
  # bounded captured process with a complete receipt, that the configuration
  # bytes are unchanged, that the retained package set is exactly what the
  # retained preparation output published, that its rows still match that set,
  # and that every packagefile archive still holds the exact bytes hashed at
  # preparation time. Every failure is named; nothing is silently re-prepared or
  # skipped. This is the single shared contract: the executor calls it before
  # every compile that uses a configuration, and validation and resume call it
  # on every retained compile stage.
  def authenticate_import_configuration!(receipt, tool:, context: nil)
    raise ContractError, 'missing import configuration receipt' unless receipt.is_a?(Hash)
    raise ContractError, "unknown import configuration schema: #{receipt['schema'].inspect}" unless receipt['schema'] == IMPORTCFG_SCHEMA

    prepared_tool = receipt.fetch('tool')
    unless tool.nil? || (prepared_tool.fetch('path') == tool.fetch('path') && prepared_tool.fetch('sha256') == tool.fetch('sha256'))
      raise ContractError, "import configuration was prepared by a different toolchain: #{prepared_tool.fetch('path')}"
    end
    authenticate_file(prepared_tool.fetch('path'), prepared_tool.fetch('sha256'))

    stage = receipt.fetch('preparation')
    raise ContractError, 'import configuration preparation is not a captured process receipt' unless stage.is_a?(Hash) && %w[argv cwd environment stdout stderr].all? { |key| stage[key] }
    raise ContractError, 'import configuration preparation was not bounded' unless stage['timeout_seconds'].is_a?(Numeric) && stage['timeout_seconds'].positive?
    raise ContractError, "import configuration preparation did not complete: #{stage['state']}" unless success?(stage)
    raise ContractError, 'import configuration preparation leaked a descendant' unless stage['descendants_survived'] == false
    known = authenticate_import_context!(receipt, prepared_tool.fetch('path'), context)
    raise ContractError, 'import configuration preparation escaped the local toolchain' unless stage.fetch('environment')['GOTOOLCHAIN'] == 'local'
    # Checking one variable would let a receipt prepared against another SDK
    # root, another platform, an inherited go env file or a foreign cache
    # certify. The whole environment is the contract, so the whole environment
    # is compared and the offending variables are named.
    expected_environment = importcfg_environment(known)
    actual_environment = stage.fetch('environment')
    unless actual_environment == expected_environment
      differing = (expected_environment.keys | actual_environment.keys).reject { |key| expected_environment[key] == actual_environment[key] }
      raise ContractError, "import configuration preparation environment differs: #{differing.sort.join(', ')}"
    end
    unless stage.fetch('cwd') == File.join(known.fetch('cache'), IMPORTCFG_HOME)
      raise ContractError, "import configuration preparation ran outside its cache: #{stage.fetch('cwd')}"
    end
    %w[stdout stderr].each do |stream|
      observation = stage.fetch(stream)
      expected_path = File.join(known.fetch('cache'), IMPORTCFG_LOGS, IMPORTCFG_LOG) + '.' + stream
      raise ContractError, "import configuration preparation #{stream} is not the retained capture: #{observation.fetch('path')}" unless observation.fetch('path') == expected_path
      actual = file_record(observation.fetch('path'))
      raise ContractError, "import configuration preparation #{stream} changed" unless %w[sha256 bytes].all? { |key| observation[key] == actual[key] }
    end
    argv = stage.fetch('argv')
    unless argv.length == 6 && argv[0] == prepared_tool.fetch('path') && argv[1, 3] == IMPORTCFG_RECIPE &&
           argv[4] == IMPORTCFG_TEMPLATE && argv[5] == 'std'
      raise ContractError, "import configuration used a different recipe: #{argv.inspect}"
    end

    actual = file_record(receipt.fetch('path'))
    raise ContractError, "import configuration changed since preparation: #{receipt.fetch('path')}" unless %w[sha256 bytes].all? { |key| receipt[key] == actual[key] }

    packages = receipt.fetch('packages')
    raise ContractError, 'import configuration publishes no packages' unless packages.is_a?(Array) && !packages.empty?
    names = packages.map { |package| package.fetch('name') }
    raise ContractError, 'import configuration repeats a package' unless names.uniq == names
    raise ContractError, 'import configuration package set changed' unless Digest::SHA256.hexdigest(canonical(packages)) == receipt.fetch('packages_sha256')
    # The retained stream hash only proves the log still holds the bytes the
    # receipt claims; it says nothing about whether those bytes are the ones the
    # package set was built from. A rewritten stdout carrying a self-consistent
    # hash is caught here, by re-deriving the rows and joining them to the
    # sealed package set and to the configuration the compiler is handed.
    published = importcfg_rows(File.binread(stage.fetch('stdout').fetch('path')))
    raise ContractError, 'import configuration preparation published no packages' if published.empty?
    retained = packages.map { |package| [package.fetch('name'), package.fetch('archive').fetch('path')] }
    unless published == retained
      offending = (published.map(&:first) | retained.map(&:first)).reject { |name| published.assoc(name) == retained.assoc(name) }
      raise ContractError, "retained packages differ from the preparation output: #{offending.sort.first(3).join(', ')}"
    end
    rows = retained.map { |name, archive| importcfg_row(name, archive) }
    raise ContractError, 'import configuration rows differ from the retained package set' unless File.binread(receipt.fetch('path')).split("\n", -1)[0..-2] == rows

    packages.each do |package|
      archive = package.fetch('archive')
      current = begin
        file_record(archive.fetch('path'))
      rescue ContractError
        raise ContractError, "stdlib archive is missing: #{package.fetch('name')} (#{archive.fetch('path')})"
      end
      unless %w[sha256 bytes].all? { |key| archive[key] == current[key] }
        raise ContractError, "stdlib archive changed since preparation: #{package.fetch('name')} (#{archive.fetch('path')})"
      end
    end
    receipt
  rescue KeyError, TypeError => e
    raise ContractError, "malformed import configuration receipt: #{e.message}"
  end

  class Executor
    attr_reader :provenance

    # importcfg_timeout bounds the one-off stdlib export preparation, which is a
    # cold-cache toolchain walk rather than a per-case stage; it is declared here
    # and retained in the preparation receipt so the bound itself is reviewable.
    IMPORTCFG_TIMEOUT_SECONDS = 900

    def initialize(bashy:, go:, evidence_root:, candidate:, sdk:, env: {}, timeout: 30, cache_root: nil, importcfg_timeout: IMPORTCFG_TIMEOUT_SECONDS)
      @bashy, @go = File.expand_path(bashy), File.realpath(go)
      @root, @timeout = File.expand_path(evidence_root), timeout
      @lineage_root = File.join(@root, '.process-lineage')
      raise ContractError, 'importcfg preparation must be bounded' unless importcfg_timeout.is_a?(Numeric) && importcfg_timeout.positive?
      @importcfg_timeout = importcfg_timeout
      @env = { 'PATH' => ENV.fetch('PATH', ''), 'LC_ALL' => 'C', 'TZ' => 'UTC', 'GOTOOLCHAIN' => 'local', 'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'BASHY_HINTS' => 'off' }.merge(env)
      raise ContractError, 'GOTOOLCHAIN must remain local' unless @env['GOTOOLCHAIN'] == 'local'
      @provenance = { 'candidate' => Corpus.authenticate_candidate(@bashy, candidate),
                      'sdk' => sdk.merge('binary' => Corpus.authenticate_file(@go, sdk.fetch('sha256'))),
                      'platform' => RbConfig::CONFIG.values_at('host_os', 'host_cpu'),
                      'executor_sha256' => Corpus.digest(__FILE__) }
      cache_key = Digest::SHA256.hexdigest(Corpus.canonical(@provenance.merge('build_environment' => @env)))
      @cache = File.join(File.expand_path(cache_root || File.join(@root, '.cache')), cache_key)
      FileUtils.mkdir_p(@cache)
      @provenance['cache'] = { 'path' => @cache, 'key' => cache_key, 'policy' => 'shared immutable candidate/SDK/environment; Go concurrent cache' }
      out, err, status = Open3.capture3({ 'GOTOOLCHAIN' => 'local' }, @go, 'version')
      raise ContractError, "SDK identity mismatch: #{out} #{err}" unless status.success? && out.strip == sdk.fetch('identity')
    end

    # sources/assets are relative paths; module_files contains generated module
    # context, never replacements for original input. package_input is an explicit
    # directory argument for multi-file packages (the CLI must support it).
    def execute(id:, source_root:, sources:, assets: [], phase: 'run', args: [], module_files: {}, runtime_env: {}, package_input: nil,
                root_id: id, parent_launch_id: nil, combined_output: false, route: nil, identity_receipts: nil,
                native_observation: nil)
      verify_tools!
      raise ContractError, 'unknown phase' unless %w[run build compile].include?(phase)
      raise ContractError, 'source list empty or duplicated' if sources.empty? || sources.uniq != sources
      raise ContractError, 'overlapping/duplicate inputs' unless (sources + assets).uniq == sources + assets
      raise ContractError, 'module files overlap immutable input' unless (module_files.keys & (sources + assets)).empty?
      raise ContractError, 'multiple sources require explicit package_input' if sources.length > 1 && !package_input
      package_input = Corpus.package_argument(package_input)
      (sources + assets + module_files.keys).each { |path| Corpus.safe_path('/unused', path) }
      source_root = File.realpath(source_root)
      inputs = (sources + assets).to_h { |p| [p, Corpus.file_record(Corpus.safe_path(source_root, p))] }
      case_dir = Corpus.safe_path(@root, id)
      raise ContractError, "evidence already exists: #{case_dir}" if File.exist?(case_dir)
      FileUtils.mkdir_p(case_dir)
      record = { 'schema' => SCHEMA, 'id' => id, 'phase' => phase, 'sources' => sources, 'assets' => assets,
                 'inputs' => inputs, 'args' => args, 'provenance' => @provenance, 'modes' => {},
                 'package_input' => package_input, 'runtime_environment' => runtime_env,
                 'module_files' => module_files.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }
      record['route'] = route if route
      MODES.each do |mode|
        record['modes'][mode] = execute_mode(case_dir, mode, inputs, sources, assets, module_files, phase, args, runtime_env,
                                             package_input, root_id, parent_launch_id, id, combined_output, identity_receipts,
                                             native_observation)
      end
      inputs.each { |p, data| raise ContractError, "upstream input changed: #{p}" unless Corpus.digest(data.fetch('path')) == data.fetch('sha256') }
      verify_tools!
      record['verdict'] = exact_verdict(record)
      File.write(File.join(case_dir, 'result.json'), Corpus.canonical(record) + "\n")
      record
    end

    private

    # The stdlib export preparation is a real subprocess against the pinned
    # toolchain, so it is bounded and captured like every other stage and it
    # leaves the same process receipt. Reuse never trusts a file that merely
    # exists in the cache: the retained receipt is re-authenticated against the
    # SDK binary, the recipe, the known toolchain environment, the configuration
    # bytes and every archive it names. A configuration with no receipt is
    # exactly the unauthenticated reuse this contract exists to refuse, so it
    # fails closed by name.
    #
    # Nothing is memoised. Authenticating once and then reusing the answer would
    # certify the state of the archives at first use, not at the use that
    # actually matters: an archive replaced between two compiles would be
    # compiled against unnoticed. Every call re-reads the retained receipt from
    # the cache and re-authenticates it, and callers ask immediately before the
    # compile they are about to spawn.
    def import_configuration
      path = File.join(@cache, IMPORTCFG_NAME)
      receipt_path = File.join(@cache, IMPORTCFG_RECEIPT)
      unless File.exist?(receipt_path)
        raise ContractError, "stdlib importcfg present without a preparation receipt: #{path}" if File.exist?(path)
        prepare_import_configuration(path, receipt_path)
      end
      Corpus.authenticate_import_configuration!(load_import_receipt(receipt_path), tool: @provenance.dig('sdk', 'binary'),
                                                context: import_context(@provenance.fetch('sdk').fetch('binary').fetch('path')))
    end

    # The exact context the preparation is allowed to have run in, derived from
    # this executor rather than read back out of the receipt: the SDK root comes
    # from the authenticated toolchain binary's own path, the platform from the
    # SDK identity this executor verified at construction, and the cache from
    # the directory this executor owns. A declared GOROOT that disagrees with
    # the pinned SDK is refused rather than quietly overridden.
    def import_context(tool_path)
      identity = @provenance.fetch('sdk').fetch('identity')
      goos, goarch = Corpus.sdk_platform(identity)
      root = Corpus.sdk_root(tool_path)
      unless @env['GOROOT'].nil? || Corpus.same_path?(@env['GOROOT'], root)
        raise ContractError, "GOROOT is not the pinned SDK root: #{@env['GOROOT'].inspect}"
      end
      { 'identity' => identity, 'goroot' => root, 'goos' => goos, 'goarch' => goarch,
        'cache' => @cache, 'environment' => @env.sort.to_h }
    end

    def load_import_receipt(receipt_path)
      raise ContractError, "import configuration receipt is not a regular file: #{receipt_path}" unless File.file?(receipt_path) && !File.symlink?(receipt_path)
      JSON.parse(File.read(receipt_path))
    rescue JSON::ParserError => e
      raise ContractError, "unreadable import configuration receipt: #{e.message}"
    end

    # `go list -export ... std` publishes archives that already belong to the
    # authenticated toolchain; it never executes an original program body. The
    # captured stdout is the only source of rows, and every archive it names is
    # hashed here so a later substitution cannot pass as the prepared one.
    def prepare_import_configuration(path, receipt_path)
      tool = Corpus.authenticate_file(@go, @provenance.fetch('sdk').fetch('binary').fetch('sha256'))
      context = import_context(tool.fetch('path'))
      # The preparation environment is the known context's environment, exactly:
      # the same map authentication recomputes, so a reviewer never has to trust
      # a variable the receipt merely reports.
      env = Corpus.importcfg_environment(context)
      logs = File.join(@cache, IMPORTCFG_LOGS)
      [env.fetch('HOME'), env.fetch('TMPDIR'), logs].each { |dir| FileUtils.mkdir_p(dir) }
      stage = Corpus.capture([tool.fetch('path'), *IMPORTCFG_RECIPE, IMPORTCFG_TEMPLATE, 'std'],
                             cwd: env.fetch('HOME'), log_prefix: File.join(logs, IMPORTCFG_LOG), env: env, timeout: @importcfg_timeout)
      stage['stage'] = 'prepare-importcfg'
      unless Corpus.success?(stage)
        detail = File.binread(stage.fetch('stderr').fetch('path')).to_s.strip.lines.last.to_s.strip
        raise ContractError, "stdlib importcfg unavailable (#{stage['state']}): #{detail}"
      end
      published = Corpus.importcfg_rows(File.binread(stage.fetch('stdout').fetch('path')))
      raise ContractError, 'stdlib importcfg is empty' if published.empty?
      packages = published.map do |name, archive|
        raise ContractError, "importcfg archive missing: #{archive}" unless File.file?(archive) && !File.symlink?(archive)
        { 'name' => name, 'archive' => Corpus.file_record(archive) }
      end
      names = packages.map { |package| package.fetch('name') }
      raise ContractError, 'stdlib importcfg repeats a package' unless names.uniq == names
      publish(path, packages.map { |package| Corpus.importcfg_row(package.fetch('name'), package.fetch('archive').fetch('path')) }.join("\n") + "\n")
      receipt = Corpus.file_record(path).merge(
        'schema' => IMPORTCFG_SCHEMA, 'tool' => tool, 'context' => context, 'preparation' => stage, 'packages' => packages,
        'packages_sha256' => Digest::SHA256.hexdigest(Corpus.canonical(packages))
      )
      publish(receipt_path, Corpus.canonical(receipt) + "\n")
      receipt
    end

    # Retained configuration and receipt are immutable once published: written
    # to a private scratch name, renamed into place and left read-only so a
    # later run reviews the same bytes a manager does.
    def publish(path, content)
      scratch = path + ".#{Process.pid}.tmp"
      File.write(scratch, content)
      File.chmod(0o444, scratch)
      File.rename(scratch, path)
    end

    def verify_tools!
      [@provenance.dig('candidate', 'launcher'), @provenance.dig('candidate', 'payload'), @provenance.dig('sdk', 'binary')].each do |file|
        Corpus.authenticate_file(file.fetch('path'), file.fetch('sha256'))
      end
    end

    def execute_mode(case_dir, mode, inputs, sources, assets, module_files, phase, args, runtime_env, package_input,
                     root_id = File.basename(case_dir), parent_launch_id = nil, execution_id = File.basename(case_dir), combined_output = false,
                     identity_receipts = nil, native_observation = nil)
      dir = File.join(case_dir, mode)
      work, artifacts, runtime = %w[work artifacts runtime].map { |s| File.join(dir, s) }
      [work, artifacts, runtime].each { |p| FileUtils.mkdir_p(p) }
      inputs.each do |p, data|
        destination = Corpus.safe_path(work, p)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(data.fetch('path'), destination)
        raise ContractError, "input copy differs: #{p}" unless Corpus.digest(destination) == data['sha256']
      end
      module_files.each do |p, bytes|
        destination = Corpus.safe_path(work, p)
        FileUtils.mkdir_p(File.dirname(destination)); File.binwrite(destination, bytes)
      end
      environment = @env.merge('HOME' => File.join(dir, 'home'), 'TMPDIR' => File.join(dir, 'tmp'), 'GOCACHE' => @cache)
      %w[HOME TMPDIR GOCACHE].each { |key| FileUtils.mkdir_p(environment.fetch(key)) }
      input = Corpus.package_argument(package_input) || sources.fetch(0)
      absolute_input = File.expand_path(input, work)
      assets.each do |p|
        target = Corpus.safe_path(runtime, p)
        FileUtils.mkdir_p(File.dirname(target)); FileUtils.cp(inputs.fetch(p).fetch('path'), target)
      end
      empty_path = File.join(dir, 'empty-path'); FileUtils.mkdir_p(empty_path)
      run_env = environment.merge('PATH' => empty_path).merge(runtime_env)
      raise ContractError, 'runtime GOTOOLCHAIN must remain local' unless run_env['GOTOOLCHAIN'] == 'local'
      runtime_before = Corpus.snapshot(runtime)
      generated, map, binary, object = %w[generated.go generated.go.map program object.o].map { |s| File.join(artifacts, s) }
      result = { 'mode' => mode, 'phase' => phase, 'stages' => [], 'artifacts' => {}, 'state' => 'complete', 'source_directory' => work, 'runtime_directory' => runtime, 'input_checks' => [] }
      lineage_path = File.join(@lineage_root || File.join(@root || case_dir, '.process-lineage'), Digest::SHA256.hexdigest(root_id) + '.jsonl')
      lineage_parent = parent_launch_id
      # `compile` is a compile-only obligation: the upstream testdir harness runs
      # `go tool compile -e -p=p -importcfg=<stdlib>` and never links. An ordinary
      # `go build` would reject a valid `package main` that declares no main, so it
      # can never stand in as the compile oracle.
      #
      # The argv is deferred: the import configuration is authenticated where it
      # is resolved, immediately before this compile is spawned, and the receipt
      # retained beside the stage is that same authentication. Resolving it when
      # the command list was built would certify a configuration as it stood
      # before an earlier stage in this very mode had run.
      compile_argv = lambda do |source|
        lambda do
          configuration = import_configuration
          result['import_configuration'] = configuration
          [@go, 'tool', 'compile', '-e', '-p=p', '-importcfg=' + configuration.fetch('path'), '-o', object, source]
        end
      end
      producer = lambda { |source| phase == 'compile' ? ['compile', compile_argv.call(source)] : ['build', [@go, 'build', '-o', binary, source]] }
      commands = case mode
                 when 'baseline' then [producer.call(input)]
                 when 'interpreted' then [[%w[build compile].include?(phase) ? 'check' : 'run', [@bashy, '--bashpp', '--source=go', *(%w[build compile].include?(phase) ? ['--check'] : []), absolute_input, *args]]]
                 when 'compiled' then [['transpile', [@bashy, 'transpile', '--bashpp', '--source=go', input, '-o', generated, '--map', map]],
                                       producer.call(generated)]
                 end
      commands.each do |stage_name, argv|
        intact = verify_inputs(work, inputs, module_files) && verify_assets(runtime, assets, inputs)
        result['input_checks'] << { 'phase' => 'before-' + stage_name, 'valid' => intact }
        unless intact
          result['state'] = 'input_mutation'; break
        end
        argv = argv.call if argv.is_a?(Proc)
        lineage_artifacts = case stage_name
                            when 'transpile' then { 'generated_source' => generated, 'source_map' => map }
                            when 'compile' then { 'object' => object }
                            when 'build' then { 'native' => binary }
                            else {}
                            end
        lineage_artifact_parents = if mode == 'compiled' && lineage_parent && %w[compile build].include?(stage_name)
                                     lineage_artifacts.keys.to_h { |label| [label, { 'launch_id' => lineage_parent, 'artifact' => 'generated_source' }] }
                                   else
                                     {}
                                   end
        stage_id = "#{execution_id}/#{mode}/#{stage_name}"
        identity = authenticate_stage_identity(identity_receipts, stage_id, root_id, stage_name == 'run' ? run_env : environment)
        stage = capture_stage(argv: argv, cwd: stage_name == 'run' ? runtime : work,
          log_prefix: File.join(dir, stage_name), environment: stage_name == 'run' ? run_env : environment,
          lineage_path: lineage_path, root_id: root_id, stage_id: stage_id, parent_launch_id: lineage_parent,
          artifact_paths: lineage_artifacts, artifact_parents: lineage_artifact_parents,
          combined_output: combined_output && stage_name == 'run', identity: identity,
          native_observation: native_observation, stage_role: stage_name)
        lineage_parent = stage.dig('lineage', 'launch_id')
        stage['stage'] = stage_name
        result['stages'] << stage
        intact = verify_inputs(work, inputs, module_files)
        result['input_checks'] << { 'phase' => 'after-' + stage_name, 'valid' => intact }
        unless intact
          result['state'] = 'input_mutation'; break
        end
        unless Corpus.success?(stage)
          result['state'] = stage_name == 'run' && stage['state'] == 'exited' ? 'complete' : 'stage_failure'
          break
        end
        if stage_name == 'transpile'
          unless File.file?(generated) && File.size?(generated) && File.file?(map) && File.size?(map)
            result['state'] = 'missing_artifact'; break
          end
          result['artifacts']['generated'] = Corpus.file_record(generated)
          result['artifacts']['source_map'] = Corpus.file_record(map)
          result['artifacts']['generated']['lineage'] = { 'producer_launch_id' => stage.dig('lineage', 'launch_id'), 'artifact' => 'generated_source' }
          result['artifacts']['source_map']['lineage'] = { 'producer_launch_id' => stage.dig('lineage', 'launch_id'), 'artifact' => 'source_map' }
          mapping = JSON.parse(File.read(map)) rescue {}
          unless Corpus.valid_source_map?(mapping, result['artifacts']['generated'], inputs.slice(*sources))
            result['state'] = 'invalid_source_map'; break
          end
        elsif stage_name == 'compile'
          # Compile-only credit requires the toolchain's own object archive; any
          # other nonempty output is a missing artifact, not a compiled package.
          unless Corpus.go_object_archive?(object)
            result['state'] = 'missing_artifact'; break
          end
          result['artifacts']['object'] = Corpus.file_record(object)
          result['artifacts']['object']['lineage'] = { 'producer_launch_id' => stage.dig('lineage', 'launch_id'), 'artifact' => 'object' }
        elsif stage_name == 'build'
          # `go build` links a native program for main packages and writes a Go
          # archive for non-main ones; neither may degrade to an arbitrary file.
          linked = Corpus.native_binary?(binary)
          unless File.file?(binary) && File.size?(binary) && (linked || (phase == 'build' && Corpus.go_object_archive?(binary)))
            result['state'] = 'missing_artifact'; break
          end
          result['artifacts']['native'] = Corpus.file_record(binary)
          result['artifacts']['native']['lineage'] = { 'producer_launch_id' => stage.dig('lineage', 'launch_id'), 'artifact' => 'native' }
        end
      end
      result['input_integrity'] = verify_inputs(work, inputs, module_files) && result['input_checks'].all? { |check| check['valid'] }
      result['state'] = 'input_mutation' unless result['input_integrity']
      if phase == 'run' && mode != 'interpreted' && result['state'] == 'complete'
        # Keep durable copies in artifacts for review, but remove compilation inputs
        # from the actual build cwd before executing its native result.
        FileUtils.cp_r(work, File.join(artifacts, 'inputs'))
        FileUtils.rm_rf(work)
        FileUtils.mkdir_p(work)
        sources.each { |p| raise ContractError, 'source remains in runtime cwd' if File.exist?(File.join(runtime, p)) }
        raise ContractError, 'runtime asset changed before run' unless verify_assets(runtime, assets, inputs)
        stage_id = "#{execution_id}/#{mode}/run"
        identity = authenticate_stage_identity(identity_receipts, stage_id, root_id, run_env)
        stage = capture_stage(argv: [binary, *args], cwd: runtime, log_prefix: File.join(dir, 'run'),
          environment: run_env, lineage_path: lineage_path, root_id: root_id, stage_id: stage_id,
          parent_launch_id: lineage_parent, artifact_paths: {}, artifact_parents: {},
          combined_output: combined_output, identity: identity, native_observation: native_observation,
          stage_role: 'run')
        stage['stage'] = 'run'
        result['stages'] << stage
        result['state'] = 'stage_failure' unless stage['spawned'] && stage['state'] == 'exited'
        result['effects'] = effects(runtime_before, Corpus.snapshot(runtime))
        result['source_absence'] = { 'scope' => 'compilation cwd removed; runtime cwd assets only; no OS sandbox', 'path' => run_env['PATH'] }
      elsif mode == 'interpreted' && phase == 'run'
        result['effects'] = effects(runtime_before, Corpus.snapshot(runtime))
      end
      result
    end

    def verify_inputs(work, inputs, module_files)
      inputs.all? { |p, data| Corpus.digest(Corpus.safe_path(work, p)) == data.fetch('sha256') } &&
        module_files.all? { |p, bytes| Corpus.digest(Corpus.safe_path(work, p)) == Digest::SHA256.hexdigest(bytes) }
    rescue ContractError, SystemCallError
      false
    end

    def authenticate_stage_identity(receipts, stage_id, root_id, environment)
      return nil unless receipts
      reference = receipts.fetch(stage_id) { raise ContractError, "execution identity missing for #{stage_id}" }
      unless reference.is_a?(Hash) && reference.keys.sort == %w[path sha256]
        raise ContractError, "execution identity reference malformed for #{stage_id}"
      end
      receipt = GoFullExecutionIdentity.load!(reference.fetch('path'), expected_sha256: reference.fetch('sha256'))
      controlled = environment.slice(*GoFullExecutionIdentity::CONTROLLED_ENVIRONMENT)
      GoFullExecutionIdentity.authorize_launch!(receipt, root_id: root_id, stage_id: stage_id,
        timeout_seconds: @timeout, environment: controlled)
      reference
    end

    def capture_stage(argv:, cwd:, log_prefix:, environment:, lineage_path:, root_id:, stage_id:,
                      parent_launch_id:, artifact_paths:, artifact_parents:, combined_output:,
                      identity:, native_observation:, stage_role:)
      unless identity
        return Corpus.capture(argv, cwd: cwd, log_prefix: log_prefix, env: environment, timeout: @timeout,
          lineage: { path: lineage_path, root_id: root_id, stage_id: stage_id,
                     parent_launch_id: parent_launch_id, artifact_paths: artifact_paths,
                     artifact_parents: artifact_parents, combined_output: combined_output })
      end
      raise ContractError, 'authenticated stage requires native applicability evidence' unless native_observation
      role = %w[compile build run check].include?(stage_role) ? stage_role : 'execute'
      resolution = GoFullStageResolver.run!(identity_path: identity.fetch('path'), identity_sha256: identity.fetch('sha256'),
        root_id: root_id, stage_id: stage_id, native_observation: native_observation.slice('status', 'evidence_kind'),
        decision: 'execute', stage_role: role, argv: argv, cwd: cwd, environment: environment,
        lineage_path: lineage_path, log_prefix: log_prefix, parent_launch_id: parent_launch_id,
        artifact_paths: artifact_paths, artifact_parents: artifact_parents, combined_output: combined_output)
      stage = resolution.fetch('stage')
      stage['resolution'] = resolution.reject { |key, _value| key == 'stage' }
      stage
    end

    def verify_assets(runtime, assets, inputs)
      assets.all? { |p| Corpus.digest(Corpus.safe_path(runtime, p)) == inputs.fetch(p).fetch('sha256') }
    rescue ContractError, SystemCallError
      false
    end

    def effects(before, after)
      (before.keys | after.keys).sort.map do |path|
        [path, { 'before' => before[path], 'after' => after[path] }] unless before[path] == after[path]
      end.compact.to_h
    end

    def exact_verdict(record)
      modes = record.fetch('modes')
      return 'FAIL' unless modes.keys == MODES && modes.values.all? { |r| r['state'] == 'complete' && r['input_integrity'] }
      return 'PASS' if %w[build compile].include?(record['phase'])
      observations = modes.values.map do |mode|
        run = mode['stages'].last
        return 'FAIL' unless run['stage'] == 'run' && run['state'] == 'exited' && run['spawned'] && run['signal'].nil?
        streams = if run['combined']
                    ['kernel-combined', run.dig('combined', 'sha256')]
                  else
                    ['separate-nonordering', run.dig('stdout', 'sha256'), run.dig('stderr', 'sha256')]
                  end
        [run['exit'], run['signal'], *streams, mode['effects']]
      end
      observations.uniq.length == 1 ? 'PASS' : 'FAIL'
    end
  end
end
