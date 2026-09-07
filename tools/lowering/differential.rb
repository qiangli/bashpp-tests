#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
# A real lower/build/run differential. Structural validation is deliberately
# separate so an unavailable authenticated compiler is an honest parity FAIL.
require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)

def fail!(message)
  warn "PARITY FAIL: #{message}"
  exit 1
end

def invoke(env, argv, chdir: ROOT)
  out, err, status = Open3.capture3(env, *argv, chdir: chdir)
  { 'argv' => argv, 'exit' => status.exitstatus, 'stdout_sha256' => Digest::SHA256.hexdigest(out), 'stderr_sha256' => Digest::SHA256.hexdigest(err), 'stdout' => out, 'stderr' => err }
end

def evidence(record)
  clean = record.reject { |key, _| %w[stdout stderr].include?(key) }
  puts JSON.generate(clean)
end

def data_lines(path)
  abort "PARITY FAIL: missing ledger #{path}" unless File.file?(path) && !File.symlink?(path)
  File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }
end

def host_platform
  os = RbConfig::CONFIG.fetch('host_os')
  goos = os.include?('darwin') ? 'darwin' : os.include?('linux') ? 'linux' : os
  cpu = RbConfig::CONFIG.fetch('host_cpu')
  goarch = %w[arm64 aarch64].include?(cpu) ? 'arm64' : cpu == 'x86_64' ? 'amd64' : cpu
  [goos, goarch]
end

def authenticate_go(go)
  goos, goarch = host_platform
  pin = File.join(ROOT, 'docs/tour/toolchain.tsv')
  row = data_lines(pin).map { |line| line.split("\t", -1) }.find { |fields| fields[0] == goos && fields[1] == goarch }
  fail!("no Go 1.27.0 authentication row for #{goos}/#{goarch}") unless row && row.length == 7
  _os, _arch, version, identity, expected_sha, = row
  fail!("toolchain pin version is #{version.inspect}, not go1.27.0") unless version == 'go1.27.0'
  candidate = if go.include?(File::SEPARATOR)
                go
              else
                ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, go) }.find { |path| File.executable?(path) }
              end
  real_go = File.realpath(candidate) rescue nil
  fail!("Go executable is missing: #{go}") unless real_go && File.executable?(real_go)
  result = invoke({ 'GOTOOLCHAIN' => 'local' }, [real_go, 'version'])
  actual_identity = result['stdout'].strip
  actual_sha = Digest::SHA256.file(real_go).hexdigest
  evidence(result.merge('phase' => 'go-authentication', 'go' => real_go, 'identity' => actual_identity, 'binary_sha256' => actual_sha))
  fail!("Go identity #{actual_identity.inspect}, expected #{identity.inspect}") unless actual_identity == identity
  fail!("Go binary digest #{actual_sha}, expected #{expected_sha}") unless actual_sha == expected_sha
  real_go
end

def cases
  result = []
  data_lines(File.join(ROOT, 'tests/bashsharp/matrix.tsv')).each do |line|
    family, _feature, _class, _cases, lowering = line.split("\t", -1)
    abort "PARITY FAIL: malformed Bash# matrix row #{line}" unless lowering&.match?(%r{\A[a-z-]+/lowering\.tsv\z})
    family_dir = File.join(ROOT, 'tests/bashsharp', File.dirname(lowering))
    data_lines(File.join(ROOT, 'tests/bashsharp', lowering)).each do |lowering_line|
      id, fixture, expectation, expected_rc, stdout, stderr = lowering_line.split("\t", -1)
      abort "PARITY FAIL: malformed lowering row #{lowering_line}" unless [id, fixture, expectation, expected_rc, stdout, stderr].all? && expectation.match?(/\A(run|reject)\z/)
      result << { family: family, id: id, fixture: fixture, expectation: expectation, expected_rc: Integer(expected_rc), stdout: stdout, stderr: stderr, dir: family_dir }
    end
  end
  abort 'PARITY FAIL: zero Bash# lowering cases' if result.empty?
  abort "PARITY FAIL: expected 33 Bash# lowering cases, found #{result.length}" unless result.length == 33
  abort 'PARITY FAIL: duplicate Bash# lowering case identity' unless result.map { |row| "#{row[:family]}/#{row[:id]}" }.uniq.length == result.length
  result
end

def expected(dir, token)
  return '' if token == 'empty'
  path = File.join(dir, token)
  abort "PARITY FAIL: missing expected result #{path}" unless File.file?(path)
  File.binread(path)
end

options = { case_filter: nil, bashy: ENV.fetch('BASHY_BIN', File.join(ROOT, '../bashy/bashy')), engine: ENV.fetch('BASH_ENGINE_BIN', File.join(ROOT, '../bashy/bin/bash')), go: ENV.fetch('GO_BIN', 'go') }
OptionParser.new do |parser|
  parser.on('--case FILTER', 'exact FAMILY/CASE or shell glob') { |value| options[:case_filter] = value }
  parser.on('--bashy PATH') { |value| options[:bashy] = value }
  parser.on('--engine PATH') { |value| options[:engine] = value }
  parser.on('--go PATH') { |value| options[:go] = value }
