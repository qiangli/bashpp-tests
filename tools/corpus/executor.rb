# frozen_string_literal: true
# Sprint: #118; Story: #11; Story-ID: e29305614139
require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'rbconfig'

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
    { 'path' => File.expand_path(path), 'bytes' => File.size(path), 'sha256' => digest(path) }
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
  def capture(argv, cwd:, log_prefix:, env:, timeout:, stdin: File::NULL)
    raise ContractError, 'invalid command/deadline' unless argv.is_a?(Array) && !argv.empty? && argv.all? { |a| a.is_a?(String) } && timeout.positive?
    FileUtils.mkdir_p(File.dirname(log_prefix))
    out_path, err_path = log_prefix + '.stdout', log_prefix + '.stderr'
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = { 'argv' => argv, 'cwd' => cwd, 'environment' => env.sort.to_h, 'timeout_seconds' => timeout,
               'spawned' => false, 'state' => 'launch_failure', 'exit' => nil, 'signal' => nil }
    pid = nil
    File.open(out_path, 'wb') do |out|
      File.open(err_path, 'wb') do |err|
        begin
          pid = Process.spawn(env, *argv, chdir: cwd, in: stdin, out: out, err: err, pgroup: true, unsetenv_others: true)
          result['spawned'] = true
          status = nil
          loop do
            waited, status = Process.waitpid2(pid, Process::WNOHANG)
            break if waited
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= timeout
              result['state'] = 'deadline'
              kill_group(pid)
              _, status = Process.waitpid2(pid)
              break
            end
            sleep 0.01
          end
          result['state'] = 'exited' unless result['state'] == 'deadline'
          result['exit'] = status.exitstatus
          result['signal'] = status.termsig
          begin
            Process.kill(0, -pid)
            result['descendants_survived'] = true
            result['state'] = 'process_leak' if result['state'] == 'exited'
          rescue Errno::ESRCH
            result['descendants_survived'] = false
          end
        rescue SystemCallError => e
          err.write("#{e.class}: #{e.message}\n")
        ensure
          kill_group(pid) if pid
        end
      end
    end
    result['duration_seconds'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    result['stdout'] = file_record(out_path)
    result['stderr'] = file_record(err_path)
    result
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

  class Executor
    attr_reader :provenance

    def initialize(bashy:, go:, evidence_root:, candidate:, sdk:, env: {}, timeout: 30, cache_root: nil)
      @bashy, @go = File.expand_path(bashy), File.realpath(go)
      @root, @timeout = File.expand_path(evidence_root), timeout
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
    def execute(id:, source_root:, sources:, assets: [], phase: 'run', args: [], module_files: {}, runtime_env: {}, package_input: nil)
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
      MODES.each do |mode|
        record['modes'][mode] = execute_mode(case_dir, mode, inputs, sources, assets, module_files, phase, args, runtime_env, package_input)
      end
      inputs.each { |p, data| raise ContractError, "upstream input changed: #{p}" unless Corpus.digest(data.fetch('path')) == data.fetch('sha256') }
      verify_tools!
      record['verdict'] = exact_verdict(record)
      File.write(File.join(case_dir, 'result.json'), Corpus.canonical(record) + "\n")
      record
    end

    private

    # Compile-only phases resolve their imports exactly the way the pinned SDK's
    # own testdir harness does: `go list -export` prepares the standard library
    # archives once and the resulting packagefile map is handed to the compiler.
    # Nothing here executes an original program body; it only publishes archives
    # that already belong to the authenticated toolchain.
    IMPORTCFG_TEMPLATE = '{{if .Export}}packagefile {{.ImportPath}}={{.Export}}{{end}}'

    def importcfg
      @importcfg ||= begin
        path = File.join(@cache, 'importcfg-std')
        write_importcfg(path) unless File.file?(path)
        raise ContractError, 'stdlib importcfg is not a regular file' unless File.file?(path) && !File.symlink?(path)
        path
      end
    end

    def write_importcfg(path)
      home, tmp = %w[importcfg-home importcfg-tmp].map { |name| File.join(@cache, name) }
      [home, tmp].each { |dir| FileUtils.mkdir_p(dir) }
      # GOENV is disabled the way upstream does it, but the executor's own GOFLAGS
      # are kept: they carry the authenticated readonly/parallelism contract.
      env = @env.merge('GOENV' => 'off', 'GOCACHE' => @cache, 'HOME' => home, 'TMPDIR' => tmp)
      out, err, status = Open3.capture3(env, @go, 'list', '-export', '-f', IMPORTCFG_TEMPLATE, 'std', unsetenv_others: true)
      raise ContractError, "stdlib importcfg unavailable: #{err.strip}" unless status.success?
      lines = out.lines.map(&:chomp).reject(&:empty?)
      raise ContractError, 'stdlib importcfg is empty' if lines.empty?
      lines.each do |line|
        name, _, archive = line.delete_prefix('packagefile ').partition('=')
        raise ContractError, "malformed importcfg row: #{line}" unless line.start_with?('packagefile ') && !name.empty? && !archive.empty?
        raise ContractError, "importcfg archive missing: #{archive}" unless File.file?(archive) && !File.symlink?(archive)
      end
      scratch = path + ".#{Process.pid}.tmp"
      File.write(scratch, lines.join("\n") + "\n")
      File.rename(scratch, path)
    end

    def verify_tools!
      [@provenance.dig('candidate', 'launcher'), @provenance.dig('candidate', 'payload'), @provenance.dig('sdk', 'binary')].each do |file|
        Corpus.authenticate_file(file.fetch('path'), file.fetch('sha256'))
      end
    end

    def execute_mode(case_dir, mode, inputs, sources, assets, module_files, phase, args, runtime_env, package_input)
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
      # `compile` is a compile-only obligation: the upstream testdir harness runs
      # `go tool compile -e -p=p -importcfg=<stdlib>` and never links. An ordinary
      # `go build` would reject a valid `package main` that declares no main, so it
      # can never stand in as the compile oracle.
      compile_argv = lambda { |source| [@go, 'tool', 'compile', '-e', '-p=p', '-importcfg=' + importcfg, '-o', object, source] }
      producer = lambda { |source| phase == 'compile' ? ['compile', compile_argv.call(source)] : ['build', [@go, 'build', '-o', binary, source]] }
      commands = case mode
                 when 'baseline' then [producer.call(input)]
                 when 'interpreted' then [[%w[build compile].include?(phase) ? 'check' : 'run', [@bashy, '--bashpp', '--source=go', *(%w[build compile].include?(phase) ? ['--check'] : []), absolute_input, *args]]]
                 when 'compiled' then [['transpile', [@bashy, 'transpile', '--bashpp', '--source=go', input, '-o', generated, '--map', map]],
                                       producer.call(generated)]
                 end
      result = { 'mode' => mode, 'phase' => phase, 'stages' => [], 'artifacts' => {}, 'state' => 'complete', 'source_directory' => work, 'runtime_directory' => runtime, 'input_checks' => [] }
      result['import_configuration'] = Corpus.file_record(importcfg) if phase == 'compile' && mode != 'interpreted'
      commands.each do |stage_name, argv|
        intact = verify_inputs(work, inputs, module_files) && verify_assets(runtime, assets, inputs)
        result['input_checks'] << { 'phase' => 'before-' + stage_name, 'valid' => intact }
        unless intact
          result['state'] = 'input_mutation'; break
        end
        stage = Corpus.capture(argv, cwd: stage_name == 'run' ? runtime : work, log_prefix: File.join(dir, stage_name), env: stage_name == 'run' ? run_env : environment, timeout: @timeout)
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
        elsif stage_name == 'build'
          # `go build` links a native program for main packages and writes a Go
          # archive for non-main ones; neither may degrade to an arbitrary file.
          linked = Corpus.native_binary?(binary)
          unless File.file?(binary) && File.size?(binary) && (linked || (phase == 'build' && Corpus.go_object_archive?(binary)))
            result['state'] = 'missing_artifact'; break
          end
          result['artifacts']['native'] = Corpus.file_record(binary)
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
        stage = Corpus.capture([binary, *args], cwd: runtime, log_prefix: File.join(dir, 'run'), env: run_env, timeout: @timeout)
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
        [run['exit'], run['signal'], run.dig('stdout', 'sha256'), run.dig('stderr', 'sha256'), mode['effects']]
      end
      observations.uniq.length == 1 ? 'PASS' : 'FAIL'
    end
  end
end
