#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
# A real lower/build/run differential. Structural validation is deliberately
# separate so an unavailable authenticated compiler remains an honest FAIL.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)

def fail!(message)
  warn "PARITY FAIL: #{message}"
  exit 1
end

def invoke(env, argv, chdir: ROOT)
  out, err, status = Open3.capture3(env, *argv, chdir: chdir)
  { 'argv' => argv, 'cwd' => chdir, 'exit' => status.exitstatus,
    'stdout_sha256' => Digest::SHA256.hexdigest(out), 'stderr_sha256' => Digest::SHA256.hexdigest(err), 'stdout' => out, 'stderr' => err }
end

def evidence(record, ledger = nil)
  line = JSON.generate(record.reject { |key, _| %w[stdout stderr].include?(key) })
  puts line
  File.open(ledger, 'a') { |file| file.puts(line) } if ledger
end

def data_lines(path)
  abort "PARITY FAIL: missing ledger #{path}" unless File.file?(path) && !File.symlink?(path)
  File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }
end

def host_platform
  os = RbConfig::CONFIG.fetch('host_os')
  goos = os.include?('darwin') ? 'darwin' : os.include?('linux') ? 'linux' : os
  cpu = RbConfig::CONFIG.fetch('host_cpu')
  [goos, %w[arm64 aarch64].include?(cpu) ? 'arm64' : cpu == 'x86_64' ? 'amd64' : cpu]
end

def authenticate_go(go)
  goos, goarch = host_platform
  row = data_lines(File.join(ROOT, 'docs/tour/toolchain.tsv')).map { |line| line.split("\t", -1) }.find { |fields| fields[0] == goos && fields[1] == goarch }
  fail!("no Go 1.27.0 authentication row for #{goos}/#{goarch}") unless row && row.length == 7
  _os, _arch, version, identity, expected_sha, = row
  fail!("toolchain pin version is #{version.inspect}, not go1.27.0") unless version == 'go1.27.0'
  candidate = go.include?(File::SEPARATOR) ? go : ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, go) }.find { |path| File.executable?(path) }
  real_go = File.realpath(candidate) rescue nil
  fail!("Go executable is missing: #{go}") unless real_go && File.executable?(real_go)
  result = invoke({ 'GOTOOLCHAIN' => 'local' }, [real_go, 'version'])
  actual_identity, actual_sha = result['stdout'].strip, Digest::SHA256.file(real_go).hexdigest
  evidence(result.merge('phase' => 'go-authentication', 'go' => real_go, 'identity' => actual_identity, 'binary_sha256' => actual_sha))
  fail!("Go identity #{actual_identity.inspect}, expected #{identity.inspect}") unless actual_identity == identity
  fail!("Go binary digest #{actual_sha}, expected #{expected_sha}") unless actual_sha == expected_sha
  real_go
end

def pinned_default_go
  out, err, status = Open3.capture3({ 'GOTOOLCHAIN' => 'go1.27.0' }, 'go', 'env', 'GOROOT')
  fail!("GOTOOLCHAIN=go1.27.0 could not resolve Go: #{err.strip}") unless status.success? && !out.strip.empty?
  File.join(out.strip, 'bin', 'go')
end