end.parse!
abort 'PARITY FAIL: unexpected arguments' unless ARGV.empty?

manifest = File.join(ROOT, 'tools/lowering/identity_manifest.rb')
manifest_result = invoke({}, [manifest])
evidence(manifest_result.merge('phase' => 'identity-manifest'))
fail!('identity manifest rejected') unless manifest_result['exit'] == 0
selected = cases.select { |row| options[:case_filter].nil? || row[:family] + '/' + row[:id] == options[:case_filter] || File.fnmatch?(options[:case_filter], row[:family] + '/' + row[:id]) }
fail!("case filter #{options[:case_filter].inspect} selected zero cases") if selected.empty?
go = authenticate_go(options[:go])
fail!("bashy transpiler is not executable: #{options[:bashy]}") unless File.executable?(options[:bashy])
fail!("Bash++ interpreter is not executable: #{options[:engine]}") unless File.executable?(options[:engine])

Dir.mktmpdir('s117-lowering-') do |tmp|
  selected.each do |row|
    label = "#{row[:family]}/#{row[:id]}"
    one = File.join(tmp, "#{row[:family]}-#{row[:id]}.one.go")
    two = File.join(tmp, "#{row[:family]}-#{row[:id]}.two.go")
    first = invoke({}, [options[:bashy], 'transpile', '--bashpp', row[:fixture], '-o', one], chdir: row[:dir])
    second = invoke({}, [options[:bashy], 'transpile', '--bashpp', row[:fixture], '-o', two], chdir: row[:dir])
    evidence(first.merge('phase' => 'transpile', 'case' => label, 'attempt' => 1))
    evidence(second.merge('phase' => 'transpile', 'case' => label, 'attempt' => 2))
    if row[:expectation] == 'reject'
      want_out, want_err = expected(row[:dir], row[:stdout]), expected(row[:dir], row[:stderr])
      fail!("#{label}: rejection exit changed") unless first['exit'] == row[:expected_rc] && second['exit'] == row[:expected_rc]
      fail!("#{label}: rejection diagnostic changed") unless first['stdout'] == want_out && first['stderr'] == want_err && first['stdout'] == second['stdout'] && first['stderr'] == second['stderr']
      fail!("#{label}: rejected source emitted Go") if File.size?(one) || File.size?(two)
      puts "PARITY PASS #{label}: deterministic rejection"
      next
    end
    fail!("#{label}: transpilation did not emit Go") unless first['exit'] == 0 && second['exit'] == 0 && File.size?(one) && File.size?(two)
    source_one, source_two = File.binread(one), File.binread(two)
    fail!("#{label}: generated Go is nondeterministic") unless source_one == source_two
    fail!("#{label}: generated source is not a Go main package") unless source_one.match?(/\A\s*package\s+main\b/)
    fail!("#{label}: generated source contains an interpreter wrapper") if source_one.match?(%r{os/exec|exec\.Command|/bin/(ba)?sh|--bashpp|\bbashy\b})
    binary = File.join(tmp, "#{row[:family]}-#{row[:id]}.bin")
    build = invoke({ 'GOTOOLCHAIN' => 'local' }, [go, 'build', '-o', binary, one])
    evidence(build.merge('phase' => 'build', 'case' => label, 'generated_go_sha256' => Digest::SHA256.hexdigest(source_one)))
    fail!("#{label}: generated Go did not build") unless build['exit'] == 0 && File.executable?(binary)
    interpreted = invoke({}, [options[:engine], '--bashpp', row[:fixture],], chdir: row[:dir])
    lowered = invoke({}, [binary])
    evidence(interpreted.merge('phase' => 'interpreted-run', 'case' => label))
    evidence(lowered.merge('phase' => 'compiled-run', 'case' => label, 'binary_sha256' => Digest::SHA256.file(binary).hexdigest))
    want_out, want_err = expected(row[:dir], row[:stdout]), expected(row[:dir], row[:stderr])
    fail!("#{label}: interpreter and compiled binary diverged") unless [interpreted['stdout'], interpreted['stderr'], interpreted['exit']] == [lowered['stdout'], lowered['stderr'], lowered['exit']]
    fail!("#{label}: compiled result missed fixture oracle") unless lowered['exit'] == row[:expected_rc] && lowered['stdout'] == want_out && lowered['stderr'] == want_err
    puts "PARITY PASS #{label}: transpile/build/run evidence authenticated"
  end
end
puts "PARITY PASS: #{selected.length}/#{cases.length} selected Bash# lowering cases"
