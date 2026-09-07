#!/usr/bin/env ruby
# Sprint: #117
# Story: #9
# Story-ID: e400885f8746
#
# Generalized Go-profile differential lowering runner.
#
# Authenticates that a Bash++ fixture executed by the interpreter and the same
# fixture lowered to Go, compiled by the pinned Go 1.27.0 toolchain and executed
# as a source-absent native artifact, agree on stdout bytes, stderr bytes, the
# numeric exit status, and the observable filesystem effects of the run.
#
# This runner makes no language-conformance claim. It authenticates evidence.
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

# --- contract constants -----------------------------------------------------

# Exact manifest header. Seven columns, expected_status is the numeric exit
# code, stdout/stderr are JSON string literals.
EXPECTED_HEADER = "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref".freeze
MANIFEST_COLUMNS = 7

# Source map artifact emitted by `bashy transpile`. Schema and field names are
# fixed by the public CLI (bashy agentos transpile).
MAP_SCHEMA = 'bashy-transpile-map-v1'.freeze
MAP_TOP_KEYS = %w[schema_version origin go_digest mappings].freeze
MAP_ENTRY_KEYS = %w[go_line go_col source_line source_col source_offset node].freeze

# Import prefixes the typed-only profile allows beyond the Go standard library.
# `mvdan.cc/sh/v3/lower/shellrt` is the typed lowering bridge runtime; it is
# itself stdlib-only and contains no interpreter.
TYPED_ONLY_ALLOWED_PREFIXES = ['mvdan.cc/sh/v3/lower/shellrt'].freeze

# Packages that would let a "compiled" artifact re-enter a shell interpreter or
# spawn one. Rejected anywhere in the transitive dependency set under
# --typed-only. Determined from `go list`, i.e. from the Go toolchain's own
# parser, never from a textual scan of the generated source.
TYPED_ONLY_FORBIDDEN_DEPS = %w[
  os/exec
  plugin
  mvdan.cc/sh/v3/interp
  mvdan.cc/sh/v3/syntax
  mvdan.cc/sh/v3/expand
  mvdan.cc/sh/v3/pattern
].freeze

# Runtime scaffolding placed INSIDE each execution root so that HOME and TMPDIR
# writes are observable, at identical relative paths in both modes.
RUNTIME_DIR = '.bashpp-run'.freeze

# The only fixture-root-relative path that is exempt from the effect diff, and
# only for the compiled mode: the original Bash++ source is deleted before the
# native artifact runs, to prove the artifact does not read it back.
def compiled_only_ignored_paths(fixture)
  [fixture]
end

DEFAULT_TIMEOUT = 60
DRAIN_GRACE = 2.0       # let an owned process group finish this long after the leader exits
FINAL_DRAIN = 0.5       # keep reading this long after killing the process group
KILL_GRACE = 0.25       # TERM -> KILL escalation window, bounded and targeted
GROUP_REAP_GRACE = 2.0  # bounded wait for an owned process group to become empty

# How a subprocess's whole process tree ended. Only CLEAN is acceptable: it is
# the only outcome in which the runner observed the tree to completion. Every
# other outcome means the runner had to cut a still-live process short, so the
# streams and the filesystem snapshot that follow are truncated and cannot be
# offered as parity evidence.
LIFECYCLE_CLEAN = 'clean'.freeze
LIFECYCLE_TIMEOUT = 'timeout'.freeze
LIFECYCLE_OUTLIVED = 'group-outlived-drain'.freeze
LIFECYCLE_UNREAPABLE = 'group-unreapable'.freeze

LIFECYCLE_REASONS = {
  LIFECYCLE_TIMEOUT => 'timed out and its process group was killed',
  LIFECYCLE_OUTLIVED => 'left a process alive in its own process group after the leader exited; ' \
                        'the runner killed the group, so the observed streams and effects are truncated',
  LIFECYCLE_UNREAPABLE => 'left a process group that could not be reaped'
}.freeze

# --- compiler phase contract -------------------------------------------------

# The phase metadata pairs every identity in the default inventory with the
# compiler phase that identity is contracted to reach. It is owned by the
# coverage worker; this runner only reads and enforces it.
EXPECTED_PHASE_HEADER = "id\tphase\tsource_sha256\treason\tpublic_test_ref".freeze
PHASE_COLUMNS = 5

PHASE_ARTIFACT_RUN = 'artifact-run'.freeze
PHASE_SEMANTIC_REJECT = 'semantic-reject'.freeze
KNOWN_PHASES = [PHASE_ARTIFACT_RUN, PHASE_SEMANTIC_REJECT].freeze

# The pinned split of the default 120-case inventory. A changed split is a
# changed contract and fails closed.
DEFAULT_PHASE_SPLIT = { PHASE_ARTIFACT_RUN => 105, PHASE_SEMANTIC_REJECT => 15 }.freeze

# A semantic diagnostic is a rendered Bash++ diagnostic identity, optionally
# positioned by the ORIGINAL source path and line. The path is compared against
# the real fixture path: a rendering that normalizes the origin away would hide
# a diagnostic pointing at the wrong file or line, so it is not accepted.
SEMANTIC_DIAGNOSTIC_LINE = /\A(?:(?<path>[^\s:]+): line (?<line>\d+): )?BASHPP-E[A-Z0-9]+(?:-[A-Z0-9]+)*: \S.*\z/.freeze

# Renderings pinned by a public test that predate the BASHPP- identity scheme.
# Allowed for these exact identities and these exact bytes only.
LEGACY_DIAGNOSTIC_ALLOWLIST = {
  'undefined-receiver-neg' => "invalid receiver type Missing (type is not declared in this session)\n"
}.freeze

# Shapes that are never a semantic diagnostic, however non-zero the status: an
# unsupported-construct bail-out, a raw Go type-check failure, or a bare
# line:col position from the lowering type checker. Accepting any of these as a
# negative result would let "the transpiler refused, somehow" masquerade as
# "the transpiler produced the contracted diagnostic".
NON_SEMANTIC_DIAGNOSTIC_MARKERS = {
  'a LOWER-E* lowering error' => /\bLOWER-E[A-Z]+/,
  'a raw Go toolchain error' => /^# command-line-arguments|\.go:\d+:\d+:/,
  'a bare line:col type-check position' => /^\d+:\d+: /
}.freeze

# The default phase contract, owned by the coverage worker. A default inventory
# manifest cannot be run without it.
DEFAULT_PHASES = File.join(ROOT, 'docs/lowering/go-profile-phases.tsv').freeze

# The repository inventory this runner is contracted to support.
DEFAULT_INVENTORY = [
  ['docs/lowering/go-profile-cases.tsv', 'tests/lowering/go-profile'],
  ['docs/lowering/profile-additional.tsv', 'tests/lowering/profile-additional']
].freeze

class CaseFailure < StandardError; end
class PreflightFailure < StandardError; end

def preflight!(message)
  raise PreflightFailure, message
end

# --- process control --------------------------------------------------------