def cases
  rows = []
  data_lines(File.join(ROOT, 'tests/bashsharp/matrix.tsv')).each do |line|
    family, _feature, _class, _cases, lowering = line.split("\t", -1)
    abort "PARITY FAIL: malformed Bash# matrix row #{line}" unless lowering && lowering.match?(%r{\A[a-z-]+/lowering\.tsv\z})
    dir = File.join(ROOT, 'tests/bashsharp', File.dirname(lowering))
    data_lines(File.join(ROOT, 'tests/bashsharp', lowering)).each do |lowering_line|
      id, fixture, expectation, expected_rc, stdout, stderr = lowering_line.split("\t", -1)
      abort "PARITY FAIL: malformed lowering row #{lowering_line}" unless [id, fixture, expectation, expected_rc, stdout, stderr].all? && expectation.match?(/\A(run|reject)\z/)
      rows << { family: family, id: id, fixture: fixture, expectation: expectation, expected_rc: Integer(expected_rc), stdout: stdout, stderr: stderr, dir: dir }
    end
  end
  fail!('zero BASHSHARP33 lowering cases') if rows.empty?
  fail!("expected 33 BASHSHARP33 lowering cases, found #{rows.length}") unless rows.length == 33
  fail!('duplicate BASHSHARP33 lowering case identity') unless rows.map { |row| "#{row[:family]}/#{row[:id]}" }.uniq.length == rows.length
  runs, rejects = rows.count { |row| row[:expectation] == 'run' }, rows.count { |row| row[:expectation] == 'reject' }
  fail!("expected 18 runtime and 15 reject cases, found #{runs} runtime and #{rejects} reject") unless runs == 18 && rejects == 15
  rows
end

def expected(dir, token)
  return '' if token == 'empty'
  path = File.join(dir, token)
  abort "PARITY FAIL: missing expected result #{path}" unless File.file?(path)
  File.binread(path)
end

def copy_tree(source, destination)
  FileUtils.mkdir_p(destination)
  Dir.children(source).each { |entry| FileUtils.cp_r(File.join(source, entry), destination, preserve: true) }
end

def filesystem_snapshot(root, ignored = [])
  entries = []
  Find.find(root) do |path|
    relative = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
    next if relative.empty?
    next if ignored.include?(relative)
    stat = File.lstat(path)
    kind = stat.symlink? ? 'symlink' : stat.directory? ? 'directory' : stat.file? ? 'file' : 'other'
    content = stat.file? ? Digest::SHA256.file(path).hexdigest : stat.symlink? ? File.readlink(path) : ''
    entries << [relative, kind, stat.mode & 0o7777, stat.size, content]
  end
  entries.sort!
  { 'sha256' => Digest::SHA256.hexdigest(JSON.generate(entries)), 'entries' => entries.length }
end

def execution_environment(shell_free: false)
  path = shell_free ? File.join(Dir.tmpdir, "s117-empty-path-#{Process.pid}") : ENV.fetch('PATH', '')
  FileUtils.mkdir_p(path) if shell_free
  { 'LC_ALL' => 'C', 'TZ' => 'UTC', 'PATH' => path }
end

def observation(result, before, after, env, mode)
  { 'mode' => mode, 'status' => { 'exit' => result['exit'] },
    # Fixture stdout is a raw byte stream, not evidence of a typed value.
    # Until a fixture declares and captures a typed-output channel, record it
    # as explicitly unproved instead of copying stdout into a typed field.
    'typed_output' => { 'schema' => 'lowering.typed-output.v1', 'status' => 'unproved-by-this-fixture' },
    'raw_streams' => { 'schema' => 'lowering.raw-byte-streams.v1',
                       'stdout_sha256' => result['stdout_sha256'], 'stderr_sha256' => result['stderr_sha256'] },
    'effects' => { 'cwd' => '.', 'environment_sha256' => Digest::SHA256.hexdigest(JSON.generate(env.sort)), 'filesystem_before' => before, 'filesystem_after' => after },
    'errors' => { 'schema' => 'lowering.diagnostics.v1', 'stdout_sha256' => result['stdout_sha256'], 'stderr_sha256' => result['stderr_sha256'] },
    'cancellation' => { 'requested' => false, 'outcome' => 'not-requested-by-this-fixture' },
    'concurrency' => { 'requested' => false, 'outcome' => 'not-requested-by-this-fixture' } }
end

def assert_typed_only!(source, label)
  fail!("#{label}: typed-only source is not direct Go main") unless source.match?(/\A\s*package\s+main\b/)
  fail!("#{label}: typed-only source depends on an interpreter or generated runtime helper") if source.match?(/\b(?:os\/exec|exec\.Command|interp(?:reter)?\b|bashpp\b|shell\b|runtime\w*)/i)
  fail!("#{label}: typed-only source lacks direct arithmetic/callable/control flow") unless source.match?(/func\s+twice\b/) && source.match?(/\bfor\b/) && source.match?(/\bif\b/) && source.match?(/[+*]/)
