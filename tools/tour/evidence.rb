#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'tempfile'

module TourEvidence
  SCHEMA = 'tour-evidence/v2'
  MODES = %w[baseline interpreted compiled].freeze
  STAGES = %w[transpile build run].freeze

  module_function

  def canonical(object)
    JSON.generate(deep_sort(object))
  end

  def deep_sort(object)
    case object
    when Hash then object.keys.sort.to_h { |key| [key, deep_sort(object[key])] }
    when Array then object.map { |value| deep_sort(value) }
    else object
    end
  end

  def sha(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def normalize(bytes, normalizer)
    out, err, status = Open3.capture3(RbConfig.ruby, normalizer, stdin_data: bytes, binmode: true)
    raise "normalizer wrote stderr: #{err}" unless err.empty?
    return { 'valid_utf8' => false, 'bytes' => nil, 'sha256' => nil, 'base64' => nil } unless status.success?
    { 'valid_utf8' => true, 'bytes' => out.bytesize, 'sha256' => sha(out), 'base64' => Base64.strict_encode64(out) }
  end

  # Every command gets a new process group. On deadline, and again after wait,
  # the entire group is swept so descendants cannot retain capture descriptors.
  def capture(argv, chdir:, timeout:, env: {})
    out = Tempfile.new('tour-out'); err = Tempfile.new('tour-err')
    out.binmode; err.binmode
    result = { 'spawned' => false, 'state' => 'launch_failure', 'exit' => nil }
    begin
      pid = Process.spawn(env, *argv, chdir: chdir, in: File::NULL, out: out, err: err, pgroup: true)
      result['spawned'] = true
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      status = nil
      until status
        waited, status = Process.waitpid2(pid, Process::WNOHANG)
        break if waited
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          result['state'] = 'deadline'
          begin Process.kill('TERM', -pid); rescue Errno::ESRCH; end
          sleep 0.1
          begin Process.kill('KILL', -pid); rescue Errno::ESRCH; end
          _, status = Process.waitpid2(pid)
          break
        end
        sleep 0.01
      end
      if result['state'] != 'deadline'
        result['state'] = 'exited'
        result['exit'] = status.exitstatus || 128 + status.termsig
      end
      begin Process.kill('KILL', -pid); rescue Errno::ESRCH; end
    rescue SystemCallError => e
      err.write("#{e.class}: #{e.message}\n")
    ensure
      out.flush; err.flush; out.rewind; err.rewind
      result['stdout'] = out.read.b
      result['stderr'] = err.read.b
      out.close!; err.close!
    end
    result
  end

  def derived(raw, normalizer)
    {
      'stdout' => normalize(raw.fetch('stdout'), normalizer),
      'stderr' => normalize(raw.fetch('stderr'), normalizer)
    }
  end

  def agent_banner?(raw)
    raw.fetch('stderr').match?(/^bashy: .* detected, and this repo has no agent config /)
  end

  def outcome(attempt, baseline = nil)
    return 'FAIL:launch_failure' unless attempt['spawned']
    return 'FAIL:deadline' if attempt['state'] == 'deadline'
    return "FAIL:exit:#{attempt['exit']}" unless attempt['exit'] == 0
    return 'FAIL:invalid_utf8' unless attempt.dig('normalized', 'stdout', 'valid_utf8') && attempt.dig('normalized', 'stderr', 'valid_utf8')
    if baseline && %w[stdout stderr].any? { |stream| attempt.dig('normalized', stream, 'sha256') != baseline.dig('normalized', stream, 'sha256') }
      return 'FAIL:mismatch'
    end
    'PASS'
  end

  def root(records)
    sha(records.map { |record| canonical(record) }.join("\n") + "\n")
  end

  # Command construction for the two single-shot modes. Shared by the runner
  # (which executes it) and the validator (which replays it independently) so
  # the two can never drift into checking a different command than the one
  # that actually ran.
  def command_for(mode, item, bashy:, go_bin:, local:)
    case mode
    when 'baseline'
      [go_bin, item['applicability'] == 'build_only_go_program' ? 'build' : 'run', local]
    when 'interpreted'
      [bashy, '--bashpp', *(item['applicability'] == 'build_only_go_program' ? ['-n'] : []), local]
    else
      raise ArgumentError, "command_for does not handle mode #{mode}"
    end
  end

  # Compiled mode is a three-stage pipeline: transpile the pinned Go source
  # with bashy, build the transpiled output with the exact pinned Go 1.27
  # toolchain, then execute the resulting binary. The recorded raw/state/exit
  # belong to whichever stage is authoritative: the first stage that fails to
  # produce its declared artifact, or — when every stage succeeds — the
  # executed binary itself. A "compiled" observation is therefore never just
  # the transpiler's own output; it is the real behavior of the program bashy
  # produced, exactly like the differential schema (`bpp_compiled:
  # transpile-build-run`) declares.
  def compiled_pipeline(bashy:, go_bin:, source:, module_dir:, workdir:, timeout:, env: {})
    base = File.basename(source, '.go')
    transpiled = File.join(workdir, "#{base}.transpiled.go")
    binary = File.join(workdir, "#{base}.bin")
    FileUtils.rm_f([transpiled, binary])
    command = {
      'transpile' => [bashy, 'transpile', source, '-o', transpiled],
      'build' => [go_bin, 'build', '-o', binary, transpiled],
      'run' => [binary]
    }

    transpile_raw = capture(command['transpile'], chdir: module_dir, timeout: timeout, env: env)
    unless transpile_raw['spawned'] && transpile_raw['state'] == 'exited' && transpile_raw['exit'] == 0 && File.file?(transpiled)
      return { 'command' => command, 'stage' => 'transpile', 'raw' => transpile_raw }
    end

    build_raw = capture(command['build'], chdir: module_dir, timeout: timeout, env: env.merge('GOTOOLCHAIN' => 'local'))
    unless build_raw['spawned'] && build_raw['state'] == 'exited' && build_raw['exit'] == 0 && File.executable?(binary)
      return { 'command' => command, 'stage' => 'build', 'raw' => build_raw }
    end

    run_raw = capture(command['run'], chdir: module_dir, timeout: timeout, env: {})
    { 'command' => command, 'stage' => 'run', 'raw' => run_raw }
  end

  # Materializes the same scratch module (go.mod/go.sum for the pinned
  # helper, every pinned tour source copied and byte/sha verified) that a
  # run needs. Used both to produce evidence and to replay it, so a replay
  # executes against an identically-constructed tree.
  def materialize_module(mod_dir, tour_root:, inventory:, go_version:, helper:)
    FileUtils.mkdir_p(mod_dir)
    File.write(File.join(mod_dir, 'go.mod'), "module tour.evidence.local\n\ngo #{go_version.delete_prefix('go')}\n\nrequire #{helper[0]} #{helper[1]}\n")
    File.write(File.join(mod_dir, 'go.sum'), "#{helper[0]} #{helper[1]} #{helper[4]}\n#{helper[0]} #{helper[1]}/go.mod #{helper[3]}\n")
    # Published Bashy 0.20 predates BASHY_HINTS suppression for its one-time
    # startup advertisement. A deterministic agent-config marker prevents that
    # provenance-neutral, driver-specific line from entering evidence. It is
    # not Go source and does not alter any program under test.
    File.write(File.join(mod_dir, 'AGENTS.md'), "# Hermetic Tour evidence workspace\n")
    File.chmod(0o444, File.join(mod_dir, 'AGENTS.md'))
    license_source = File.join(tour_root, 'LICENSE')
    raise "missing upstream LICENSE #{license_source}" unless File.file?(license_source)
    license_bytes = File.binread(license_source)
    license_local = File.join(mod_dir, 'LICENSE')
    File.binwrite(license_local, license_bytes)
    File.chmod(0o444, license_local)
    inventory.each do |item|
      source = File.join(tour_root, item['path'])
      raise "missing source #{source}" unless File.file?(source)
      raise "source mode is not read-only 444: #{item['path']}" unless File.stat(source).mode & 0o777 == 0o444
      bytes = File.binread(source)
      raise "source pin mismatch #{item['path']}" unless bytes.bytesize == item['bytes'] && sha(bytes) == item['sha256']
      local = File.join(mod_dir, item['path'])
      FileUtils.mkdir_p(File.dirname(local))
      File.binwrite(local, bytes)
      File.chmod(0o444, local)
    end
  end

  # Parses `bashy --version`-style output (e.g.
  # "bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-0.20.0" for a
  # published release, or "...-bashy-dev (da8deb9-dirty)" for a workspace
  # build) into a provenance identity that can be independently
  # re-derived — never trusted as free-form text. A dev build (published:
  # false) or a dirty tree (dirty: true) cannot satisfy the "clean published
  # reproducible" requirement, whatever the manifest claims about them.
  def bashy_identity(version_line)
    m = version_line.to_s.match(/-bashy-(dev|\d[\w.]*)(?:\s+\(([0-9a-f]{7,40})(-dirty)?\))?\z/)
    return { 'revision' => nil, 'published' => false, 'dirty' => true } unless m
    tag, commit, dirty_suffix = m[1], m[2], m[3]
    if tag == 'dev'
      { 'revision' => commit, 'published' => false, 'dirty' => true }
    else
      { 'revision' => tag, 'published' => true, 'dirty' => !dirty_suffix.nil? }
    end
  end
end
