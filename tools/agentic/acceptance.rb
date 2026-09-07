#!/usr/bin/env ruby
# Bounded Sprint 134 product checks; no provider, compiler or foreign suite.
require 'open3'
require 'timeout'

root = File.expand_path('../..', __dir__)
fixtures = File.join(root, 'tests/agentic')
binary = File.expand_path(ENV.fetch('BASHY_BIN', File.join(root, '../bashy/bin/bash')))
oracle_candidates = ENV.key?('BASH53') ? [ENV.fetch('BASH53')] : ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'bash') }
oracle = oracle_candidates.map { |path| File.expand_path(path) }.uniq.find do |path|
  File.executable?(path) && Open3.capture2e(path, '--version').first.include?('version 5.3')
end
abort 'agentic: GNU Bash 5.3 not found on PATH; set BASH53=/path/to/bash' unless oracle
[binary, oracle].each { |path| abort "agentic: missing executable #{path}" unless File.executable?(path) }
rows = File.readlines(File.join(fixtures, 'cases.tsv'), chomp: true).reject { |line| line.empty? || line.start_with?('#') }.map { |line| line.split("\t", -1) }
abort 'agentic: expected 13 unique cases' unless rows.size == 13 && rows.map(&:first).uniq.size == 13
abort 'agentic: malformed case ledger' unless rows.all? { |row| row.size == 5 }
actual = Dir.glob(File.join(fixtures, '*.bpp')).map { |path| File.basename(path) }.sort
abort 'agentic: unlisted or missing fixture' unless actual == rows.map { |row| row[1] }.sort

executions = 0
run = lambda do |program, flags, entry, source, ambient, parse_only = false|
  env = {'BASHY_AGENTIC' => ambient, 'BASHY_HINTS' => 'off', 'BASHY_BASHPP' => nil, 'BASH_ENV' => nil, 'ENV' => nil}
  command = [program, *flags, *(parse_only ? ['-n'] : [])]
  text = File.binread(File.join(fixtures, source))
  input = ''
  case entry
  when 'file' then command += [source, 'input value']
  when 'stdin' then command += ['-s', '--', 'input value']; input = text
  when '-c' then command += ['-c', text, 'agentic-fixture', 'input value']
  end
  executions += 1
  # Bound each real process; kill the process group on timeout, including tools.
  Open3.popen3(env, *command, chdir: fixtures, pgroup: true) do |stdin, stdout, stderr, waiter|
    writer = Thread.new { begin stdin.write(input); rescue Errno::EPIPE; ensure stdin.close; end }
    out = Thread.new { stdout.read }
    err = Thread.new { stderr.read }
    begin
      Timeout.timeout(15) do
        status = waiter.value
        writer.join
        [out.value, err.value, status.exitstatus]
      end
    rescue Timeout::Error
      Process.kill('KILL', -waiter.pid) rescue Errno::ESRCH
      abort "agentic: timeout #{source}/#{entry}/#{flags.join(' ')}"
    end
  end
end

failures = []
rows.each do |id, source, expected_status, expected_stdout, expected_stderr|
  want_out = expected_stdout == 'empty' ? '' : File.binread(File.join(fixtures, expected_stdout))
  [nil, '1'].each do |ambient|
    %w[file stdin -c].each do |entry|
      label = "#{id}/#{entry}/BASHY_AGENTIC=#{ambient || 'unset'}"
      out, err, status = run.call(binary, ['--bashpp'], entry, source, ambient)
      status_ok = expected_status == 'nonzero' ? status && status != 0 : status == Integer(expected_status)
      stderr_ok = case expected_stderr
                  when 'empty' then err.empty?
                  when 'scope' then err.include?('agentic action requires an explicit agentic { ...; } scope')
                  when 'syntax' then err.match?(/syntax error|agentic.*(?:numeric|level)/i)
                  else false
                  end
      failures << "#{label}: exit=#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect}" unless status_ok && out == want_out && stderr_ok

      # Classic/POSIX parse verdicts come from the independent GNU oracle.
      # Only the compatibility case is executed in these modes: feature bodies
      # must never become accidental ordinary commands during this check.
      [[['--no-bashpp'], []], [['--posix', '--no-bashpp'], ['--posix']], [['--posix', '--bashpp'], []]].each do |flags, oracle_flags|
        parse_only = id != 'compatibility'
        got = run.call(binary, flags, entry, source, ambient, parse_only)
        ref = run.call(oracle, oracle_flags, entry, source, ambient, parse_only)
        equal = parse_only ? (got[2] == 0) == (ref[2] == 0) : got == ref
        failures << "#{label}/#{flags.join(' ')}: product=#{got.inspect}, GNU=#{ref.inspect}" unless equal
      end
    end
  end
  puts "agentic: checked #{id}"
end
abort failures.join("\n") unless failures.empty?
puts "agentic: PASS — #{rows.size} cases, #{executions} product/oracle executions; interpreted source contract only"