end

options = { case_filter: nil, bashy: ENV.fetch('BASHY_BIN', File.join(ROOT, '../bashy/bashy')), engine: ENV.fetch('BASH_ENGINE_BIN', File.join(ROOT, '../bashy/bin/bash')), go: ENV.fetch('GO_BIN', pinned_default_go), artifacts: nil, typed_only: false }
OptionParser.new do |parser|
  parser.on('--case FILTER', 'exact FAMILY/CASE or shell glob') { |value| options[:case_filter] = value }
  parser.on('--bashy PATH') { |value| options[:bashy] = value }
  parser.on('--engine PATH') { |value| options[:engine] = value }
  parser.on('--go PATH') { |value| options[:go] = value }
  parser.on('--artifacts PATH', 'retained evidence directory') { |value| options[:artifacts] = value }
  parser.on('--typed-only', 'require direct Go, not an interpreter wrapper') { options[:typed_only] = true }
end.parse!
abort 'PARITY FAIL: unexpected arguments' unless ARGV.empty?

manifest_result = invoke({}, [File.join(ROOT, 'tools/lowering/identity_manifest.rb')])
evidence(manifest_result.merge('phase' => 'identity-manifest'))
fail!('identity manifest rejected') unless manifest_result['exit'] == 0
all_cases = cases
selected = all_cases.select { |row| options[:case_filter].nil? || row[:family] + '/' + row[:id] == options[:case_filter] || File.fnmatch?(options[:case_filter], row[:family] + '/' + row[:id]) }
fail!("case filter #{options[:case_filter].inspect} selected zero cases") if selected.empty?
fail!('--typed-only requires exactly one selected runtime case') if options[:typed_only] && (selected.length != 1 || selected[0][:expectation] != 'run')
go = authenticate_go(options[:go])
fail!("bashy transpiler is not executable: #{options[:bashy]}") unless File.executable?(options[:bashy])
fail!("Bash++ interpreter is not executable: #{options[:engine]}") unless File.executable?(options[:engine])

artifact_root = options[:artifacts] || File.join(Dir.tmpdir, "s117-lowering-artifacts-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(4)}")
fail!("artifact directory already exists: #{artifact_root}") if File.exist?(artifact_root)
FileUtils.mkdir_p(artifact_root)
puts "ARTIFACTS RETAINED: #{artifact_root}"