# Is the owned process group still non-empty?
#
# Signal 0 to a negative pid probes the process group without delivering
# anything. This is the only reliable liveness question: pipe EOF does NOT mean
# the tree is gone, because a descendant can close or redirect the inherited
# descriptors and keep running -- and keep writing to the execution root long
# after the runner would otherwise have snapshotted it.
def group_alive?(pgid)
  return false if pgid.nil? || pgid <= 0
  Process.kill(0, -pgid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
rescue StandardError
  false
end

# Bounded wait for an owned process group to become empty.
def wait_group_empty(pgid, grace)
  deadline = Time.now + grace
  loop do
    return true unless group_alive?(pgid)
    return false if Time.now >= deadline
    IO.select(nil, nil, nil, 0.02)
  end
end

# Terminate the process group whose group id is `pgid`.
#
# Safety: this is only ever called with the pgid of a group this runner created
# (pgroup: true makes the spawned leader its own group leader, so pgid == leader
# pid), and only after group_alive? has confirmed the group is non-empty. A
# process group id cannot be recycled while the group still has members, so this
# can never signal an unrelated process. No pgrep, no ps, no global scan.
def kill_group(pgid)
  return false if pgid.nil? || pgid <= 0
  return false unless group_alive?(pgid)
  begin
    Process.kill('-TERM', pgid)
  rescue StandardError
    nil
  end
  wait_group_empty(pgid, KILL_GRACE)
  if group_alive?(pgid)
    begin
      Process.kill('-KILL', pgid)
    rescue StandardError
      nil
    end
  end
  true
end

# Run argv with a fully explicit environment, in its own process group, and
# observe its whole process tree to completion.
#
# Guarantees:
#   * the child never inherits this runner's environment (unsetenv_others)
#   * whatever bytes were produced before a kill are retained (partial streams)
#   * the call does not return while a process this runner spawned is still
#     alive in its own process group -- pipe EOF is not accepted as proof of
#     death, because a descendant can close the inherited descriptors and keep
#     running. Liveness is probed on the group itself.
#   * if the runner ever has to cut a live process short -- a timeout, or a
#     group that outlived the drain grace -- it says so in `lifecycle`, and the
#     caller must fail the case. A truncated observation is never parity
#     evidence, however clean the bytes that did arrive look.
def invoke_subprocess(env, argv, chdir: ROOT, timeout: DEFAULT_TIMEOUT, drain_grace: DRAIN_GRACE)
  out_buf = String.new.force_encoding('BINARY')
  err_buf = String.new.force_encoding('BINARY')
  lifecycle = LIFECYCLE_CLEAN
  group_killed = false
  status = nil
  started = Time.now

  Open3.popen3(env, *argv, chdir: chdir, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    pgid = wait_thr.pid
    pipes = { stdout => out_buf, stderr => err_buf }
    hard_deadline = started + timeout
    group_deadline = nil
    final_deadline = nil
    reaped = nil

    loop do
      if reaped.nil? && wait_thr.join(0)
        reaped = wait_thr.value
        group_deadline = Time.now + drain_grace
      end
      now = Time.now

      if final_deadline.nil? && reaped.nil? && now >= hard_deadline
        lifecycle = LIFECYCLE_TIMEOUT
        group_killed = kill_group(pgid) || group_killed
        final_deadline = Time.now + FINAL_DRAIN
      end

      if final_deadline.nil? && reaped
        # The leader is gone. The tree is only finished when every pipe has
        # closed AND the process group is empty. Either one alone is a lie.
        outstanding = !pipes.empty? || group_alive?(pgid)
        if !outstanding
          break
        elsif now >= group_deadline
          lifecycle = LIFECYCLE_OUTLIVED
          group_killed = kill_group(pgid) || group_killed
          final_deadline = Time.now + FINAL_DRAIN
        end
      end

      break if final_deadline && Time.now >= final_deadline

      if pipes.empty?
        if reaped
          IO.select(nil, nil, nil, 0.02)
        else
          wait_thr.join(0.05)
        end
        next
      end

      slice = 0.05
      [hard_deadline, group_deadline, final_deadline].compact.each do |deadline|
        remaining = deadline - Time.now
        slice = remaining if remaining > 0 && remaining < slice
      end
      slice = 0.01 if slice <= 0

      ready = IO.select(pipes.keys, nil, nil, slice)
      next unless ready
      ready[0].each do |io|
        begin
          pipes[io] << io.read_nonblock(65_536)
        rescue IO::WaitReadable
          next
        rescue EOFError, IOError, Errno::EIO, Errno::EBADF
          pipes.delete(io)
          begin
            io.close unless io.closed?
          rescue StandardError
            nil
          end
        end
      end
    end

    if reaped.nil?
      lifecycle = LIFECYCLE_TIMEOUT if lifecycle == LIFECYCLE_CLEAN
      group_killed = kill_group(pgid) || group_killed
      reaped = wait_thr.value
    end
    status = reaped

    # Nothing this runner spawned may still be running when this returns. If
    # the group is still alive here, the loop above left it that way, so the
    # observation is truncated by definition.
    if group_alive?(pgid)
      lifecycle = LIFECYCLE_OUTLIVED if lifecycle == LIFECYCLE_CLEAN
      group_killed = kill_group(pgid) || group_killed
      lifecycle = LIFECYCLE_UNREAPABLE unless wait_group_empty(pgid, GROUP_REAP_GRACE)
    end
  end

  timed_out = lifecycle == LIFECYCLE_TIMEOUT
  exit_code =
    if timed_out
      124
    elsif status.exitstatus
      status.exitstatus
    elsif status.termsig
      128 + status.termsig
    else
      1
    end

  {
    'argv' => argv,
    'cwd' => chdir,
    'exit' => exit_code,
    'timeout' => timed_out,
    'lifecycle' => lifecycle,
    'lifecycle_clean' => lifecycle == LIFECYCLE_CLEAN,
    'group_killed' => group_killed,
    'duration_ms' => ((Time.now - started) * 1000).round,
    'stdout_bytes' => out_buf.bytesize,
    'stderr_bytes' => err_buf.bytesize,
    'stdout_sha256' => Digest::SHA256.hexdigest(out_buf),
    'stderr_sha256' => Digest::SHA256.hexdigest(err_buf),
    'stdout' => out_buf,
    'stderr' => err_buf
  }
end

# --- evidence ---------------------------------------------------------------

# Always retains the raw byte streams, at every phase, including partial streams
# from a timed-out or drain-killed process. Raw artifacts live in the case
# evidence directory, which is OUTSIDE every execution root.
def evidence(record, case_dir: nil, ledger: nil, name: nil)
  if name && case_dir && File.directory?(case_dir)
    File.binwrite(File.join(case_dir, "#{name}.stdout.raw"), record['stdout'] || '')
    File.binwrite(File.join(case_dir, "#{name}.stderr.raw"), record['stderr'] || '')
  end
  line = JSON.generate(record.reject { |key, _| %w[stdout stderr].include?(key) })
  puts line
  File.open(ledger, 'a') { |file| file.puts(line) } if ledger
  line
end

def data_lines(path)
  preflight!("missing data file #{path}") unless File.file?(path) && !File.symlink?(path)
  File.readlines(path, chomp: true)
end

# --- toolchain authentication ----------------------------------------------

def host_platform
  os = RbConfig::CONFIG.fetch('host_os')
  goos = os.include?('darwin') ? 'darwin' : os.include?('linux') ? 'linux' : os
  cpu = RbConfig::CONFIG.fetch('host_cpu')
  goarch = %w[arm64 aarch64].include?(cpu) ? 'arm64' : cpu == 'x86_64' ? 'amd64' : cpu
  [goos, goarch]
end

TOOLCHAIN_TSV = 'docs/tour/toolchain.tsv'.freeze
TOOLCHAIN_COLUMNS = 7
PINNED_GO_VERSION = 'go1.27.0'.freeze

# Authenticate the Go binary against the exact pinned row in docs/tour/toolchain.tsv:
# exact version coordinate, exact `go version` identity string, and SHA-256 of
# the executing binary. A host without a row is unsupported, not degraded.
def authenticate_go(go)
  goos, goarch = host_platform
  rows = data_lines(File.join(ROOT, TOOLCHAIN_TSV))
             .reject { |line| line.strip.empty? || line.start_with?('#') }
             .map { |line| line.split("\t", -1) }
  row = rows.find { |fields| fields[0] == goos && fields[1] == goarch }
  preflight!("no pinned Go toolchain row for #{goos}/#{goarch} in #{TOOLCHAIN_TSV}") unless row
  preflight!("toolchain row for #{goos}/#{goarch} has #{row.length} columns, expected #{TOOLCHAIN_COLUMNS}") unless row.length == TOOLCHAIN_COLUMNS
  _goos, _goarch, version, identity, expected_sha, acquisition, provenance = row
  preflight!("toolchain pin version is #{version.inspect}, not #{PINNED_GO_VERSION}") unless version == PINNED_GO_VERSION
  preflight!('toolchain pin identity is empty') if identity.to_s.strip.empty?
  preflight!('toolchain pin digest is not a sha256 hex digest') unless expected_sha.to_s.match?(/\A[0-9a-f]{64}\z/)
  preflight!('toolchain pin acquisition is empty') if acquisition.to_s.strip.empty?
  preflight!('toolchain pin provenance is empty') if provenance.to_s.strip.empty?

  candidate =
    if go.include?(File::SEPARATOR)
      go
    else
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
         .map { |dir| File.join(dir, go) }.find { |path| File.executable?(path) }
    end
  real_go = (File.realpath(candidate) rescue nil) if candidate
  preflight!("Go executable is missing: #{go}") unless real_go && File.executable?(real_go) && File.file?(real_go)

  result = invoke_subprocess(
    { 'GOTOOLCHAIN' => 'local', 'HOME' => Dir.tmpdir, 'PATH' => File.dirname(real_go) },
    [real_go, 'version'], chdir: ROOT, timeout: 30
  )
  preflight!("`go version` failed with exit #{result['exit']}") unless result['exit'].zero?
  actual_identity = result['stdout'].strip
  actual_sha = Digest::SHA256.file(real_go).hexdigest
  preflight!("Go identity #{actual_identity.inspect}, expected #{identity.inspect}") unless actual_identity == identity
  preflight!("Go binary digest #{actual_sha}, expected #{expected_sha}") unless actual_sha == expected_sha
  { 'bin' => real_go, 'identity' => identity, 'sha256' => actual_sha, 'version' => version,
    'goos' => goos, 'goarch' => goarch }
end

def resolve_pinned_go
  out, err, status = Open3.capture3({ 'GOTOOLCHAIN' => PINNED_GO_VERSION }, 'go', 'env', 'GOROOT')
  preflight!("GOTOOLCHAIN=#{PINNED_GO_VERSION} could not resolve Go: #{err.strip}") unless status.success? && !out.strip.empty?
  File.join(out.strip, 'bin', 'go')
end

# --- manifest ---------------------------------------------------------------

def decode_stream(value, column, id)
  preflight!("case #{id}: #{column} column must be a JSON string literal, got #{value.inspect}") unless value.start_with?('"') && value.end_with?('"') && value.length >= 2
  parsed = JSON.parse(value) rescue nil
  preflight!("case #{id}: #{column} column is not valid JSON, got #{value.inspect}") unless parsed.is_a?(String)
  parsed.dup.force_encoding('BINARY')
end

# Load and fully validate a seven-column numeric-status manifest against its
# fixture root. Every check here is fail-closed and runs before any case does.
def load_cases(manifest_path, fixture_root)
  preflight!("fixture root is not a directory: #{fixture_root}") unless File.directory?(fixture_root)
  real_root = File.realpath(fixture_root)
  rows = []
  header_found = false

  data_lines(manifest_path).each_with_index do |line, index|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?('#')

    unless header_found
      preflight!("#{manifest_path}: header mismatch, expected #{EXPECTED_HEADER.inspect}, got #{line.inspect}") unless line == EXPECTED_HEADER
      header_found = true
      next
    end

    fields = line.split("\t", -1)
    preflight!("#{manifest_path}:#{index + 1}: expected #{MANIFEST_COLUMNS} tab-separated fields, got #{fields.length}") unless fields.length == MANIFEST_COLUMNS
    id, category, fixture, status_text, stdout_text, stderr_text, public_test_ref = fields

    preflight!("#{manifest_path}:#{index + 1}: invalid id #{id.inspect}") unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
    preflight!("#{manifest_path}:#{index + 1}: invalid category #{category.inspect}") unless category.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
    preflight!("#{manifest_path}:#{index + 1}: public_test_ref must be non-empty") if public_test_ref.to_s.strip.empty?
    preflight!("#{manifest_path}:#{index + 1}: public_test_ref must not carry surrounding whitespace") unless public_test_ref == public_test_ref.strip

    preflight!("#{manifest_path}:#{index + 1}: fixture path must be relative and contained: #{fixture.inspect}") if fixture.empty? || fixture.start_with?('/') || fixture.split('/').include?('..') || fixture.split('/').include?('.')
    preflight!("#{manifest_path}:#{index + 1}: fixture must be a .bpp source: #{fixture.inspect}") unless fixture.end_with?('.bpp')
    preflight!("#{manifest_path}:#{index + 1}: fixture must not live under the reserved runtime path #{RUNTIME_DIR}") if fixture.split('/').first == RUNTIME_DIR

    absolute = File.join(fixture_root, fixture)
    preflight!("#{manifest_path}:#{index + 1}: missing fixture on disk: #{absolute}") unless File.file?(absolute)
    real_fixture = File.realpath(absolute) rescue nil
    preflight!("#{manifest_path}:#{index + 1}: fixture realpath escapes the fixture root: #{fixture.inspect}") unless real_fixture && real_fixture.start_with?(real_root + File::SEPARATOR)

    expected_status = (Integer(status_text, 10) rescue nil)
    preflight!("#{manifest_path}:#{index + 1}: expected_status must be a decimal integer 0..255, got #{status_text.inspect}") unless expected_status && expected_status.between?(0, 255)

    rows << {
      id: id,
      category: category,
      fixture: fixture,
      expected_status: expected_status,
      stdout: decode_stream(stdout_text, 'stdout', id),
      stderr: decode_stream(stderr_text, 'stderr', id),
      public_test_ref: public_test_ref,
      manifest: manifest_path,
      fixture_root: fixture_root
    }
  end

  preflight!("#{manifest_path}: manifest has no header row") unless header_found
  preflight!("#{manifest_path}: manifest declares zero cases") if rows.empty?
  seen = Hash.new(0)
  rows.each { |row| seen[row[:id]] += 1 }
  duplicates = seen.select { |_, count| count > 1 }.keys
  preflight!("#{manifest_path}: duplicate case ids #{duplicates.inspect}") unless duplicates.empty?

  on_disk = []
  Find.find(fixture_root) do |path|
    next unless File.file?(path)
    next unless path.end_with?('.bpp')
    on_disk << path.sub(%r{\A#{Regexp.escape(fixture_root)}/?}, '')
  end
  declared = rows.map { |row| row[:fixture] }
  unlisted = (on_disk - declared).sort
  preflight!("#{manifest_path}: .bpp fixtures on disk are absent from the manifest: #{unlisted.inspect}") unless unlisted.empty?

  rows
end

# Load and validate the phase contract as a standalone document.
def load_phases(path)
  rows = {}
  header_found = false
  data_lines(path).each_with_index do |line, index|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?('#')

    unless header_found
      preflight!("#{path}: phase header mismatch, expected #{EXPECTED_PHASE_HEADER.inspect}, got #{line.inspect}") unless line == EXPECTED_PHASE_HEADER
      header_found = true
      next
    end

    fields = line.split("\t", -1)
    preflight!("#{path}:#{index + 1}: expected #{PHASE_COLUMNS} tab-separated fields, got #{fields.length}") unless fields.length == PHASE_COLUMNS
    id, phase, source_sha256, reason, public_test_ref = fields

    preflight!("#{path}:#{index + 1}: invalid id #{id.inspect}") unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
    preflight!("#{path}:#{index + 1}: unknown phase #{phase.inspect}, expected one of #{KNOWN_PHASES.inspect}") unless KNOWN_PHASES.include?(phase)
    preflight!("#{path}:#{index + 1}: source_sha256 must be a sha256 hex digest, got #{source_sha256.inspect}") unless source_sha256.match?(/\A[0-9a-f]{64}\z/)
    preflight!("#{path}:#{index + 1}: reason must be non-empty") if reason.to_s.strip.empty?
    preflight!("#{path}:#{index + 1}: public_test_ref must be non-empty") if public_test_ref.to_s.strip.empty?
    preflight!("#{path}:#{index + 1}: public_test_ref must not carry surrounding whitespace") unless public_test_ref == public_test_ref.strip
    preflight!("#{path}: duplicate phase entry for id #{id.inspect}") if rows.key?(id)

    rows[id] = { id: id, phase: phase, source_sha256: source_sha256, reason: reason, public_test_ref: public_test_ref }
  end

  preflight!("#{path}: phase contract has no header row") unless header_found
  preflight!("#{path}: phase contract declares zero identities") if rows.empty?
  rows
end

# Bind the phase contract to the manifest it governs: exactly one entry per
# identity, both ways, with the source bytes and the public reference pinned.
# Nothing here tolerates an extra, a duplicate, a gap or a drift.
def bind_phases!(cases, phases, phase_path, manifest_path, enforce_default_split)
  case_ids = cases.map { |row| row[:id] }
  missing = (case_ids - phases.keys).sort
  preflight!("#{phase_path}: no phase declared for #{missing.length} manifest identities: #{missing.first(8).inspect}") unless missing.empty?
  unknown = (phases.keys - case_ids).sort
  preflight!("#{phase_path}: phase contract declares #{unknown.length} identities absent from #{manifest_path}: #{unknown.first(8).inspect}") unless unknown.empty?

  cases.each do |row|
    entry = phases.fetch(row[:id])
    actual = Digest::SHA256.file(File.join(row[:fixture_root], row[:fixture])).hexdigest
    preflight!("#{phase_path}: #{row[:id]} source_sha256 #{entry[:source_sha256]} does not match #{row[:fixture]} (#{actual}); the phase contract and the fixture have diverged") unless entry[:source_sha256] == actual
    preflight!("#{phase_path}: #{row[:id]} public_test_ref #{entry[:public_test_ref].inspect} does not match the manifest reference #{row[:public_test_ref].inspect}") unless entry[:public_test_ref] == row[:public_test_ref]
    row[:phase] = entry[:phase]
    row[:phase_reason] = entry[:reason]
  end

  counts = Hash.new(0)
  cases.each { |row| counts[row[:phase]] += 1 }
  if enforce_default_split
    KNOWN_PHASES.each do |phase|
      expected = DEFAULT_PHASE_SPLIT.fetch(phase)
      preflight!("#{phase_path}: default inventory declares #{counts[phase]} #{phase} identities, the pinned contract is #{expected}") unless counts[phase] == expected
    end
  end
  counts
end

# Is this stderr the contracted semantic diagnostic rendering, rather than some
# other reason the transpiler happened to exit non-zero?
def semantic_diagnostic_problems(text, id, fixture)
  legacy = LEGACY_DIAGNOSTIC_ALLOWLIST[id]
  return [] if legacy && text == legacy

  problems = []
  NON_SEMANTIC_DIAGNOSTIC_MARKERS.each do |description, pattern|
    problems << "the diagnostic is #{description}" if pattern.match?(text)
  end
  return problems unless problems.empty?

  return ['the diagnostic is empty'] if text.strip.empty?

  text.split("\n", -1).each_with_index do |line, index|
    next if line.empty?
    match = SEMANTIC_DIAGNOSTIC_LINE.match(line)
    if match.nil?
      problems << "line #{index + 1} is not a rendered BASHPP diagnostic: #{line.inspect}"
      next
    end
    next if match[:path].nil?
    problems << "line #{index + 1} is positioned at #{match[:path].inspect}, not at the original source #{fixture.inspect}" unless match[:path] == fixture
  end
  problems
end

# --- filesystem effects -----------------------------------------------------

def copy_tree(source, destination)
  FileUtils.mkdir_p(destination)
  Dir.children(source).each do |entry|
    next if %w[.git .agents].include?(entry)
    FileUtils.cp_r(File.join(source, entry), destination, preserve: true)
  end
end

# Content-addressed snapshot of an execution root.
#
# Nothing is ignored except the paths explicitly passed in `ignored`, which is
# empty for the interpreted mode and exactly the deleted original source for the
# compiled mode. Files whose names end in `.raw`, dotfiles, and the HOME/TMPDIR
# scaffolding under RUNTIME_DIR are all included, so a fixture that writes to
# $HOME, $TMPDIR, or a file called `evidence.raw` is compared, not excused.
def filesystem_snapshot(root, ignored = [])
  entries = []
  Find.find(root) do |path|
    relative = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
    next if relative.empty?
    next if ignored.any? { |ig| relative == ig || relative.start_with?("#{ig}/") }
    stat = File.lstat(path)
    kind = stat.symlink? ? 'symlink' : stat.directory? ? 'directory' : stat.file? ? 'file' : 'other'
    content =
      if stat.symlink?
        File.readlink(path)
      elsif stat.file?
        Digest::SHA256.file(path).hexdigest
      else
        ''
      end
    size = stat.file? ? stat.size : -1
    entries << [relative, kind, stat.mode & 0o7777, size, content]
  end
  entries.sort!
  { 'sha256' => Digest::SHA256.hexdigest(JSON.generate(entries)), 'count' => entries.length, 'entries' => entries }
end

def snapshot_public(snapshot)
  { 'sha256' => snapshot['sha256'], 'count' => snapshot['count'] }
end

# View of a snapshot with the given root-relative paths removed. Used only to
# make the two modes comparable across the one path that cannot exist in both:
# the original Bash++ source, deleted before the compiled artifact runs. The
# unfiltered snapshot is what gets recorded as evidence.
def snapshot_reject(snapshot, ignored)
  return snapshot if ignored.empty?
  entries = snapshot['entries'].reject do |entry|
    ignored.any? { |ig| entry[0] == ig || entry[0].start_with?("#{ig}/") }
  end
  { 'sha256' => Digest::SHA256.hexdigest(JSON.generate(entries)), 'count' => entries.length, 'entries' => entries }
end

def snapshot_entry(snapshot, relative)
  snapshot['entries'].find { |entry| entry[0] == relative }
end

def snapshot_under(snapshot, prefix)
  snapshot['entries'].select { |entry| entry[0] == prefix || entry[0].start_with?("#{prefix}/") }
end

# The one path that cannot be diffed between the modes is the original Bash++
# source, because the compiled artifact runs with it deliberately deleted. That
# is not a licence to stop looking at it: a blanket ignore also hides a compiled
# artifact that RECREATES or rewrites the source path, and an interpreted run
# that rewrites its own source.
#
# So instead of excusing the path, its state is pinned explicitly at both ends
# in both modes. Only once each of those transitions is asserted is the path
# normalized out of the general effect diff.
def source_path_problems(fixture, before_interpreted, after_interpreted, before_compiled, after_compiled)
  problems = []

  original = snapshot_entry(before_interpreted, fixture)
  if original.nil?
    problems << "the interpreted execution root did not contain the original source #{fixture} before the run"
  else
    final = snapshot_entry(after_interpreted, fixture)
    if final.nil?
      problems << "the interpreted run deleted its own source #{fixture}"
    elsif final != original
      problems << "the interpreted run modified its own source #{fixture} (#{original[1..-1].inspect} -> #{final[1..-1].inspect})"
    end
  end

  stale = snapshot_under(before_compiled, fixture)
  problems << "the compiled execution root still held the original source path before the run: #{stale.map(&:first).inspect}" unless stale.empty?

  recreated = snapshot_under(after_compiled, fixture)
  unless recreated.empty?
    problems << "the compiled artifact recreated or wrote the deliberately absent source path: #{recreated.map(&:first).inspect}"
  end

  problems
end

def snapshot_diff(left, right, limit = 12)
  left_map = left['entries'].to_h { |entry| [entry[0], entry[1..]] }
  right_map = right['entries'].to_h { |entry| [entry[0], entry[1..]] }
  diffs = []
  (left_map.keys | right_map.keys).sort.each do |key|
    next if left_map[key] == right_map[key]
    diffs << "#{key}: interpreted=#{left_map[key].inspect} compiled=#{right_map[key].inspect}"
    break if diffs.length >= limit
  end
  diffs
end

# --- execution environment --------------------------------------------------

def prepare_execution_root(fixture_root, destination)
  copy_tree(fixture_root, destination)
  preflight!("fixture root already contains the reserved runtime path #{RUNTIME_DIR}") if File.exist?(File.join(destination, RUNTIME_DIR))
  home = File.join(destination, RUNTIME_DIR, 'home')
  tmp = File.join(destination, RUNTIME_DIR, 'tmp')
  FileUtils.mkdir_p(home)
  FileUtils.mkdir_p(tmp)
  destination
end

# Explicit, controlled environment. Combined with unsetenv_others this is the
# whole environment the process sees; nothing is inherited. HOME and TMPDIR sit
# at identical relative paths inside each execution root so their contents are
# part of the compared effect surface.
def run_environment(exec_root, path_value)
  {
    'LC_ALL' => 'C.UTF-8',
    'LANG' => 'C.UTF-8',
    'TZ' => 'UTC',
    'PWD' => exec_root,
    'HOME' => File.join(exec_root, RUNTIME_DIR, 'home'),
    'TMPDIR' => File.join(exec_root, RUNTIME_DIR, 'tmp'),
    'PATH' => path_value
  }
end

# Environment reduced to a root-independent form so the two modes are actually
# comparable. Without this the absolute execution-root prefix guarantees a
# difference and the comparison can never gate anything.
def environment_profile(env, exec_root)
  env.transform_values { |value| value.to_s.gsub(exec_root, '${EXEC_ROOT}') }
end

def environment_digest(profile)
  Digest::SHA256.hexdigest(JSON.generate(profile.sort))
end

def build_environment(go, gocache, gomodcache, gohome, gotmp)
  {
    'LC_ALL' => 'C.UTF-8',
    'LANG' => 'C.UTF-8',
    'TZ' => 'UTC',
    'HOME' => gohome,
    'TMPDIR' => gotmp,
    'GOTMPDIR' => gotmp,
    'PATH' => File.dirname(go['bin']),
    'GOTOOLCHAIN' => 'local',
    'GOCACHE' => gocache,
    'GOMODCACHE' => gomodcache,
    'GOFLAGS' => '-mod=mod',
    'GOPROXY' => 'off',
    'GOSUMDB' => 'off',
    'GONOSUMDB' => '*',
    'GONOSUMCHECK' => '1',
    'GOWORK' => 'off',
    'GOOS' => go['goos'],
    'GOARCH' => go['goarch'],
    'CGO_ENABLED' => '0'
  }
end

# --- source map -------------------------------------------------------------

# The source map is REQUIRED for every case. It must carry the exact public
# schema, a non-empty origin naming the real source, a go_digest that binds it
# to the exact generated Go bytes, and at least one mapping with valid Go and
# source coordinates. No extra top-level or entry fields are tolerated.
# Byte line index: the lines of `bytes` and the byte offset each one starts at.
# Positions in the map artifact are 1-based byte lines and 1-based byte columns
# with a 0-based byte offset, so every check below is done in bytes, not
# characters -- a multi-byte source must not shift a coordinate silently.
def byte_line_index(bytes)
  lines = bytes.split("\n", -1)
  offset = 0
  starts = lines.map do |line|
    start = offset
    offset += line.bytesize + 1
    start
  end
  [lines, starts]
end

# Is this byte the middle of a UTF-8 sequence? A coordinate that lands there is
# not a real position in the artifact.
def utf8_continuation_byte?(bytes, offset)
  return false if offset >= bytes.bytesize
  (bytes.getbyte(offset) & 0xC0) == 0x80
end

# Check one (line, col, offset) triple against the artifact it claims to point
# into. A positive integer is not a coordinate: the line must exist, the column
# must be inside that line, the offset must be exactly the byte position that
# line and column denote, and it must not land inside a multi-byte character.
def coordinate_problems(bytes, kind, line, col, offset, label_utf8)
  lines, starts = byte_line_index(bytes)
  problems = []
  if line > lines.length
    problems << "#{kind}_line #{line} is past the end of the #{lines.length}-line artifact"
    return problems
  end
  width = lines[line - 1].bytesize
  problems << "#{kind}_col #{col} is past the end of #{kind}_line #{line} (#{width} bytes)" if col > width + 1
  return problems unless problems.empty?

  expected = starts[line - 1] + (col - 1)
  unless offset.nil?
    problems << "#{kind}_offset #{offset} is past the end of the #{bytes.bytesize}-byte artifact" if offset > bytes.bytesize
    problems << "#{kind}_offset #{offset} does not agree with #{kind}_line #{line} #{kind}_col #{col} (byte #{expected})" if problems.empty? && offset != expected
  end
  return problems unless problems.empty?

  position = offset || expected
  if label_utf8 && utf8_continuation_byte?(bytes, position)
    problems << "#{kind} position #{position} lands inside a multi-byte UTF-8 character"
  end
  problems
end

def parse_source_map(map_path, generated, source_bytes, fixture, label)
  raise CaseFailure, "#{label}: missing source map file '#{map_path}'" unless File.file?(map_path)
  raw = File.binread(map_path)
  raise CaseFailure, "#{label}: empty source map file '#{map_path}'" if raw.empty?
  data = JSON.parse(raw) rescue nil
  raise CaseFailure, "#{label}: source map is not a JSON object" unless data.is_a?(Hash)

  extra = data.keys - MAP_TOP_KEYS
  missing = MAP_TOP_KEYS - data.keys
  raise CaseFailure, "#{label}: source map has unexpected fields #{extra.sort.inspect}" unless extra.empty?
  raise CaseFailure, "#{label}: source map is missing fields #{missing.sort.inspect}" unless missing.empty?
  raise CaseFailure, "#{label}: source map schema_version is #{data['schema_version'].inspect}, expected #{MAP_SCHEMA.inspect}" unless data['schema_version'] == MAP_SCHEMA

  origin = data['origin']
  raise CaseFailure, "#{label}: source map origin must be a non-empty string" unless origin.is_a?(String) && !origin.strip.empty?
  raise CaseFailure, "#{label}: source map origin is #{origin.inspect}, expected the transpiled source #{fixture.inspect}" unless origin == fixture

  expected_digest = "sha256:#{Digest::SHA256.hexdigest(generated)}"
  raise CaseFailure, "#{label}: source map go_digest #{data['go_digest'].inspect} is not bound to the generated Go (expected #{expected_digest})" unless data['go_digest'] == expected_digest

  mappings = data['mappings']
  raise CaseFailure, "#{label}: source map mappings must be a non-empty array" unless mappings.is_a?(Array) && !mappings.empty?
  generated_utf8 = generated.dup.force_encoding('UTF-8').valid_encoding?
  source_utf8 = source_bytes.dup.force_encoding('UTF-8').valid_encoding?
  mappings.each_with_index do |entry, index|
    raise CaseFailure, "#{label}: source map mapping #{index} is not an object" unless entry.is_a?(Hash)
    entry_extra = entry.keys - MAP_ENTRY_KEYS
    entry_missing = MAP_ENTRY_KEYS - entry.keys
    raise CaseFailure, "#{label}: source map mapping #{index} has unexpected fields #{entry_extra.sort.inspect}" unless entry_extra.empty?
    raise CaseFailure, "#{label}: source map mapping #{index} is missing fields #{entry_missing.sort.inspect}" unless entry_missing.empty?
    raise CaseFailure, "#{label}: source map mapping #{index} node must be a non-empty string" unless entry['node'].is_a?(String) && !entry['node'].strip.empty?
    %w[go_line go_col source_line source_col].each do |key|
      value = entry[key]
      raise CaseFailure, "#{label}: source map mapping #{index} #{key} must be an integer >= 1, got #{value.inspect}" unless value.is_a?(Integer) && value >= 1
    end
    offset = entry['source_offset']
    raise CaseFailure, "#{label}: source map mapping #{index} source_offset must be an integer >= 0, got #{offset.inspect}" unless offset.is_a?(Integer) && offset >= 0

    # Positive integers are not coordinates. Both ends of every mapping are
    # checked against the bytes of the artifact they address.
    go_problems = coordinate_problems(generated, 'go', entry['go_line'], entry['go_col'], nil, generated_utf8)
    raise CaseFailure, "#{label}: source map mapping #{index} does not address the generated Go: #{go_problems.join('; ')}" unless go_problems.empty?
    source_problems = coordinate_problems(source_bytes, 'source', entry['source_line'], entry['source_col'], offset, source_utf8)
    raise CaseFailure, "#{label}: source map mapping #{index} does not address #{fixture}: #{source_problems.join('; ')}" unless source_problems.empty?
  end

  { 'bytes' => raw, 'digest' => Digest::SHA256.hexdigest(raw), 'mappings' => mappings.length,
    'origin' => origin, 'go_digest' => data['go_digest'] }
end

# --- typed-only profile -----------------------------------------------------

def stdlib_import?(path)
  !path.split('/').first.to_s.include?('.')
end

def allowed_typed_import?(path)
  return true if stdlib_import?(path)
  TYPED_ONLY_ALLOWED_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
end

# Assert that the compiled artifact is a direct typed Go program: package main,
# importing only the standard library and the stdlib-only typed bridge runtime,
# with no dynamic interpreter or process-exec package anywhere in its transitive
# dependency set. Facts come from `go list`, i.e. from the Go toolchain's own
# parser -- not from regex over the generated text, which would match comments
# and identifiers.
def assert_typed_only!(go, build_env, build_dir, label, case_dir, ledger)
  meta = invoke_subprocess(build_env, [go['bin'], 'list', '-f', "{{.Name}}\n{{range .Imports}}import {{.}}\n{{end}}", '.'], chdir: build_dir, timeout: 60)
  evidence(meta.merge('phase' => 'typed-only-imports', 'case' => label), case_dir: case_dir, ledger: ledger, name: 'typed-only.imports')
  raise CaseFailure, "#{label}: typed-only assertion failed: `go list` could not describe the generated package (exit #{meta['exit']})" unless meta['exit'].zero?

  lines = meta['stdout'].split("\n").map(&:strip).reject(&:empty?)
  package_name = lines.shift
  raise CaseFailure, "#{label}: typed-only assertion failed: generated package is #{package_name.inspect}, expected \"main\"" unless package_name == 'main'
  imports = lines.select { |line| line.start_with?('import ') }.map { |line| line.sub('import ', '') }

  rejected = imports.reject { |path| allowed_typed_import?(path) }
  raise CaseFailure, "#{label}: typed-only assertion failed: non-typed imports #{rejected.sort.inspect}" unless rejected.empty?

  deps_result = invoke_subprocess(build_env, [go['bin'], 'list', '-deps', '.'], chdir: build_dir, timeout: 120)
  evidence(deps_result.merge('phase' => 'typed-only-deps', 'case' => label), case_dir: case_dir, ledger: ledger, name: 'typed-only.deps')
  raise CaseFailure, "#{label}: typed-only assertion failed: `go list -deps` failed (exit #{deps_result['exit']})" unless deps_result['exit'].zero?
  deps = deps_result['stdout'].split("\n").map(&:strip).reject(&:empty?)

  forbidden = deps & TYPED_ONLY_FORBIDDEN_DEPS
  raise CaseFailure, "#{label}: typed-only assertion failed: depends on an interpreter or process-exec package #{forbidden.sort.inspect}" unless forbidden.empty?
  foreign = deps.reject { |path| allowed_typed_import?(path) }
  raise CaseFailure, "#{label}: typed-only assertion failed: transitive non-typed dependencies #{foreign.sort.inspect}" unless foreign.empty?

  { 'package' => package_name, 'imports' => imports.sort, 'transitive_deps' => deps.length }
end

# --- options ----------------------------------------------------------------

options = {
  case_filter: nil,
  bashy: ENV['BASHY_BIN'] || File.join(ROOT, '../bashy/bashy'),
  engine: ENV['BASH_ENGINE_BIN'] || File.join(ROOT, '../bashy/bin/bash'),
  go: ENV['GO_BIN'],
  sh_module: ENV['SH_MODULE'],
  fixture_root: nil,
  manifest: nil,
  artifacts: nil,
  typed_only: false,
  run_path: nil,
  timeout: DEFAULT_TIMEOUT,
  go_cache: nil,
  go_mod_cache: nil,
  phases: nil,
  artifact_only: false,
  inventory: false
}

parser = OptionParser.new do |opts|
  opts.banner = 'usage: go_profile.rb --manifest TSV --fixture-root DIR --sh-module DIR [options]'
  opts.on('--case FILTER', 'exact case id or shell glob') { |value| options[:case_filter] = value }
  opts.on('--bashy PATH', 'bashy CLI providing `transpile --bashpp`') { |value| options[:bashy] = value }
  opts.on('--engine PATH', 'bash engine providing `--bashpp` interpretation') { |value| options[:engine] = value }
  opts.on('--go PATH', 'pinned go1.27.0 binary') { |value| options[:go] = value }
  opts.on('--sh-module PATH', 'local mvdan.cc/sh/v3 module directory') { |value| options[:sh_module] = value }
  opts.on('--fixture-root PATH') { |value| options[:fixture_root] = value }
  opts.on('--manifest PATH') { |value| options[:manifest] = value }
  opts.on('--artifacts PATH', 'retained evidence directory (must not already exist)') { |value| options[:artifacts] = value }
  opts.on('--typed-only', 'require a source-absent, interpreter-free typed artifact') { options[:typed_only] = true }
  opts.on('--run-path PATH', 'PATH given to both execution modes (default: an empty directory)') { |value| options[:run_path] = value }
  opts.on('--timeout SECONDS', Integer) { |value| options[:timeout] = value }
  opts.on('--go-cache PATH', 'GOCACHE for the build (default: inside the artifact directory)') { |value| options[:go_cache] = value }
  opts.on('--go-mod-cache PATH', 'GOMODCACHE for the build (default: inside the artifact directory)') { |value| options[:go_mod_cache] = value }
  opts.on('--phases PATH', 'compiler phase contract for this manifest') { |value| options[:phases] = value }
  opts.on('--artifact-only', 'custom manifests only: declare every case artifact-run') { options[:artifact_only] = true }
  opts.on('--inventory', 'validate every repository manifest and its phase contract, then exit') { options[:inventory] = true }
end
parser.parse!

def fail_closed(message)
  warn "PARITY FAIL: #{message}"
  exit 1
end

begin
  fail_closed("unexpected arguments #{ARGV.inspect}") unless ARGV.empty?

  if options[:inventory]
    phase_path = options[:phases] || DEFAULT_PHASES
    preflight!("the default phase contract is missing at #{phase_path}; the inventory is not phase-aware without it") unless File.file?(phase_path)
    phases = load_phases(phase_path)
    total = 0
    combined = []
    DEFAULT_INVENTORY.each do |manifest_rel, root_rel|
      manifest = File.join(ROOT, manifest_rel)
      root = File.join(ROOT, root_rel)
      cases = load_cases(manifest, root)
      total += cases.length
      combined.concat(cases)
      puts "INVENTORY #{manifest_rel} #{root_rel} #{cases.length}"
    end
    counts = bind_phases!(combined, phases, phase_path, 'the default inventory', true)
    puts "INVENTORY OK: #{total} cases across #{DEFAULT_INVENTORY.length} manifests"
    KNOWN_PHASES.each { |phase| puts "PHASE #{phase} #{counts[phase]}" }
    puts "PHASE CONTRACT OK: #{total} phase-aware cases = #{counts[PHASE_ARTIFACT_RUN]} #{PHASE_ARTIFACT_RUN} + #{counts[PHASE_SEMANTIC_REJECT]} #{PHASE_SEMANTIC_REJECT}"
    exit 0
  end

  preflight!('--manifest is required') unless options[:manifest]
  preflight!('--fixture-root is required') unless options[:fixture_root]
  preflight!('--sh-module is required (or set SH_MODULE)') unless options[:sh_module]

  sh_module = File.realpath(options[:sh_module]) rescue nil
  preflight!("sh module directory does not exist: #{options[:sh_module]}") unless sh_module && File.directory?(sh_module)
  preflight!("sh module has no go.mod: #{sh_module}") unless File.file?(File.join(sh_module, 'go.mod'))

  bashy_bin = File.realpath(options[:bashy]) rescue nil
  preflight!("bashy CLI is missing or not executable: #{options[:bashy]}") unless bashy_bin && File.executable?(bashy_bin) && File.file?(bashy_bin)
  engine_bin = File.realpath(options[:engine]) rescue nil
  preflight!("bash engine is missing or not executable: #{options[:engine]}") unless engine_bin && File.executable?(engine_bin) && File.file?(engine_bin)

  manifest_path = File.expand_path(options[:manifest])
  fixture_root = File.realpath(options[:fixture_root]) rescue nil
  preflight!("fixture root does not exist: #{options[:fixture_root]}") unless fixture_root

  identity = invoke_subprocess(
    { 'LC_ALL' => 'C.UTF-8', 'TZ' => 'UTC', 'HOME' => Dir.tmpdir, 'PATH' => '/usr/bin:/bin' },
    [RbConfig.ruby, File.join(ROOT, 'tools/lowering/identity_manifest.rb')], chdir: ROOT, timeout: 120
  )
  evidence(identity.merge('phase' => 'identity-manifest'))
  preflight!('identity manifest rejected the repository state') unless identity['exit'].zero?

  all_cases = load_cases(manifest_path, fixture_root)

  # Phase policy. A default manifest always carries the full default phase
  # contract: it cannot be run with no phase contract, and it cannot be
  # downgraded to an artifact-only contract, because that would silently turn
  # the semantic-reject identities into artifact runs.
  default_manifests = DEFAULT_INVENTORY.map do |manifest_rel, _|
    begin
      File.realpath(File.join(ROOT, manifest_rel))
    rescue StandardError
      nil
    end
  end.compact
  resolved_manifest = begin
    File.realpath(manifest_path)
  rescue StandardError
    manifest_path
  end
  is_default_manifest = default_manifests.include?(resolved_manifest)

  if is_default_manifest
    preflight!('--artifact-only cannot be used with a default inventory manifest; its phase contract is not optional') if options[:artifact_only]
    phase_path = options[:phases] || DEFAULT_PHASES
    unless File.file?(phase_path)
      preflight!("the default phase contract is missing at #{phase_path}; a default inventory manifest cannot be run without it")
    end
    phases = load_phases(phase_path)
    # The phase document is one contract over the WHOLE default inventory, so it
    # is validated against all 120 identities -- not just the manifest being
    # executed -- and the pinned split is enforced every time. An explicitly
    # supplied phase file is held to that identical contract, so it can relocate
    # the document but never weaken it.
    inventory_cases = DEFAULT_INVENTORY.flat_map do |manifest_rel, root_rel|
      load_cases(File.join(ROOT, manifest_rel), File.join(ROOT, root_rel))
    end
    inventory_counts = bind_phases!(inventory_cases, phases, phase_path, 'the default inventory', true)
    assigned = inventory_cases.each_with_object({}) { |row, acc| acc[row[:id]] = row }
    all_cases.each do |row|
      bound = assigned.fetch(row[:id])
      row[:phase] = bound[:phase]
      row[:phase_reason] = bound[:phase_reason]
    end
    phase_counts = all_cases.each_with_object(Hash.new(0)) { |row, acc| acc[row[:phase]] += 1 }
    puts "PHASE CONTRACT INVENTORY #{phase_path}: #{inventory_cases.length} identities = " \
         "#{inventory_counts[PHASE_ARTIFACT_RUN]} #{PHASE_ARTIFACT_RUN} + #{inventory_counts[PHASE_SEMANTIC_REJECT]} #{PHASE_SEMANTIC_REJECT}"
    warn "NOTE: default phase contract supplied explicitly from #{phase_path}" if options[:phases]
  elsif options[:artifact_only]
    preflight!('--artifact-only and --phases are mutually exclusive') if options[:phases]
    phase_path = '(--artifact-only)'
    all_cases.each { |row| row[:phase] = PHASE_ARTIFACT_RUN; row[:phase_reason] = 'declared artifact-only by --artifact-only' }
    phase_counts = { PHASE_ARTIFACT_RUN => all_cases.length, PHASE_SEMANTIC_REJECT => 0 }
  elsif options[:phases]
    phase_path = options[:phases]
    phases = load_phases(phase_path)
    phase_counts = bind_phases!(all_cases, phases, phase_path, manifest_path, false)
  else
    preflight!('a custom manifest must declare its compiler phases with --phases PATH or --artifact-only')
  end

  puts "PHASE CONTRACT #{phase_path}: #{all_cases.length} cases = #{phase_counts[PHASE_ARTIFACT_RUN].to_i} #{PHASE_ARTIFACT_RUN} + #{phase_counts[PHASE_SEMANTIC_REJECT].to_i} #{PHASE_SEMANTIC_REJECT}"

  selected = all_cases.select do |row|
    options[:case_filter].nil? || row[:id] == options[:case_filter] || File.fnmatch?(options[:case_filter], row[:id])
  end
  preflight!("case filter #{options[:case_filter].inspect} selected zero of #{all_cases.length} cases") if selected.empty?

  go = authenticate_go(options[:go] || resolve_pinned_go)

  artifact_root = options[:artifacts] || File.join(Dir.tmpdir, "go-profile-artifacts-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(4)}")
  preflight!("artifact directory already exists: #{artifact_root}") if File.exist?(artifact_root)
  artifact_root = File.expand_path(artifact_root)
  FileUtils.mkdir_p(artifact_root)

  # Build caches default to the artifact directory. They can be pointed at a
  # shared directory so a long contract run does not rebuild the world; the
  # runner only ever creates them, it never removes a directory it was handed.
  shared_gocache = options[:go_cache] ? File.expand_path(options[:go_cache]) : File.join(artifact_root, 'go-build-cache')
  shared_gomodcache = options[:go_mod_cache] ? File.expand_path(options[:go_mod_cache]) : File.join(artifact_root, 'go-mod-cache')
  build_home = File.join(artifact_root, 'build-home')
  build_tmp = File.join(artifact_root, 'build-tmp')
  empty_path_dir = File.join(artifact_root, 'empty-path')
  [shared_gocache, shared_gomodcache, build_home, build_tmp, empty_path_dir].each { |dir| FileUtils.mkdir_p(dir) }

  run_path = options[:run_path] || empty_path_dir
  go_bin_dir = File.dirname(go['bin'])
  run_path_dirs = run_path.split(File::PATH_SEPARATOR).reject(&:empty?)
  preflight!("run PATH exposes the Go toolchain directory #{go_bin_dir}; the executed artifact must not see a Go runtime") if run_path_dirs.include?(go_bin_dir)
  leaked_go = run_path_dirs.find { |dir| File.executable?(File.join(dir, 'go')) }
  preflight!("run PATH directory #{leaked_go} exposes a `go` executable; the executed artifact must not see a Go runtime") if leaked_go

  build_env = build_environment(go, shared_gocache, shared_gomodcache, build_home, build_tmp)

  metadata = {
    'schema' => 'lowering.go-profile-run.v1',
    'go_cache' => shared_gocache,
    'go_mod_cache' => shared_gomodcache,
    'sprint' => 117, 'story' => 9, 'story_id' => 'e400885f8746',
    'manifest' => manifest_path,
    'fixture_root' => fixture_root,
    'cases_declared' => all_cases.length,
    'cases_selected' => selected.length,
    'phase_contract' => phase_path,
    'phase_counts_declared' => phase_counts,
    'phase_counts_selected' => selected.each_with_object(Hash.new(0)) { |row, acc| acc[row[:phase]] += 1 },
    'typed_only' => options[:typed_only],
    'toolchain' => go,
    'module_import' => 'mvdan.cc/sh/v3',
    'sh_module_path' => sh_module,
    'bashy_bin' => bashy_bin,
    'bashy_bin_sha256' => Digest::SHA256.file(bashy_bin).hexdigest,
    'engine_bin' => engine_bin,
    'engine_bin_sha256' => Digest::SHA256.file(engine_bin).hexdigest,
    'run_path' => run_path,
    'effect_detection' => {
      'method' => 'sha256 tree snapshot of the execution root before and after the run',
      'covers' => "every path under the execution root, including #{RUNTIME_DIR}/home (HOME), #{RUNTIME_DIR}/tmp (TMPDIR), dotfiles and files named *.raw",
      'exempt' => 'compiled mode only: the deleted original Bash++ source path',
      'syscall_hooks' => false,
      'limitation' => 'writes to absolute paths outside the execution root are not observed by this runner'
    }
  }
  File.write(File.join(artifact_root, 'meta.json'), JSON.pretty_generate(metadata))
  puts "ARTIFACTS RETAINED: #{artifact_root}"
  puts JSON.generate(metadata)

  go_mod = "module bashylowered\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.0.0\n\nreplace mvdan.cc/sh/v3 => #{sh_module}\n"
  failures = []
  artifact_executed = 0
  semantic_certified = 0

  selected.each do |row|
    label = row[:id]
    fixture = row[:fixture]
    case_dir = File.join(artifact_root, row[:category], label)
    FileUtils.mkdir_p(case_dir)
    ledger = File.join(case_dir, 'evidence.jsonl')

    begin
      # -- transpile twice, from two independent sandbox copies of the fixture
      #    tree. Outputs land in the evidence directory, outside every root.
      source_one = File.join(case_dir, 'generated.one.go')
      source_two = File.join(case_dir, 'generated.two.go')
      sandbox_one = File.join(case_dir, 'transpile.one')
      sandbox_two = File.join(case_dir, 'transpile.two')
      copy_tree(fixture_root, sandbox_one)
      copy_tree(fixture_root, sandbox_two)
      semantic = row[:phase] == PHASE_SEMANTIC_REJECT
      sandbox_before = semantic ? [filesystem_snapshot(sandbox_one), filesystem_snapshot(sandbox_two)] : nil

      transpile_env = { 'LC_ALL' => 'C.UTF-8', 'LANG' => 'C.UTF-8', 'TZ' => 'UTC',
                        'HOME' => build_home, 'TMPDIR' => build_tmp, 'PATH' => run_path }
      first = invoke_subprocess(transpile_env, [bashy_bin, 'transpile', '--bashpp', fixture, '-o', source_one], chdir: sandbox_one, timeout: options[:timeout])
      evidence(first.merge('phase' => 'transpile', 'case' => label, 'attempt' => 1), case_dir: case_dir, ledger: ledger, name: 'transpile.one')
      second = invoke_subprocess(transpile_env, [bashy_bin, 'transpile', '--bashpp', fixture, '-o', source_two], chdir: sandbox_two, timeout: options[:timeout])
      evidence(second.merge('phase' => 'transpile', 'case' => label, 'attempt' => 2), case_dir: case_dir, ledger: ledger, name: 'transpile.two')

      [[first, 1], [second, 2]].each do |result, attempt|
        next if result['lifecycle_clean']
        raise CaseFailure, "#{label}: transpile attempt #{attempt} #{LIFECYCLE_REASONS.fetch(result['lifecycle'], result['lifecycle'])}"
      end
      if semantic
        # ---- semantic-reject phase -----------------------------------------
        # The contract is that the CLI REFUSES this statically invalid source
        # with the exact diagnostic the interpreter produces. Exiting non-zero
        # is not the contract; neither is bailing out with LOWER-EUNSUPPORTED
        # or leaking a raw Go type-check error. No artifact is built.
        problems = []
        [[first, 1, source_one, sandbox_one, sandbox_before[0]],
         [second, 2, source_two, sandbox_two, sandbox_before[1]]].each do |result, attempt, source, sandbox, before|
          problems << "transpile attempt #{attempt} expected exit #{row[:expected_status]} but got #{result['exit']}" if result['exit'] != row[:expected_status]
          problems << "transpile attempt #{attempt} stdout does not match the manifest" if result['stdout'] != row[:stdout]
          problems << "transpile attempt #{attempt} stderr does not match the manifest diagnostic" if result['stderr'] != row[:stderr]
          semantic_diagnostic_problems(result['stderr'], label, fixture).each do |detail|
            problems << "transpile attempt #{attempt} did not produce a contracted semantic diagnostic: #{detail}"
          end
          problems << "transpile attempt #{attempt} emitted Go for a rejected source" if File.exist?(source)
          problems << "transpile attempt #{attempt} emitted a source map for a rejected source" if File.exist?("#{source}.map")
          after = filesystem_snapshot(sandbox)
          unless after['entries'] == before['entries']
            problems << "transpile attempt #{attempt} changed its input tree: #{snapshot_diff(before, after).join('; ')}"
          end
        end
        problems << 'the rejection is nondeterministic: the two attempts disagree on stderr' if first['stderr'] != second['stderr']
        problems << 'the rejection is nondeterministic: the two attempts disagree on exit' if first['exit'] != second['exit']

        # The interpreter is exercised independently and must still produce the
        # original observation. A truncated lifecycle cannot certify anything.
        interpreted_root = prepare_execution_root(fixture_root, File.join(case_dir, 'run', 'interpreted'))
        env_interpreted = run_environment(interpreted_root, run_path)
        before_interpreted = filesystem_snapshot(interpreted_root)
        interpreted = invoke_subprocess(env_interpreted, [engine_bin, '--bashpp', fixture], chdir: interpreted_root, timeout: options[:timeout])
        after_interpreted = filesystem_snapshot(interpreted_root)
        evidence(interpreted.merge('phase' => 'interpreted-run', 'case' => label, 'compiler_phase' => PHASE_SEMANTIC_REJECT,
                                   'observation' => { 'mode' => 'interpreted',
                                                      'status' => { 'exit' => interpreted['exit'], 'timeout' => interpreted['timeout'],
                                                                    'lifecycle' => interpreted['lifecycle'], 'group_killed' => interpreted['group_killed'] },
                                                      'raw_streams' => { 'schema' => 'lowering.raw-byte-streams.v1',
                                                                         'stdout_sha256' => interpreted['stdout_sha256'], 'stderr_sha256' => interpreted['stderr_sha256'] },
                                                      'effects' => { 'schema' => 'lowering.execution-root-effects.v1', 'syscall_hooks' => false,
                                                                     'filesystem_before' => snapshot_public(before_interpreted),
                                                                     'filesystem_after' => snapshot_public(after_interpreted) } }),
                 case_dir: case_dir, ledger: ledger, name: 'interpreted')

        unless interpreted['lifecycle_clean']
          problems << "interpreted run #{LIFECYCLE_REASONS.fetch(interpreted['lifecycle'], interpreted['lifecycle'])}"
        end
        problems << "interpreted expected exit #{row[:expected_status]} but got #{interpreted['exit']}" if interpreted['exit'] != row[:expected_status]
        problems << 'interpreted stdout does not match the manifest' if interpreted['stdout'] != row[:stdout]
        problems << 'interpreted stderr does not match the manifest' if interpreted['stderr'] != row[:stderr]
        unless after_interpreted['entries'] == before_interpreted['entries']
          problems << "the interpreted run left an effect before the designated error: #{snapshot_diff(before_interpreted, after_interpreted).join('; ')}"
        end

        raise CaseFailure, "#{label}: #{problems.join('; ')}" unless problems.empty?
        semantic_certified += 1
        puts "PHASE PASS #{label}: semantic-reject certified (diagnostic parity, no artifact built)"
        next
      end

      raise CaseFailure, "#{label}: transpilation failed (exit #{first['exit']}/#{second['exit']}): #{first['stderr'].strip}" unless first['exit'].zero? && second['exit'].zero?
      raise CaseFailure, "#{label}: transpilation emitted no Go source" unless File.size?(source_one) && File.size?(source_two)

      generated_one = File.binread(source_one)
      generated_two = File.binread(source_two)
      raise CaseFailure, "#{label}: generated Go is nondeterministic" unless generated_one == generated_two

      # -- source map is required, schema-checked, and digest-bound
      source_bytes = File.binread(File.join(fixture_root, fixture))
      map_one = parse_source_map("#{source_one}.map", generated_one, source_bytes, fixture, label)
      map_two = parse_source_map("#{source_two}.map", generated_two, source_bytes, fixture, label)
      raise CaseFailure, "#{label}: generated source map is nondeterministic" unless map_one['digest'] == map_two['digest']
      evidence({ 'phase' => 'source-map', 'case' => label, 'schema' => MAP_SCHEMA,
                 'origin' => map_one['origin'], 'go_digest' => map_one['go_digest'],
                 'map_sha256' => map_one['digest'], 'mappings' => map_one['mappings'],
                 'generated_go_sha256' => Digest::SHA256.hexdigest(generated_one) },
               case_dir: case_dir, ledger: ledger)

      # -- build, in a directory that is not an execution root
      build_dir = File.join(case_dir, 'build')
      FileUtils.mkdir_p(build_dir)
      File.write(File.join(build_dir, 'go.mod'), go_mod)
      File.binwrite(File.join(build_dir, 'main.go'), generated_one)
      built = File.join(build_dir, 'lowered.bin')
      build = invoke_subprocess(build_env, [go['bin'], 'build', '-o', built, '.'], chdir: build_dir, timeout: [options[:timeout], 300].max)
      evidence(build.merge('phase' => 'build', 'case' => label, 'generated_go_sha256' => Digest::SHA256.hexdigest(generated_one)), case_dir: case_dir, ledger: ledger, name: 'build')
      raise CaseFailure, "#{label}: generated Go build #{LIFECYCLE_REASONS.fetch(build['lifecycle'], build['lifecycle'])}" unless build['lifecycle_clean']
      raise CaseFailure, "#{label}: generated Go did not build: #{build['stderr'].strip}" unless build['exit'].zero? && File.executable?(built)

      typed_profile = nil
      typed_profile = assert_typed_only!(go, build_env, build_dir, label, case_dir, ledger) if options[:typed_only]

      # -- move the artifact out of the build tree: it must run with no build
      #    directory, no module, no Go toolchain and (typed-only) no PATH.
      isolated_dir = File.join(case_dir, 'artifact')
      FileUtils.mkdir_p(isolated_dir)
      binary = File.join(isolated_dir, 'lowered.bin')
      FileUtils.mv(built, binary)
      binary_sha = Digest::SHA256.file(binary).hexdigest

      # -- two execution roots with identical relative layout
      interpreted_root = prepare_execution_root(fixture_root, File.join(case_dir, 'run', 'interpreted'))
      compiled_root = prepare_execution_root(fixture_root, File.join(case_dir, 'run', 'compiled'))
      FileUtils.rm_f(File.join(compiled_root, fixture))
      ignored_compiled = compiled_only_ignored_paths(fixture)

      env_interpreted = run_environment(interpreted_root, run_path)
      env_compiled = run_environment(compiled_root, options[:typed_only] ? '' : run_path)
      profile_interpreted = environment_profile(env_interpreted, interpreted_root)
      profile_compiled = environment_profile(env_compiled, compiled_root)
      declared_divergence = options[:typed_only] ? ['PATH'] : []

      env_diff = (profile_interpreted.keys | profile_compiled.keys).reject do |key|
        profile_interpreted[key] == profile_compiled[key]
      end
      undeclared = env_diff - declared_divergence
      raise CaseFailure, "#{label}: execution environments diverge on undeclared keys #{undeclared.sort.inspect}" unless undeclared.empty?

      before_interpreted = filesystem_snapshot(interpreted_root)
      before_compiled = filesystem_snapshot(compiled_root)
      comparable_before_i = snapshot_reject(before_interpreted, ignored_compiled)
      comparable_before_c = snapshot_reject(before_compiled, ignored_compiled)
      raise CaseFailure, "#{label}: execution roots differ before the run: #{snapshot_diff(comparable_before_i, comparable_before_c).inspect}" unless comparable_before_i['entries'] == comparable_before_c['entries']

      interpreted = invoke_subprocess(env_interpreted, [engine_bin, '--bashpp', fixture], chdir: interpreted_root, timeout: options[:timeout])
      after_interpreted = filesystem_snapshot(interpreted_root)
      compiled = invoke_subprocess(env_compiled, [binary], chdir: compiled_root, timeout: options[:timeout])
      after_compiled = filesystem_snapshot(compiled_root)
      comparable_after_i = snapshot_reject(after_interpreted, ignored_compiled)
      comparable_after_c = snapshot_reject(after_compiled, ignored_compiled)

      observation = lambda do |result, mode, before, after, env, profile|
        {
          'mode' => mode,
          'status' => { 'exit' => result['exit'], 'timeout' => result['timeout'],
                        'lifecycle' => result['lifecycle'], 'group_killed' => result['group_killed'] },
          'raw_streams' => { 'schema' => 'lowering.raw-byte-streams.v1',
                             'stdout_sha256' => result['stdout_sha256'], 'stderr_sha256' => result['stderr_sha256'],
                             'stdout_bytes' => result['stdout_bytes'], 'stderr_bytes' => result['stderr_bytes'] },
          'environment' => { 'schema' => 'lowering.controlled-env.v1', 'inherited' => false,
                             'profile' => profile, 'profile_sha256' => environment_digest(profile),
                             'declared_divergence' => declared_divergence, 'keys' => env.keys.sort },
          'effects' => { 'schema' => 'lowering.execution-root-effects.v1',
                         'method' => 'pre/post sha256 tree snapshot of the execution root',
                         'syscall_hooks' => false,
                         'exempt_paths' => mode == 'compiled' ? ignored_compiled : [],
                         'filesystem_before' => snapshot_public(before), 'filesystem_after' => snapshot_public(after) }
        }
      end

      evidence(interpreted.merge('phase' => 'interpreted-run', 'case' => label,
                                 'observation' => observation.call(interpreted, 'interpreted', before_interpreted, after_interpreted, env_interpreted, profile_interpreted)),
               case_dir: case_dir, ledger: ledger, name: 'interpreted')
      evidence(compiled.merge('phase' => 'compiled-run', 'case' => label, 'binary_sha256' => binary_sha,
                              'typed_only' => typed_profile,
                              'observation' => observation.call(compiled, 'compiled', before_compiled, after_compiled, env_compiled, profile_compiled)),
               case_dir: case_dir, ledger: ledger, name: 'compiled')

      problems = []
      # A run whose process tree the runner had to cut short is not evidence.
      # This covers a plain timeout and, just as importantly, a process that
      # outlived the leader in the runner's own process group -- including one
      # that closed its inherited pipes first and would otherwise have looked
      # like a clean, finished run while it kept writing to the execution root.
      [[interpreted, 'interpreted'], [compiled, 'compiled']].each do |result, mode|
        next if result['lifecycle_clean']
        reason = LIFECYCLE_REASONS.fetch(result['lifecycle'], result['lifecycle'])
        detail = result['lifecycle'] == LIFECYCLE_TIMEOUT ? " (budget #{options[:timeout]}s)" : ''
        problems << "#{mode} run #{reason}#{detail}"
      end
      problems.concat(source_path_problems(fixture, before_interpreted, after_interpreted, before_compiled, after_compiled))

      if interpreted['exit'] != row[:expected_status]
        problems << "interpreted expected exit #{row[:expected_status]} but got #{interpreted['exit']}"
      end
      if compiled['exit'] != row[:expected_status]
        problems << "compiled expected exit #{row[:expected_status]} but got #{compiled['exit']}"
      end
      problems << 'interpreted stdout does not match the manifest' if interpreted['stdout'] != row[:stdout]
      problems << 'interpreted stderr does not match the manifest' if interpreted['stderr'] != row[:stderr]
      problems << 'compiled stdout does not match the manifest' if compiled['stdout'] != row[:stdout]
      problems << 'compiled stderr does not match the manifest' if compiled['stderr'] != row[:stderr]
      problems << 'interpreted and compiled stdout diverged' if interpreted['stdout'] != compiled['stdout']
      problems << 'interpreted and compiled stderr diverged' if interpreted['stderr'] != compiled['stderr']
      problems << "interpreted and compiled exit diverged (#{interpreted['exit']} vs #{compiled['exit']})" if interpreted['exit'] != compiled['exit']

      unless comparable_after_i['entries'] == comparable_after_c['entries']
        problems << "filesystem effects diverged: #{snapshot_diff(comparable_after_i, comparable_after_c).join('; ')}"
      end

      raise CaseFailure, "#{label}: #{problems.join('; ')}" unless problems.empty?
      artifact_executed += 1
      puts "PARITY PASS #{label}: artifact-run authenticated (transpile/map/build/source-absent run)"
    rescue CaseFailure => error
      failures << error.message
      warn "PARITY FAIL #{error.message}"
    rescue StandardError => error
      failures << "#{label}: unhandled error: #{error.class}: #{error.message}"
      warn "PARITY FAIL #{label}: unhandled error: #{error.class}: #{error.message}"
    end
  end

  # The two phases are counted and reported separately, always. A certified
  # semantic rejection is not a native execution, and the totals must never be
  # readable as "N native artifacts".
  selected_artifact = selected.count { |row| row[:phase] == PHASE_ARTIFACT_RUN }
  selected_semantic = selected.count { |row| row[:phase] == PHASE_SEMANTIC_REJECT }
  breakdown = "#{artifact_executed}/#{selected_artifact} artifact executions, " \
              "#{semantic_certified}/#{selected_semantic} certified semantic rejections"

  puts "GO-PROFILE PHASE RESULT: #{breakdown} " \
       "(#{selected.length} phase-aware cases selected of #{all_cases.length}; " \
       "artifact executions are the only native artifacts, semantic rejections build none)"

  if failures.empty?
    scope = selected.length == all_cases.length ? 'PASS' : 'SUBSET PASS'
    puts "GO-PROFILE PARITY #{scope}: #{selected.length}/#{all_cases.length} selected — #{breakdown}"
    exit 0
  end

  warn "GO-PROFILE PARITY FAIL: #{failures.length} failures across #{selected.length} selected cases (#{breakdown})"
  exit 1
rescue PreflightFailure => error
  fail_closed(error.message)
end