selected.each do |row|
  label, case_dir = "#{row[:family]}/#{row[:id]}", File.join(artifact_root, row[:family], row[:id])
  FileUtils.mkdir_p(case_dir)
  ledger = File.join(case_dir, 'evidence.jsonl')
  source_one, source_two = File.join(case_dir, 'generated.one.go'), File.join(case_dir, 'generated.two.go')
  first_dir, second_dir = File.join(case_dir, 'transpile.one'), File.join(case_dir, 'transpile.two')
  copy_tree(row[:dir], first_dir); copy_tree(row[:dir], second_dir)
  first = invoke({}, [options[:bashy], 'transpile', '--bashpp', row[:fixture], '-o', source_one], chdir: first_dir)
  second = invoke({}, [options[:bashy], 'transpile', '--bashpp', row[:fixture], '-o', source_two], chdir: second_dir)
  evidence(first.merge('phase' => 'transpile', 'case' => label, 'attempt' => 1), ledger)
  evidence(second.merge('phase' => 'transpile', 'case' => label, 'attempt' => 2), ledger)
  if row[:expectation] == 'reject'
    want_out, want_err = expected(row[:dir], row[:stdout]), expected(row[:dir], row[:stderr])
    fail!("#{label}: rejection exit changed") unless first['exit'] == row[:expected_rc] && second['exit'] == row[:expected_rc]
    fail!("#{label}: rejection diagnostic changed") unless first['stdout'] == want_out && first['stderr'] == want_err && first['stdout'] == second['stdout'] && first['stderr'] == second['stderr']
    fail!("#{label}: rejected source emitted Go") if File.size?(source_one) || File.size?(source_two)
    puts "PARITY PASS #{label}: deterministic rejection"
    next
  end
  fail!("#{label}: transpilation did not emit Go") unless first['exit'] == 0 && second['exit'] == 0 && File.size?(source_one) && File.size?(source_two)
  generated_one, generated_two = File.binread(source_one), File.binread(source_two)
  fail!("#{label}: generated Go is nondeterministic") unless generated_one == generated_two
  assert_typed_only!(generated_one, label) if options[:typed_only]
  binary = File.join(case_dir, 'lowered.bin')
  build = invoke({ 'GOTOOLCHAIN' => 'local', 'GOCACHE' => File.join(case_dir, 'go-build-cache') }, [go, 'build', '-o', binary, File.basename(source_one)], chdir: case_dir)
  evidence(build.merge('phase' => 'build', 'case' => label, 'generated_go_sha256' => Digest::SHA256.hexdigest(generated_one)), ledger)
  fail!("#{label}: generated Go did not build: #{build['stderr'].strip}") unless build['exit'] == 0 && File.executable?(binary)
  interpreted_state, compiled_state = File.join(case_dir, 'interpreted-state'), File.join(case_dir, 'compiled-state')
  copy_tree(row[:dir], interpreted_state); copy_tree(row[:dir], compiled_state)
  # Typed-only authenticity intentionally runs the binary where its original
  # Bash++ source is unavailable. The copied transpilation inputs remain in
  # the retained artifact directory; only this execution state omits it.
  FileUtils.rm_f(File.join(compiled_state, row[:fixture])) if options[:typed_only]
  env = execution_environment
  ignored = options[:typed_only] ? [row[:fixture]] : []
  before_i, before_c = filesystem_snapshot(interpreted_state, ignored), filesystem_snapshot(compiled_state, ignored)
  interpreted = invoke(env, [options[:engine], '--bashpp', row[:fixture]], chdir: interpreted_state)
  lowered_env = options[:typed_only] ? execution_environment(shell_free: true) : env
  lowered = invoke(lowered_env, [binary], chdir: compiled_state)
  after_i, after_c = filesystem_snapshot(interpreted_state, ignored), filesystem_snapshot(compiled_state, ignored)
  evidence(interpreted.merge('phase' => 'interpreted-run', 'case' => label, 'observation' => observation(interpreted, before_i, after_i, env, 'interpreted')), ledger)
  evidence(lowered.merge('phase' => 'compiled-run', 'case' => label, 'binary_sha256' => Digest::SHA256.file(binary).hexdigest, 'observation' => observation(lowered, before_c, after_c, lowered_env, 'compiled')), ledger)
  want_out, want_err = expected(row[:dir], row[:stdout]), expected(row[:dir], row[:stderr])
  fail!("#{label}: interpreter and compiled binary diverged") unless [interpreted['stdout'], interpreted['stderr'], interpreted['exit']] == [lowered['stdout'], lowered['stderr'], lowered['exit']]
  fail!("#{label}: isolated filesystem effects diverged") unless after_i == after_c
  fail!("#{label}: compiled result missed fixture oracle") unless lowered['exit'] == row[:expected_rc] && lowered['stdout'] == want_out && lowered['stderr'] == want_err
  puts "PARITY PASS #{label}: transpile/build/run evidence authenticated"
end
if selected.length == all_cases.length
  puts "BASHSHARP33 PARITY PASS: #{selected.length}/#{all_cases.length} Bash# lowering cases; compiled compiler/corpus parity NOT ESTABLISHED"
else
  puts "BASHSHARP33 PARITY SUBSET PASS: #{selected.length}/#{all_cases.length} selected Bash# lowering cases; BASHSHARP33 completion NOT ESTABLISHED; compiled compiler/corpus parity NOT ESTABLISHED"
end
