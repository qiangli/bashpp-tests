#!/usr/bin/env ruby
# Sprint: #117
# Story: #9
# Story-ID: e400885f8746
#
# Structural contract test for tools/lowering/go_profile.rb.
#
# This is NOT a Bash++ language proof. It proves the runner's gates: what it
# accepts, what it rejects, and that a rejection is a non-zero exit with a
# named diagnostic rather than a silent pass.
#
# Two kinds of evidence are used and they are labelled as such:
#
#   * MECHANISM scenarios drive the runner with a fake transpiler and a fake
#     engine. They exist to exercise gate mechanics (tamper, timeout, effect
#     divergence). They make no claim about Bash++ or about the real compiler.
#     Their generated Go is nevertheless compiled for real by the pinned Go
#     1.27.0 toolchain, and the typed-only scenarios import the real, reviewed
#     `mvdan.cc/sh/v3/lower/shellrt` bridge from the real sh module.
#
#   * ACCEPTANCE scenarios drive the runner with the real bashy transpile CLI,
#     the real bash engine, the real sh module and the real pinned Go. They
#     must pass. Their locations are supplied at runtime through the
#     environment; no host path is committed to this repository.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
RUNNER = File.join(ROOT, 'tools/lowering/go_profile.rb')
RUBY = RbConfig.ruby

FAILURES = []
CHECKS = []

def check(name)
  yield
  CHECKS << name
  puts "  ok   #{name}"
rescue StandardError => error
  FAILURES << "#{name}: #{error.message}"
  puts "  FAIL #{name}: #{error.message}"
end

def assert(condition, message)
  raise message unless condition
end

def assert_includes(haystack, needle, message)
  assert(haystack.include?(needle), "#{message} (looked for #{needle.inspect})")
end

def run(env, *argv)
  Open3.capture3(env, *argv)
end

# --- runtime configuration; nothing here is committed ------------------------

def require_env(*names)
  names.each do |name|
    value = ENV[name]
    return value if value && !value.empty?
  end
  abort <<~MSG
    go-profile contract ABORT: none of #{names.join(', ')} is set.

    This contract test refuses to fake its acceptance evidence. The real
    artifacts must be supplied at runtime, for example:

      CONTRACT_BASHY_CLI=/path/to/bashy \\
      CONTRACT_ENGINE=/path/to/bash \\
      CONTRACT_SH_MODULE=/path/to/sh \\
      ruby tests/lowering/go_profile_contract_test.rb
  MSG
end

REAL_BASHY = require_env('CONTRACT_BASHY_CLI', 'BASHY_BIN')
REAL_ENGINE = require_env('CONTRACT_ENGINE', 'BASH_ENGINE_BIN')
REAL_SH_MODULE = require_env('CONTRACT_SH_MODULE', 'SH_MODULE')

abort "go-profile contract ABORT: bashy CLI is not executable: #{REAL_BASHY}" unless File.executable?(REAL_BASHY)
abort "go-profile contract ABORT: bash engine is not executable: #{REAL_ENGINE}" unless File.executable?(REAL_ENGINE)
abort "go-profile contract ABORT: sh module has no go.mod: #{REAL_SH_MODULE}" unless File.file?(File.join(REAL_SH_MODULE, 'go.mod'))
abort "go-profile contract ABORT: sh module has no lower/shellrt typed bridge: #{REAL_SH_MODULE}" unless File.directory?(File.join(REAL_SH_MODULE, 'lower/shellrt'))

goroot, go_err, go_status = run({ 'GOTOOLCHAIN' => 'go1.27.0' }, 'go', 'env', 'GOROOT')
abort "go-profile contract ABORT: pinned Go 1.27.0 is unavailable:\n#{go_err}" unless go_status.success?
REAL_GO = File.join(goroot.strip, 'bin/go')
abort "go-profile contract ABORT: resolved Go is not executable: #{REAL_GO}" unless File.executable?(REAL_GO)

# A PATH the fake POSIX-sh engine can actually work in. It must not expose a Go
# toolchain -- the runner refuses that, and the next check proves it.
RUN_PATH = '/usr/bin:/bin'.freeze

WORK = Dir.mktmpdir('s117-goprofile-contract-')
at_exit { FileUtils.remove_entry(WORK) if File.directory?(WORK) }

# A build cache shared across every scenario in this run. It is created if it is
# missing and NEVER removed -- this suite does not clean up a directory it was
# handed, and a warm cache is what keeps ~50 real Go builds affordable.
GO_CACHE = ENV['S117_GO_CACHE'] || File.join(Dir.tmpdir, 's117-runner-correction-cache')
GO_MOD_CACHE = ENV['S117_GO_MOD_CACHE'] || File.join(GO_CACHE, 'mod')
FileUtils.mkdir_p(GO_CACHE)
FileUtils.mkdir_p(GO_MOD_CACHE)
CACHE_ARGS = ['--go-cache', GO_CACHE, '--go-mod-cache', GO_MOD_CACHE].freeze

# --- MECHANISM harness ------------------------------------------------------

TRANSPILER_TEMPLATE = <<~'TEMPLATE'
  #!@@RUBY@@
  require 'digest'
  require 'json'
  out = nil
  input = nil
  argv = ARGV.dup
  until argv.empty?
    arg = argv.shift
    if arg == '-o'
      out = argv.shift
    elsif arg == 'transpile' || arg.start_with?('-')
      next
    else
      input = arg
    end
  end
  attempt = File.basename(out).include?('.two.') ? 2 : 1
  go = ATTEMPT_SOURCE.call(attempt)
  File.binwrite(out, go)
  map_path = "#{out}.map"
  map = {
    'schema_version' => 'bashy-transpile-map-v1',
    'origin' => input,
    'go_digest' => "sha256:#{Digest::SHA256.hexdigest(go)}",
    'mappings' => [
      { 'go_line' => 1, 'go_col' => 1, 'source_line' => 1, 'source_col' => 1, 'source_offset' => 0, 'node' => 'BashPPDecl' }
    ]
  }
  @@MAP_HOOK@@
  File.binwrite(map_path, JSON.pretty_generate(map)) if map
TEMPLATE

# A fake CLI that REJECTS its input instead of lowering it: it writes the given
# streams, exits with the given status, and (unless told otherwise) emits no Go
# and no source map. Used to drive the semantic-reject phase.
REJECTING_TRANSPILER_TEMPLATE = <<~'TEMPLATE'
  #!@@RUBY@@
  out = nil
  input = nil
  argv = ARGV.dup
  until argv.empty?
    arg = argv.shift
    if arg == '-o'
      out = argv.shift
    elsif arg == 'transpile' || arg.start_with?('-')
      next
    else
      input = arg
    end
  end
  @@EMIT@@
  $stdout.write(@@STDOUT@@)
  $stderr.write(@@STDERR@@)
  exit @@STATUS@@
TEMPLATE

MECH_REF = 'sh/interp/bashpp_test.go:TestBashPPMechanism'.freeze
PHASE_HEADER = "id\tphase\tsource_sha256\treason\tpublic_test_ref".freeze

# Build a phase contract document for a scenario's own manifest.
def phase_file(path, entries, fixture_root, header: PHASE_HEADER, comment: '# MECHANISM phase contract.')
  lines = [comment, header]
  entries.each do |entry|
    sha = entry[:sha] || Digest::SHA256.file(File.join(fixture_root, entry.fetch(:fixture))).hexdigest
    lines << [entry.fetch(:id), entry.fetch(:phase), sha,
              entry[:reason] || 'mechanism scenario', entry[:ref] || MECH_REF].join("\t")
  end
  File.write(path, lines.join("\n") + "\n")
  path
end

# Every mechanism scenario gets its own directory, its own fake binaries and its
# own manifest. No environment channel is punched through the runner to steer a
# fake: the runner's execution environment stays fully controlled.
def mechanism(name, go_source: GO_HELLO, map_hook: '', engine_body:, fixture: 'case.bpp',
              fixture_body: "echo case\n", extra_files: {}, rows: nil, args: [],
              reject: nil, phases: nil, phase_file_text: nil, artifact_only: false)
  dir = File.join(WORK, name)
  fixtures = File.join(dir, 'fixtures')
  FileUtils.mkdir_p(fixtures)

  File.write(File.join(fixtures, fixture), fixture_body)
  extra_files.each do |relative, body|
    target = File.join(fixtures, relative)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, body)
  end

  # A Go source is either a literal (same bytes on every attempt) or a Ruby
  # lambda expression, given as a string, that varies with the attempt number.
  transpiler = File.join(dir, 'fake-transpiler')
  # Block form: a plain replacement string would have `\\` interpreted as a
  # backreference escape and would silently corrupt the embedded Go source.
  body =
    if reject
      emit = []
      emit << %(File.binwrite(out, "package main\\n")) if reject[:emit_go]
      emit << %(File.binwrite("\#{out}.map", "{}")) if reject[:emit_map]
      REJECTING_TRANSPILER_TEMPLATE
        .sub('@@RUBY@@') { RUBY }
        .sub('@@EMIT@@') { emit.join("\n") }
        .sub('@@STDOUT@@') { (reject[:stdout] || '').inspect }
        .sub('@@STDERR@@') { (reject[:stderr] || '').inspect }
        .sub('@@STATUS@@') { (reject[:status] || 2).to_s }
    else
      source_expr = go_source.start_with?('->') ? go_source : "->(_attempt) { #{go_source.inspect} }"
      TRANSPILER_TEMPLATE
        .sub('@@RUBY@@') { RUBY }
        .sub('ATTEMPT_SOURCE') { source_expr }
        .sub('@@MAP_HOOK@@') { map_hook }
    end
  File.write(transpiler, body)
  FileUtils.chmod(0o755, transpiler)

  engine = File.join(dir, 'fake-engine')
  File.write(engine, "#!/bin/sh\n#{engine_body}")
  FileUtils.chmod(0o755, engine)

  manifest = File.join(dir, 'manifest.tsv')
  rows ||= ["case-1\tmech\t#{fixture}\t0\t\"hello\\n\"\t\"\"\tsh/interp/bashpp_test.go:TestBashPPMechanism"]
  File.write(manifest, ([
    '# MECHANISM manifest: fake transpiler/engine, gate mechanics only.',
    "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref"
  ] + rows).join("\n") + "\n")

  phase_args =
    if phase_file_text
      path = File.join(dir, 'phases.tsv')
      File.write(path, phase_file_text)
      ['--phases', path]
    elsif phases
      ['--phases', phase_file(File.join(dir, 'phases.tsv'), phases, fixtures)]
    elsif artifact_only || !(args.include?('--artifact-only') || args.include?('--phases'))
      # Scenarios that only exercise artifact-run behaviour declare that
      # explicitly; a custom manifest is never allowed an implicit phase.
      ['--artifact-only']
    else
      []
    end

  artifacts = File.join(dir, 'artifacts')
  argv = [RUBY, RUNNER,
          '--bashy', transpiler, '--engine', engine, '--go', REAL_GO,
          '--sh-module', REAL_SH_MODULE, '--manifest', manifest,
          '--fixture-root', fixtures, '--artifacts', artifacts,
          '--run-path', RUN_PATH, '--timeout', '20'] + CACHE_ARGS + phase_args + args
  out, err, status = run({}, *argv)
  { out: out, err: err, status: status, all: out + err, dir: dir, artifacts: artifacts,
    manifest: manifest, fixtures: fixtures }
end

def ledger(result, category, id)
  path = File.join(result[:artifacts], category, id, 'evidence.jsonl')
  raise "no evidence ledger at #{path}" unless File.file?(path)
  File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
end

def phase(records, name)
  records.find { |record| record['phase'] == name } or raise "no #{name} record in ledger"
end

# --- Go sources used by MECHANISM scenarios ---------------------------------

GO_HELLO = <<~GO
  // Code generated for the Sprint 117 mechanism contract. DO NOT EDIT.
  package main

  import "fmt"

  func main() { fmt.Println("hello") }
GO

# Deliberately saturated with the words a naive textual scan would trip over:
# interpreter, shell, runtime, exec, bashpp -- in comments, in a string, and in
# identifiers. A typed-only assertion built on the Go toolchain's own import
# graph must accept this; a regex over the source text would not.
GO_NOISY = <<~GO
  // bashpp lowering: this comment mentions the interpreter, the shell runtime,
  // os/exec and exec.Command on purpose. None of them are imported.
  package main

  import "fmt"

  // interpreterWrapperShellRuntimeExec is a plain function name, not a dependency.
  func interpreterWrapperShellRuntimeExec() string { return "hello" }

  func main() { fmt.Println(interpreterWrapperShellRuntimeExec()) }
GO

GO_SHELLRT = <<~GO
  // Typed bridge: imports the reviewed, stdlib-only mvdan.cc/sh/v3/lower/shellrt.
  package main

  import (
  \t"fmt"

  \t"mvdan.cc/sh/v3/lower/shellrt"
  )

  func main() {
  \t_ = shellrt.Stdout
  \tfmt.Println("hello")
  }
GO

GO_EXEC = <<~GO
  package main

  import (
  \t"fmt"
  \t"os/exec"
  )

  func main() {
  \t_ = exec.Command
  \tfmt.Println("hello")
  }
GO

GO_BAD_BUILD = <<~GO
  package main

  func main() { syntax error }
GO

GO_ERROR2 = <<~GO
  package main

  import (
  \t"fmt"
  \t"os"
  )

  func main() {
  \tfmt.Fprintln(os.Stderr, "boom")
  \tos.Exit(2)
  }
GO

GO_SOURCE_ABSENT = <<~GO
  package main

  import (
  \t"fmt"
  \t"os"
  )

  func main() {
  \tif _, err := os.Stat("case.bpp"); err == nil {
  \t\tfmt.Println("SOURCE-STILL-PRESENT")
  \t\treturn
  \t}
  \tfmt.Println("hello")
  }
GO

def go_writes(path_expr, content, extra_import: nil)
  <<~GO
    package main

    import (
    \t"fmt"
    \t"os"
    )

    func main() {
    \tif err := os.WriteFile(#{path_expr}, []byte(#{content.inspect}), 0o644); err != nil {
    \t\tfmt.Fprintln(os.Stderr, err)
    \t\tos.Exit(1)
    \t}
    \tfmt.Println("hello")
    }
  GO
end

ENGINE_HELLO = %(printf 'hello\\n'\n).freeze
ENGINE_ERROR2 = %(printf 'boom\\n' >&2\nexit 2\n).freeze

puts 'go-profile contract: preflight and fail-closed gates'

check 'no arguments is a fail-closed PARITY FAIL' do
  out, err, status = run({}, RUBY, RUNNER)
  assert(!status.success?, "expected non-zero exit, got #{status.exitstatus}")
  assert_includes(out + err, 'PARITY FAIL', 'expected a PARITY FAIL diagnostic')
end

check '--manifest without --fixture-root is rejected' do
  out, err, status = run({}, RUBY, RUNNER, '--manifest', File.join(ROOT, 'docs/lowering/go-profile-cases.tsv'))
  assert(!status.success?, 'expected non-zero exit')
  assert_includes(out + err, '--fixture-root is required', 'expected the missing-flag diagnostic')
end

check 'unknown positional arguments are rejected' do
  out, err, status = run({}, RUBY, RUNNER, '--inventory', 'stray')
  assert(!status.success?, 'expected non-zero exit')
  assert_includes(out + err, 'unexpected arguments', 'expected the stray-argument diagnostic')
end

# The phase contract is owned by the coverage worker. Until it lands in this
# repository the runner must fail closed, and this suite reads the candidate
# from S117_PHASES_CANDIDATE so the pairing is still exercised for real.
def default_phase_contract
  landed = File.join(ROOT, 'docs/lowering/go-profile-phases.tsv')
  return landed if File.file?(landed)
  candidate = ENV['S117_PHASES_CANDIDATE']
  return candidate if candidate && File.file?(candidate)
  nil
end

check 'the repository inventory covers all 120 cases across both manifests' do
  contract = default_phase_contract
  raise 'no phase contract available; set S117_PHASES_CANDIDATE' unless contract
  out, err, status = run({}, RUBY, RUNNER, '--inventory', '--phases', contract)
  assert(status.success?, "inventory failed:\n#{out}#{err}")
  assert_includes(out, 'INVENTORY docs/lowering/go-profile-cases.tsv tests/lowering/go-profile 52', 'go-profile manifest inventory line')
  assert_includes(out, 'INVENTORY docs/lowering/profile-additional.tsv tests/lowering/profile-additional 68', 'profile-additional manifest inventory line')
  assert_includes(out, 'INVENTORY OK: 120 cases across 2 manifests', 'combined inventory total')
end

check 'a non-pinned Go binary fails toolchain authentication' do
  result = mechanism('bad-go', go_source: GO_HELLO, engine_body: ENGINE_HELLO)
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', File.join(result[:dir], 'fake-transpiler'),
                         '--engine', File.join(result[:dir], 'fake-engine'),
                         '--go', '/bin/echo',
                         '--sh-module', REAL_SH_MODULE,
                         '--manifest', result[:manifest],
                         '--fixture-root', result[:fixtures], '--artifact-only',
                         '--artifacts', File.join(result[:dir], 'artifacts-badgo'))
  assert(!status.success?, 'a non-pinned Go binary was accepted')
  assert(/Go identity|Go binary digest/.match?(out + err), "expected an authentication diagnostic, got:\n#{out}#{err}")
end

check 'a missing sh module is rejected' do
  out, err, status = run({}, RUBY, RUNNER,
                         '--manifest', File.join(ROOT, 'docs/lowering/go-profile-cases.tsv'),
                         '--fixture-root', File.join(ROOT, 'tests/lowering/go-profile'),
                         '--sh-module', File.join(WORK, 'no-such-sh'))
  assert(!status.success?, 'expected non-zero exit')
  assert_includes(out + err, 'sh module directory does not exist', 'expected the sh-module diagnostic')
end

puts 'go-profile contract: seven-column numeric manifest validation'

MANIFEST_CASES = {
  'header mismatch' => {
    text: "id\tcategory\tfixture\tstatus\tstdout\tstderr\tref\ncase-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\tref\n",
    diagnostic: 'header mismatch'
  },
  'six columns' => {
    text: nil, row: "case-1\tmech\tcase.bpp\t0\t\"\"\t\"\"", diagnostic: 'expected 7 tab-separated fields, got 6'
  },
  'eight columns' => {
    text: nil, row: "case-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\tref\textra", diagnostic: 'expected 7 tab-separated fields, got 8'
  },
  'bare unquoted stdout stream' => {
    text: nil, row: "case-1\tmech\tcase.bpp\t0\thello\t\"\"\tref", diagnostic: 'stdout column must be a JSON string literal'
  },
  'invalid JSON stream' => {
    text: nil, row: "case-1\tmech\tcase.bpp\t0\t\"\\\"\t\"\"\tref", diagnostic: 'is not valid JSON'
  },
  'empty public_test_ref' => {
    text: nil, row: "case-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\t", diagnostic: 'public_test_ref must be non-empty'
  },
  'non-numeric expected_status' => {
    text: nil, row: "case-1\tmech\tcase.bpp\tsuccess\t\"\"\t\"\"\tref", diagnostic: 'expected_status must be a decimal integer 0..255'
  },
  'out-of-range expected_status' => {
    text: nil, row: "case-1\tmech\tcase.bpp\t300\t\"\"\t\"\"\tref", diagnostic: 'expected_status must be a decimal integer 0..255'
  },
  'uncontained fixture path' => {
    text: nil, row: "case-1\tmech\t../escape.bpp\t0\t\"\"\t\"\"\tref", diagnostic: 'fixture path must be relative and contained'
  },
  'absolute fixture path' => {
    text: nil, row: "case-1\tmech\t/etc/passwd\t0\t\"\"\t\"\"\tref", diagnostic: 'fixture path must be relative and contained'
  },
  'fixture missing on disk' => {
    text: nil, row: "case-1\tmech\tabsent.bpp\t0\t\"\"\t\"\"\tref", diagnostic: 'missing fixture on disk'
  },
  'duplicate case id' => {
    text: nil,
    row: "case-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\tref\ncase-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\tref",
    diagnostic: 'duplicate case ids'
  }
}.freeze

MANIFEST_CASES.each do |name, spec|
  check "manifest is rejected: #{name}" do
    dir = File.join(WORK, "manifest-#{name.gsub(/\W+/, '-')}")
    fixtures = File.join(dir, 'fixtures')
    FileUtils.mkdir_p(fixtures)
    File.write(File.join(fixtures, 'case.bpp'), "echo case\n")
    manifest = File.join(dir, 'manifest.tsv')
    text = spec[:text] || ("id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref\n#{spec[:row]}\n")
    File.write(manifest, text)
    out, err, status = run({}, RUBY, RUNNER,
                           '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                           '--sh-module', REAL_SH_MODULE, '--manifest', manifest,
                           '--fixture-root', fixtures, '--artifacts', File.join(dir, 'artifacts'))
    assert(!status.success?, "manifest defect #{name.inspect} was accepted")
    assert_includes(out + err, spec[:diagnostic], "expected the #{name} diagnostic")
  end
end

check 'a .bpp fixture on disk that no manifest row declares is rejected' do
  dir = File.join(WORK, 'manifest-unlisted')
  fixtures = File.join(dir, 'fixtures')
  FileUtils.mkdir_p(fixtures)
  File.write(File.join(fixtures, 'case.bpp'), "echo case\n")
  File.write(File.join(fixtures, 'orphan.bpp'), "echo orphan\n")
  manifest = File.join(dir, 'manifest.tsv')
  File.write(manifest, "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref\ncase-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\tref\n")
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                         '--sh-module', REAL_SH_MODULE, '--manifest', manifest,
                         '--fixture-root', fixtures, '--artifacts', File.join(dir, 'artifacts'))
  assert(!status.success?, 'an undeclared fixture was accepted')
  assert_includes(out + err, 'absent from the manifest', 'expected the inventory diagnostic')
  assert_includes(out + err, 'orphan.bpp', 'diagnostic should name the undeclared fixture')
end

puts 'go-profile contract: MECHANISM gates (fake transpiler and engine)'

check 'MECHANISM: a well-formed case passes and retains raw evidence' do
  result = mechanism('pass', go_source: GO_HELLO, engine_body: ENGINE_HELLO)
  assert(result[:status].success?, "expected success:\n#{result[:all]}")
  assert_includes(result[:out], 'GO-PROFILE PARITY PASS: 1/1', 'expected a full-manifest pass line')
  %w[transpile.one transpile.two build interpreted compiled].each do |name|
    %w[stdout stderr].each do |stream|
      path = File.join(result[:artifacts], 'mech', 'case-1', "#{name}.#{stream}.raw")
      assert(File.file?(path), "missing retained raw stream #{name}.#{stream}.raw")
    end
  end
  assert(File.binread(File.join(result[:artifacts], 'mech', 'case-1', 'interpreted.stdout.raw')) == "hello\n",
         'retained interpreted stdout bytes are wrong')
  meta = JSON.parse(File.read(File.join(result[:artifacts], 'meta.json')))
  assert(meta['toolchain']['version'] == 'go1.27.0', 'meta.json does not record the pinned toolchain')
  assert(meta['effect_detection']['syscall_hooks'] == false, 'meta.json must not claim syscall hooks')
  records = ledger(result, 'mech', 'case-1')
  map = phase(records, 'source-map')
  assert(map['schema'] == 'bashy-transpile-map-v1', "map schema recorded as #{map['schema'].inspect}")
  assert(map['go_digest'] == "sha256:#{map['generated_go_sha256']}", 'map go_digest is not bound to the generated Go')
end

check 'MECHANISM: retained artifacts live outside every execution root' do
  result = mechanism('outside-root', go_source: GO_HELLO, engine_body: ENGINE_HELLO)
  assert(result[:status].success?, "expected success:\n#{result[:all]}")
  case_dir = File.join(result[:artifacts], 'mech', 'case-1')
  %w[run/interpreted run/compiled].each do |exec_root|
    root = File.join(case_dir, exec_root)
    assert(File.directory?(root), "missing execution root #{exec_root}")
    stray = Dir.glob(File.join(root, '**', '*.raw'), File::FNM_DOTMATCH)
    assert(stray.empty?, "runner evidence leaked into the execution root: #{stray.inspect}")
    %w[evidence.jsonl go.mod main.go lowered.bin].each do |name|
      assert(!File.exist?(File.join(root, name)), "build/evidence artifact #{name} is inside the execution root")
    end
  end
  assert(File.file?(File.join(case_dir, 'evidence.jsonl')), 'evidence ledger is not in the case directory')
  assert(File.file?(File.join(case_dir, 'build', 'main.go')), 'build tree is not in the case directory')
  assert(File.file?(File.join(case_dir, 'artifact', 'lowered.bin')), 'the artifact was not moved out of the build tree')
end

check 'MECHANISM: a missing source map is rejected' do
  result = mechanism('missing-map', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: 'map = nil')
  assert(!result[:status].success?, 'a case with no source map was accepted')
  assert_includes(result[:all], 'missing source map file', 'expected the missing-map diagnostic')
end

check 'MECHANISM: a source map missing only on the second transpile is rejected' do
  result = mechanism('missing-map-two', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     map_hook: 'map = nil if attempt == 2')
  assert(!result[:status].success?, 'a half-present source map was accepted')
  assert_includes(result[:all], 'missing source map file', 'expected the missing-map diagnostic')
end

check 'MECHANISM: a source-map-v3 artifact is rejected (wrong schema)' do
  hook = <<~'HOOK'
    map = { 'version' => 3, 'sources' => [input], 'names' => [], 'mappings' => 'AAAA' }
  HOOK
  result = mechanism('sourcemap-v3', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: hook)
  assert(!result[:status].success?, 'a source-map-v3 artifact was accepted')
  assert(/unexpected fields|schema_version/.match?(result[:all]), "expected a schema diagnostic, got:\n#{result[:all]}")
end

check 'MECHANISM: an extra top-level map field is rejected' do
  result = mechanism('map-extra', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     map_hook: "map['sources'] = [input]")
  assert(!result[:status].success?, 'an extra map field was accepted')
  assert_includes(result[:all], 'unexpected fields', 'expected the extra-field diagnostic')
end

check 'MECHANISM: a go_digest not bound to the generated Go is rejected' do
  result = mechanism('map-digest-tamper', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     map_hook: "map['go_digest'] = 'sha256:' + ('0' * 64)")
  assert(!result[:status].success?, 'an unbound go_digest was accepted')
  assert_includes(result[:all], 'is not bound to the generated Go', 'expected the digest-binding diagnostic')
end

check 'MECHANISM: an empty origin is rejected' do
  result = mechanism('map-origin', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     map_hook: "map['origin'] = ''")
  assert(!result[:status].success?, 'an empty map origin was accepted')
  assert_includes(result[:all], 'origin must be a non-empty string', 'expected the origin diagnostic')
end

check 'MECHANISM: an empty mappings array is rejected' do
  result = mechanism('map-empty', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     map_hook: "map['mappings'] = []")
  assert(!result[:status].success?, 'an empty mappings array was accepted')
  assert_includes(result[:all], 'mappings must be a non-empty array', 'expected the mappings diagnostic')
end

check 'MECHANISM: a non-deterministic source map is rejected' do
  hook = "map['mappings'][0]['go_col'] = attempt + 1"
  result = mechanism('map-nondeterministic', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: hook)
  assert(!result[:status].success?, 'a non-deterministic source map was accepted')
  assert_includes(result[:all], 'generated source map is nondeterministic', 'expected the map determinism diagnostic')
end

check 'MECHANISM: non-deterministic generated Go is rejected' do
  source = '->(attempt) { "package main\n\nimport \"fmt\"\n\n// attempt #{attempt}\nfunc main() { fmt.Println(\"hello\") }\n" }'
  result = mechanism('go-nondeterministic', go_source: source, engine_body: ENGINE_HELLO)
  assert(!result[:status].success?, 'non-deterministic Go was accepted')
  assert_includes(result[:all], 'generated Go is nondeterministic', 'expected the determinism diagnostic')
end

check 'MECHANISM: generated Go that does not compile is rejected' do
  result = mechanism('bad-build', go_source: GO_BAD_BUILD, engine_body: ENGINE_HELLO)
  assert(!result[:status].success?, 'uncompilable Go was accepted')
  assert_includes(result[:all], 'generated Go did not build', 'expected the build diagnostic')
end

check 'MECHANISM: a numeric exit mismatch is rejected and partial evidence is kept' do
  result = mechanism('exit-mismatch', go_source: GO_ERROR2, engine_body: ENGINE_ERROR2)
  assert(!result[:status].success?, 'an exit mismatch was accepted')
  assert_includes(result[:all], 'expected exit 0 but got 2', 'expected the numeric status diagnostic')
  path = File.join(result[:artifacts], 'mech', 'case-1', 'interpreted.stderr.raw')
  assert(File.file?(path), 'failure-path raw stderr was not retained')
  assert(File.binread(path) == "boom\n", 'failure-path raw stderr bytes are wrong')
end

check 'MECHANISM: the compiled artifact runs with the original source absent' do
  result = mechanism('source-absent', go_source: GO_SOURCE_ABSENT, engine_body: ENGINE_HELLO)
  assert(result[:status].success?, "source-absent execution failed:\n#{result[:all]}")
  compiled_root = File.join(result[:artifacts], 'mech', 'case-1', 'run', 'compiled')
  assert(!File.exist?(File.join(compiled_root, 'case.bpp')), 'the original source was still present for the compiled run')
  interpreted_root = File.join(result[:artifacts], 'mech', 'case-1', 'run', 'interpreted')
  assert(File.file?(File.join(interpreted_root, 'case.bpp')), 'the interpreted root lost its source')
  assert(File.binread(File.join(result[:artifacts], 'mech', 'case-1', 'compiled.stdout.raw')) == "hello\n",
         'the artifact observed its own source')
end

puts 'go-profile contract: typed-only profile'

check 'typed-only accepts a program whose comments and identifiers name an interpreter' do
  result = mechanism('typed-noisy', go_source: GO_NOISY, engine_body: ENGINE_HELLO, args: ['--typed-only'])
  assert(result[:status].success?, "typed-only rejected a purely typed program on textual grounds:\n#{result[:all]}")
end

check 'typed-only accepts the real stdlib-only shellrt typed bridge import' do
  result = mechanism('typed-shellrt', go_source: GO_SHELLRT, engine_body: ENGINE_HELLO, args: ['--typed-only'])
  assert(result[:status].success?, "typed-only rejected the reviewed shellrt bridge:\n#{result[:all]}")
  records = ledger(result, 'mech', 'case-1')
  compiled = phase(records, 'compiled-run')
  imports = compiled['typed_only']['imports']
  assert_includes(imports, 'mvdan.cc/sh/v3/lower/shellrt', 'the shellrt import was not recorded')
end

check 'typed-only rejects a program that can exec a process' do
  result = mechanism('typed-exec', go_source: GO_EXEC, engine_body: ENGINE_HELLO, args: ['--typed-only'])
  assert(!result[:status].success?, 'typed-only accepted an os/exec dependency')
  assert_includes(result[:all], 'typed-only assertion failed', 'expected the typed-only diagnostic')
  assert_includes(result[:all], 'os/exec', 'the diagnostic should name the offending package')
end

check 'typed-only runs the artifact with an empty PATH and gates the declared divergence' do
  result = mechanism('typed-path', go_source: GO_HELLO, engine_body: ENGINE_HELLO, args: ['--typed-only'])
  assert(result[:status].success?, "typed-only run failed:\n#{result[:all]}")
  records = ledger(result, 'mech', 'case-1')
  compiled = phase(records, 'compiled-run')['observation']
  interpreted = phase(records, 'interpreted-run')['observation']
  assert(compiled['environment']['profile']['PATH'] == '', "compiled PATH was #{compiled['environment']['profile']['PATH'].inspect}")
  assert(compiled['environment']['declared_divergence'] == ['PATH'], 'PATH divergence was not declared')
  assert(compiled['environment']['inherited'] == false, 'the runner must not claim an inherited environment')
  assert(interpreted['environment']['profile']['HOME'] == compiled['environment']['profile']['HOME'],
         'HOME is not at an equivalent path in both modes')
  assert(interpreted['environment']['profile']['TMPDIR'] == compiled['environment']['profile']['TMPDIR'],
         'TMPDIR is not at an equivalent path in both modes')
  assert(interpreted['environment']['profile_sha256'] != nil, 'no environment digest recorded')
  assert(!compiled['environment']['keys'].any? { |key| key.start_with?('GO') },
         "a Go runtime variable leaked into the artifact environment: #{compiled['environment']['keys'].inspect}")
end

puts 'go-profile contract: filesystem effects, including HOME and TMPDIR'

check 'EFFECTS: matching HOME writes in both modes are accepted' do
  result = mechanism('effect-home-match',
                     go_source: go_writes('os.Getenv("HOME") + "/marker"', "same\n"),
                     engine_body: %(printf 'same\\n' > "$HOME/marker"\nprintf 'hello\\n'\n))
  assert(result[:status].success?, "matching HOME effects were rejected:\n#{result[:all]}")
end

check 'EFFECTS: a HOME write in only one mode is a divergence' do
  result = mechanism('effect-home-diverge',
                     go_source: go_writes('os.Getenv("HOME") + "/marker"', "only-compiled\n"),
                     engine_body: ENGINE_HELLO)
  assert(!result[:status].success?, 'a HOME-only effect was ignored')
  assert_includes(result[:all], 'filesystem effects diverged', 'expected the effect diagnostic')
  assert_includes(result[:all], '.bashpp-run/home/marker', 'the diagnostic should name the HOME path')
end

check 'EFFECTS: a TMPDIR write in only one mode is a divergence' do
  result = mechanism('effect-tmp-diverge',
                     go_source: go_writes('os.Getenv("TMPDIR") + "/scratch"', "only-compiled\n"),
                     engine_body: ENGINE_HELLO)
  assert(!result[:status].success?, 'a TMPDIR-only effect was ignored')
  assert_includes(result[:all], 'filesystem effects diverged', 'expected the effect diagnostic')
  assert_includes(result[:all], '.bashpp-run/tmp/scratch', 'the diagnostic should name the TMPDIR path')
end

check 'EFFECTS: a fixture file whose name ends in .raw is compared, not excused' do
  result = mechanism('effect-raw',
                     go_source: go_writes('"notes.raw"', "compiled-only\n"),
                     engine_body: ENGINE_HELLO)
  assert(!result[:status].success?, 'an effect on a *.raw path was ignored')
  assert_includes(result[:all], 'filesystem effects diverged', 'expected the effect diagnostic')
  assert_includes(result[:all], 'notes.raw', 'the diagnostic should name the .raw path')
end

check 'EFFECTS: a pre-existing fixture named *.raw is mutated-detected' do
  result = mechanism('effect-raw-existing',
                     go_source: go_writes('"payload.raw"', "changed\n"),
                     engine_body: ENGINE_HELLO,
                     extra_files: { 'payload.raw' => "original\n" })
  assert(!result[:status].success?, 'a mutation of a pre-existing *.raw fixture was ignored')
  assert_includes(result[:all], 'payload.raw', 'the diagnostic should name the mutated .raw fixture')
end

puts 'go-profile contract: timeouts and descendant drain'

check 'TIMEOUT: a hung interpreted run fails and keeps the partial stream' do
  engine = <<~SH
    printf 'partial-out\\n'
    sleep 120
  SH
  started = Time.now
  result = mechanism('timeout-hung', go_source: GO_HELLO, engine_body: engine, args: ['--timeout', '4'])
  elapsed = Time.now - started
  assert(!result[:status].success?, 'a timed-out run reported success')
  assert_includes(result[:all], 'timed out', 'expected a timeout diagnostic')
  assert(elapsed < 90, "the runner did not bound the hung run (took #{elapsed.round(1)}s)")
  path = File.join(result[:artifacts], 'mech', 'case-1', 'interpreted.stdout.raw')
  assert(File.file?(path), 'the partial raw stream was not retained')
  assert(File.binread(path) == "partial-out\n", "partial bytes were lost: #{File.binread(path).inspect}")
  records = ledger(result, 'mech', 'case-1')
  interpreted = phase(records, 'interpreted-run')
  assert(interpreted['timeout'] == true, 'the ledger does not record the timeout')
  assert(interpreted['exit'] == 124, "timeout exit recorded as #{interpreted['exit']}, expected 124")
end

# --- REGRESSION 1 and 2: process lifetime -----------------------------------
#
# Reviewer defects 1 and 2. Both are the same lie told two ways: the runner
# stopped observing while a process it had spawned was still running, and then
# reported parity on the truncated observation. Defect 1 cut a descendant off at
# the drain grace and called the result a pass; defect 2 never noticed the
# descendant at all, because it had closed its inherited pipes, and it went on
# writing into the execution root after the snapshot was taken.

# Waits out a background writer and reports whether it managed to touch the
# execution root after the runner had already returned.
def late_file_appeared?(artifacts, relative, wait_seconds)
  path = File.join(artifacts, 'mech', 'case-1', 'run', 'interpreted', relative)
  deadline = Time.now + wait_seconds
  while Time.now < deadline
    return true if File.exist?(path)
    sleep 0.25
  end
  File.exist?(path)
end

check 'LIFETIME: a descendant that outlives the drain while holding the pipe fails the case' do
  engine = <<~SH
    ( sleep 8; printf 'late-output\\n'; printf 'late-effect\\n' > late.txt ) &
    printf 'hello\\n'
    exit 0
  SH
  started = Time.now
  result = mechanism('lifetime-drain-cut', go_source: GO_HELLO, engine_body: engine, args: ['--timeout', '30'])
  elapsed = Time.now - started
  assert(!result[:status].success?, 'a killed, still-running descendant was accepted as a pass')
  assert_includes(result[:all], 'left a process alive in its own process group', 'expected an explicit lifecycle reason')
  assert_includes(result[:all], 'truncated', 'the reason must say the observation is truncated')
  assert(elapsed < 60, "the runner did not bound the drain (#{elapsed.round(1)}s)")
  records = ledger(result, 'mech', 'case-1')
  interpreted = phase(records, 'interpreted-run')
  assert(interpreted['lifecycle'] == 'group-outlived-drain', "lifecycle recorded as #{interpreted['lifecycle'].inspect}")
  assert(interpreted['group_killed'] == true, 'the ledger does not record the group kill')
  assert(interpreted['timeout'] == false, 'an outliving group is not a timeout')
  assert(File.binread(File.join(result[:artifacts], 'mech', 'case-1', 'interpreted.stdout.raw')) == "hello\n",
         'the leader output was lost')
  assert(!late_file_appeared?(result[:artifacts], 'late.txt', 10),
         'the descendant survived the runner and wrote into the execution root')
end

check 'LIFETIME: a descendant that closes its inherited pipes is still detected and killed' do
  # Both pipes hit EOF the moment the leader exits, so a pipe-only drain sees a
  # clean, finished run. The process is still there, and two seconds later it
  # writes into the execution root the runner has already snapshotted.
  engine = <<~SH
    ( exec >/dev/null 2>&1; sleep 8; printf 'late-effect\\n' > late.txt ) &
    printf 'hello\\n'
    exit 0
  SH
  started = Time.now
  result = mechanism('lifetime-closed-pipes', go_source: GO_HELLO, engine_body: engine, args: ['--timeout', '30'])
  elapsed = Time.now - started
  assert(!result[:status].success?, 'a surviving descendant with closed pipes was accepted as a pass')
  assert_includes(result[:all], 'left a process alive in its own process group', 'expected an explicit lifecycle reason')
  assert(elapsed < 60, "the runner did not bound the wait (#{elapsed.round(1)}s)")
  records = ledger(result, 'mech', 'case-1')
  interpreted = phase(records, 'interpreted-run')
  assert(interpreted['lifecycle'] == 'group-outlived-drain', "lifecycle recorded as #{interpreted['lifecycle'].inspect}")
  assert(interpreted['group_killed'] == true, 'the ledger does not record the group kill')
  assert(!late_file_appeared?(result[:artifacts], 'late.txt', 10),
         'the descendant survived the runner and wrote into the execution root after the snapshot')
end

check 'LIFETIME: a descendant that finishes inside the grace is waited for, not killed' do
  # The positive control. The runner must not simply fail anything that
  # backgrounds work: it must wait for the owned process group to empty and
  # include what that work did in the compared effects.
  engine = <<~SH
    ( sleep 0.4; printf 'late-effect\\n' > shared.txt ) &
    printf 'hello\\n'
    exit 0
  SH
  result = mechanism('lifetime-completes', go_source: go_writes('"shared.txt"', "late-effect\n"),
                     engine_body: engine, args: ['--timeout', '30'])
  assert(result[:status].success?, "a descendant that finished in time was rejected:\n#{result[:all]}")
  records = ledger(result, 'mech', 'case-1')
  interpreted = phase(records, 'interpreted-run')
  assert(interpreted['lifecycle'] == 'clean', "lifecycle recorded as #{interpreted['lifecycle'].inspect}")
  assert(interpreted['group_killed'] == false, 'the runner killed a group that was finishing on its own')
  written = File.join(result[:artifacts], 'mech', 'case-1', 'run', 'interpreted', 'shared.txt')
  assert(File.file?(written), 'the descendant effect was not captured in the execution root')
  assert(File.binread(written) == "late-effect\n", 'the descendant effect was captured incompletely')
end


puts 'go-profile contract: map coordinates address real artifacts'

# --- REGRESSION 3 -----------------------------------------------------------
# Reviewer defect 3: coordinates were only checked for being positive, so a map
# claiming line 1000000 of a two-line fixture was accepted.

check 'COORDINATES: impossible coordinates on a tiny source are rejected' do
  hook = "map['mappings'][0].merge!('go_col' => 1000000, 'source_line' => 1000000, 'source_col' => 1000000, 'source_offset' => 1000000)"
  result = mechanism('coords-impossible', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: hook)
  assert(!result[:status].success?, 'impossible map coordinates were accepted')
  assert(/does not address/.match?(result[:all]), "expected a coordinate diagnostic, got:\n#{result[:all]}")
end

check 'COORDINATES: a go_col past the end of its generated line is rejected' do
  hook = "map['mappings'][0]['go_col'] = 4096"
  result = mechanism('coords-gocol', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: hook)
  assert(!result[:status].success?, 'an out-of-range go_col was accepted')
  assert_includes(result[:all], 'does not address the generated Go', 'expected a generated-Go coordinate diagnostic')
  assert_includes(result[:all], 'go_col', 'the diagnostic should name go_col')
end

check 'COORDINATES: a source_line past the end of the fixture is rejected' do
  hook = "map['mappings'][0]['source_line'] = 99"
  result = mechanism('coords-srcline', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: hook)
  assert(!result[:status].success?, 'an out-of-range source_line was accepted')
  assert_includes(result[:all], 'is past the end of the', 'expected a source coordinate diagnostic')
end

check 'COORDINATES: a source_offset inconsistent with its line and column is rejected' do
  # The subtle one: every field is individually plausible, but together they do
  # not denote a byte position in the fixture.
  hook = "map['mappings'][0]['source_offset'] = 3"
  result = mechanism('coords-offset', go_source: GO_HELLO, engine_body: ENGINE_HELLO, map_hook: hook)
  assert(!result[:status].success?, 'an inconsistent source_offset was accepted')
  assert_includes(result[:all], 'does not agree with', 'expected an offset-consistency diagnostic')
end

check 'COORDINATES: correct byte coordinates into a multi-byte source are accepted' do
  # Positive control, and the UTF-8 half of it: line 1 holds two- and three-byte
  # characters, so the byte offset of line 2 is not its character offset.
  hook = <<~'HOOK'
    src = File.binread(input)
    first = src.split("\n", -1)[0]
    map['mappings'][0].merge!('source_line' => 2, 'source_col' => 1, 'source_offset' => first.bytesize + 1)
  HOOK
  result = mechanism('coords-utf8-ok', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     fixture_body: "# h\u00e9llo \u4e2d\necho case\n", map_hook: hook)
  assert(result[:status].success?, "correct byte coordinates into a UTF-8 source were rejected:\n#{result[:all]}")
end

check 'COORDINATES: character-counted coordinates into a multi-byte source are rejected' do
  hook = <<~'HOOK'
    src = File.binread(input)
    first = src.split("\n", -1)[0]
    chars = first.dup.force_encoding('UTF-8').length
    map['mappings'][0].merge!('source_line' => 2, 'source_col' => 1, 'source_offset' => chars + 1)
  HOOK
  result = mechanism('coords-utf8-chars', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     fixture_body: "# h\u00e9llo \u4e2d\necho case\n", map_hook: hook)
  assert(!result[:status].success?, 'character-counted coordinates were accepted for a multi-byte source')
  assert_includes(result[:all], 'does not agree with', 'expected an offset-consistency diagnostic')
end

puts 'go-profile contract: the deliberately absent source path'

# --- REGRESSION 4 -----------------------------------------------------------
# Reviewer defect 4: the original source path was removed from both sides of the
# effect diff wholesale, so a compiled artifact that recreated it was invisible.

check 'SOURCE PATH: a compiled artifact that recreates the deleted source fails' do
  go = <<~GO
    package main

    import (
    \t"fmt"
    \t"os"
    )

    func main() {
    \tos.WriteFile("case.bpp", []byte("compiled-only-effect\\n"), 0o600)
    \tfmt.Println("hello")
    }
  GO
  result = mechanism('source-recreated', go_source: go, engine_body: ENGINE_HELLO)
  assert(!result[:status].success?, 'a compiled artifact recreated the deleted source and was accepted')
  assert_includes(result[:all], 'recreated or wrote the deliberately absent source path', 'expected the source-path diagnostic')
  assert_includes(result[:all], 'case.bpp', 'the diagnostic should name the source path')
end

check 'SOURCE PATH: an interpreted run that rewrites its own source fails' do
  engine = %(printf 'mutated\\n' > case.bpp\nprintf 'hello\\n'\n)
  result = mechanism('source-mutated', go_source: GO_HELLO, engine_body: engine)
  assert(!result[:status].success?, 'an interpreted run rewrote its own source and was accepted')
  assert_includes(result[:all], 'modified its own source', 'expected the source-mutation diagnostic')
end

check 'SOURCE PATH: an interpreted run that deletes its own source fails' do
  engine = %(rm -f case.bpp\nprintf 'hello\\n'\n)
  result = mechanism('source-deleted', go_source: GO_HELLO, engine_body: engine)
  assert(!result[:status].success?, 'an interpreted run deleted its own source and was accepted')
  assert_includes(result[:all], 'deleted its own source', 'expected the source-deletion diagnostic')
end

puts 'go-profile contract: compiler phase contract'

SEM_DIAG = "BASHPP-EIF-COND: if condition must be boolean, got Int\n".freeze
LEGACY_DIAG = "invalid receiver type Missing (type is not declared in this session)\n".freeze

def shell_quote(text)
  "'" + text.gsub("'", %q('\\'')) + "'"
end

# A fake engine that reproduces a semantic diagnostic on stderr and exits 2.
def rejecting_engine(stderr, status: 2, before: nil)
  body = ''
  body += before if before
  body + "printf '%s' #{shell_quote(stderr)} >&2\nexit #{status}\n"
end

def semantic_rows(id, fixture, stderr, status: 2)
  ["#{id}\tmech\t#{fixture}\t#{status}\t\"\"\t#{JSON.generate(stderr)}\t#{MECH_REF}"]
end

# Drive one semantic-reject case end to end.
def semantic(name, id: 'sem-1', fixture: 'case.bpp', golden: SEM_DIAG, golden_status: 2,
             cli_stderr: nil, cli_stdout: '', cli_status: 2, emit_go: false, emit_map: false,
             engine_stderr: nil, engine_status: nil, engine_before: nil, phase: 'semantic-reject')
  mechanism(name,
            fixture: fixture,
            fixture_body: "if 1 { echo x }\n",
            rows: semantic_rows(id, fixture, golden, status: golden_status),
            phases: [{ id: id, phase: phase, fixture: fixture }],
            reject: { status: cli_status, stdout: cli_stdout, stderr: cli_stderr.nil? ? golden : cli_stderr,
                      emit_go: emit_go, emit_map: emit_map },
            engine_body: rejecting_engine(engine_stderr.nil? ? golden : engine_stderr,
                                          status: engine_status || golden_status, before: engine_before))
end

# --- the phase document itself ---------------------------------------------

PHASE_DOC_CASES = {
  'an unknown phase name' => {
    rows: ["sem-1\tlower-only\t%<sha>s\treason\t%<ref>s"], diagnostic: 'unknown phase'
  },
  'a phase entry for an identity the manifest does not declare' => {
    rows: ["case-1\tartifact-run\t%<sha>s\treason\t%<ref>s", "ghost-1\tartifact-run\t%<sha>s\treason\t%<ref>s"],
    diagnostic: 'identities absent from'
  },
  'a duplicate identity' => {
    rows: ["case-1\tartifact-run\t%<sha>s\treason\t%<ref>s", "case-1\tsemantic-reject\t%<sha>s\treason\t%<ref>s"],
    diagnostic: 'duplicate phase entry'
  },
  'a source hash that no longer matches the fixture' => {
    rows: ["case-1\tartifact-run\t#{'0' * 64}\treason\t%<ref>s"], diagnostic: 'does not match'
  },
  'a public reference that disagrees with the manifest' => {
    rows: ["case-1\tartifact-run\t%<sha>s\treason\tsh/interp/other_test.go:TestOther"],
    diagnostic: 'does not match the manifest reference'
  },
  'a non-hex source hash' => {
    rows: ["case-1\tartifact-run\tnot-a-digest\treason\t%<ref>s"], diagnostic: 'must be a sha256 hex digest'
  },
  'an empty reason' => {
    rows: ["case-1\tartifact-run\t%<sha>s\t\t%<ref>s"], diagnostic: 'reason must be non-empty'
  },
  'a missing column' => {
    rows: ["case-1\tartifact-run\t%<sha>s\treason"], diagnostic: 'expected 5 tab-separated fields, got 4'
  },
  'an extra column' => {
    rows: ["case-1\tartifact-run\t%<sha>s\treason\t%<ref>s\textra"], diagnostic: 'expected 5 tab-separated fields, got 6'
  }
}.freeze

PHASE_DOC_CASES.each do |name, spec|
  check "phase contract is rejected: #{name}" do
    dir = File.join(WORK, "phasedoc-#{name.gsub(/\W+/, '-')[0, 40]}")
    fixtures = File.join(dir, 'fixtures')
    FileUtils.mkdir_p(fixtures)
    File.write(File.join(fixtures, 'case.bpp'), "echo case\n")
    sha = Digest::SHA256.file(File.join(fixtures, 'case.bpp')).hexdigest
    manifest = File.join(dir, 'manifest.tsv')
    File.write(manifest, "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref\ncase-1\tmech\tcase.bpp\t0\t\"hello\\n\"\t\"\"\t#{MECH_REF}\n")
    phases = File.join(dir, 'phases.tsv')
    body = spec[:rows].map { |row| format(row, sha: sha, ref: MECH_REF) }.join("\n")
    File.write(phases, "#{PHASE_HEADER}\n#{body}\n")
    out, err, status = run({}, RUBY, RUNNER,
                           '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                           '--sh-module', REAL_SH_MODULE, '--manifest', manifest,
                           '--fixture-root', fixtures, '--phases', phases,
                           '--artifacts', File.join(dir, 'artifacts'), *CACHE_ARGS)
    assert(!status.success?, "phase contract defect #{name.inspect} was accepted")
    assert_includes(out + err, spec[:diagnostic], "expected the #{name} diagnostic")
  end
end

check 'phase contract is rejected: a wrong header' do
  result = mechanism('phasedoc-header', engine_body: ENGINE_HELLO,
                     phase_file_text: "id\tphase\tsha\treason\tref\ncase-1\tartifact-run\t#{'0' * 64}\tr\t#{MECH_REF}\n")
  assert(!result[:status].success?, 'a wrong phase header was accepted')
  assert_includes(result[:all], 'phase header mismatch', 'expected the header diagnostic')
end

check 'phase contract is rejected: a manifest identity with no phase' do
  rows = (1..2).map { |i| "case-#{i}\tmech\tcase#{i}.bpp\t0\t\"hello\\n\"\t\"\"\t#{MECH_REF}" }
  result = mechanism('phasedoc-missing', engine_body: ENGINE_HELLO,
                     fixture: 'case1.bpp', extra_files: { 'case2.bpp' => "echo 2\n" }, rows: rows,
                     phases: [{ id: 'case-1', phase: 'artifact-run', fixture: 'case1.bpp' }])
  assert(!result[:status].success?, 'a manifest identity with no phase was accepted')
  assert_includes(result[:all], 'no phase declared for', 'expected the missing-phase diagnostic')
end

# --- policy: the default contract cannot be bypassed ------------------------

check 'POLICY: a custom manifest must declare its phases' do
  dir = File.join(WORK, 'policy-implicit')
  fixtures = File.join(dir, 'fixtures')
  FileUtils.mkdir_p(fixtures)
  File.write(File.join(fixtures, 'case.bpp'), "echo case\n")
  manifest = File.join(dir, 'manifest.tsv')
  File.write(manifest, "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref\ncase-1\tmech\tcase.bpp\t0\t\"\"\t\"\"\t#{MECH_REF}\n")
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                         '--sh-module', REAL_SH_MODULE, '--manifest', manifest,
                         '--fixture-root', fixtures, '--artifacts', File.join(dir, 'artifacts'), *CACHE_ARGS)
  assert(!status.success?, 'a custom manifest ran with no phase declaration')
  assert_includes(out + err, 'must declare its compiler phases', 'expected the missing-declaration diagnostic')
end

check 'POLICY: --artifact-only and --phases cannot be combined' do
  result = mechanism('policy-both', engine_body: ENGINE_HELLO,
                     phases: [{ id: 'case-1', phase: 'artifact-run', fixture: 'case.bpp' }],
                     args: ['--artifact-only'])
  assert(!result[:status].success?, 'both phase declarations were accepted at once')
  assert_includes(result[:all], 'mutually exclusive', 'expected the exclusivity diagnostic')
end

check 'POLICY: a default inventory manifest cannot be downgraded to --artifact-only' do
  # The bypass that would matter: it would silently turn the 15 semantic-reject
  # identities into artifact runs.
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                         '--sh-module', REAL_SH_MODULE,
                         '--manifest', File.join(ROOT, 'docs/lowering/go-profile-cases.tsv'),
                         '--fixture-root', File.join(ROOT, 'tests/lowering/go-profile'),
                         '--artifact-only', '--artifacts', File.join(WORK, 'policy-default-artifacts'), *CACHE_ARGS)
  assert(!status.success?, 'a default manifest was downgraded to an artifact-only contract')
  assert_includes(out + err, 'its phase contract is not optional', 'expected the bypass diagnostic')
end

check 'POLICY: a default inventory manifest fails closed without its phase contract' do
  default_phases = File.join(ROOT, 'docs/lowering/go-profile-phases.tsv')
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                         '--sh-module', REAL_SH_MODULE,
                         '--manifest', File.join(ROOT, 'docs/lowering/go-profile-cases.tsv'),
                         '--fixture-root', File.join(ROOT, 'tests/lowering/go-profile'),
                         '--artifacts', File.join(WORK, 'policy-nophase-artifacts'), *CACHE_ARGS)
  if File.file?(default_phases)
    # The contract has landed: the run must at least get past phase binding.
    assert(!(out + err).include?('the default phase contract is missing'), 'the landed default phase contract was not found')
    assert_includes(out, 'PHASE CONTRACT INVENTORY', 'the default phase contract was not validated against the whole inventory')
  else
    assert(!status.success?, 'a default manifest ran with no phase contract present')
    assert_includes(out + err, 'the default phase contract is missing', 'expected the fail-closed diagnostic')
  end
end

check 'POLICY: the default phase contract validates the 120/105/15 split' do
  candidate = default_phase_contract
  raise 'no default phase contract available; set S117_PHASES_CANDIDATE' unless candidate
  out, err, status = run({}, RUBY, RUNNER, '--inventory', '--phases', candidate)
  assert(status.success?, "the default phase contract did not validate:\n#{out}#{err}")
  assert_includes(out, 'INVENTORY OK: 120 cases across 2 manifests', 'inventory total')
  assert_includes(out, 'PHASE artifact-run 105', 'artifact-run count')
  assert_includes(out, 'PHASE semantic-reject 15', 'semantic-reject count')
  assert_includes(out, 'PHASE CONTRACT OK: 120 phase-aware cases = 105 artifact-run + 15 semantic-reject', 'combined phase line')
end

check 'POLICY: a changed split in the default pairing is rejected' do
  candidate = default_phase_contract
  raise 'no default phase contract available' unless candidate
  tampered = File.join(WORK, 'phases-split-tampered.tsv')
  text = File.read(candidate)
  # Flip exactly one semantic-reject identity to artifact-run.
  flipped = text.sub("\tsemantic-reject\t", "\tartifact-run\t")
  raise 'could not flip a phase for the tamper' if flipped == text
  File.write(tampered, flipped)
  out, err, status = run({}, RUBY, RUNNER, '--inventory', '--phases', tampered)
  assert(!status.success?, 'a changed 105/15 split was accepted')
  assert_includes(out + err, 'the pinned contract is', 'expected the split diagnostic')
end

puts 'go-profile contract: semantic-reject phase'

# --- the real positive ------------------------------------------------------

check 'SEMANTIC: an exact diagnostic rejection with no emission is certified' do
  result = semantic('semantic-positive')
  assert(result[:status].success?, "a correct semantic rejection was not certified:\n#{result[:all]}")
  assert_includes(result[:out], 'PHASE PASS sem-1: semantic-reject certified', 'expected the certification line')
  # Counted as a rejection, never as a native artifact.
  assert_includes(result[:out], '0/0 artifact executions, 1/1 certified semantic rejections', 'the counts must be reported separately')
  case_dir = File.join(result[:artifacts], 'mech', 'sem-1')
  assert(!File.exist?(File.join(case_dir, 'generated.one.go')), 'Go was emitted for a rejected source')
  assert(!File.exist?(File.join(case_dir, 'build')), 'a build tree was created for a rejected source')
  assert(!File.exist?(File.join(case_dir, 'artifact')), 'an artifact was produced for a rejected source')
  assert(File.file?(File.join(case_dir, 'transpile.one.stderr.raw')), 'the rejection diagnostic was not retained')
  assert(File.binread(File.join(case_dir, 'transpile.one.stderr.raw')) == SEM_DIAG, 'the retained diagnostic bytes are wrong')
  assert(File.file?(File.join(case_dir, 'interpreted.stderr.raw')), 'the interpreter observation was not retained')
end

check 'SEMANTIC: the certified rejection is not counted as an artifact execution' do
  result = semantic('semantic-count')
  assert(result[:status].success?, "expected success:\n#{result[:all]}")
  assert(!result[:out].include?('PARITY PASS sem-1'), 'a semantic rejection was reported as an artifact run')
  assert_includes(result[:out], 'semantic rejections build none', 'the result line must disclaim native artifacts')
end

# --- the traps --------------------------------------------------------------

check 'SEMANTIC: LOWER-EUNSUPPORTED is not a semantic rejection' do
  # Status 2, nothing emitted, and completely wrong: the transpiler gave up on
  # the construct instead of diagnosing the program.
  result = semantic('semantic-unsupported', cli_stderr: "LOWER-EUNSUPPORTED: construct not supported by the lowering bridge\n")
  assert(!result[:status].success?, 'LOWER-EUNSUPPORTED was accepted as a semantic rejection')
  assert_includes(result[:all], 'a LOWER-E* lowering error', 'expected the LOWER-E diagnostic')
end

check 'SEMANTIC: a bare line:col lowering type error is not a semantic rejection' do
  result = semantic('semantic-lowertype', cli_stderr: "2:2: LOWER-ETYPE: non-boolean condition in if statement\n")
  assert(!result[:status].success?, 'a raw LOWER-ETYPE position was accepted as a semantic rejection')
  assert(/a LOWER-E\* lowering error|bare line:col/.match?(result[:all]), "expected a non-semantic diagnostic reason:\n#{result[:all]}")
end

check 'SEMANTIC: a raw Go toolchain error is not a semantic rejection' do
  result = semantic('semantic-rawgo', cli_stderr: "# command-line-arguments\n./main.go:3:2: undefined: x\n")
  assert(!result[:status].success?, 'a raw Go error was accepted as a semantic rejection')
  assert_includes(result[:all], 'a raw Go toolchain error', 'expected the raw-Go diagnostic')
end

check 'SEMANTIC: an unprefixed error is not a semantic rejection outside the allowlist' do
  result = semantic('semantic-unprefixed', cli_stderr: "something went wrong\n", golden: "something went wrong\n",
                    engine_stderr: "something went wrong\n")
  assert(!result[:status].success?, 'an arbitrary unprefixed error was accepted')
  assert_includes(result[:all], 'is not a rendered BASHPP diagnostic', 'expected the identity diagnostic')
end

check 'SEMANTIC: the legacy rendering is accepted only for its own identity' do
  allowed = semantic('semantic-legacy-ok', id: 'undefined-receiver-neg', golden: LEGACY_DIAG)
  assert(allowed[:status].success?, "the allowlisted legacy rendering was rejected:\n#{allowed[:all]}")
  other = semantic('semantic-legacy-other', id: 'sem-other', golden: LEGACY_DIAG)
  assert(!other[:status].success?, 'the legacy rendering was accepted for an identity outside the allowlist')
  assert_includes(other[:all], 'is not a rendered BASHPP diagnostic', 'expected the identity diagnostic')
end

check 'SEMANTIC: a diagnostic positioned at the wrong path is rejected' do
  # "Normalizing" the origin away would hide a diagnostic pointing at the wrong
  # file, so the positioned path must be the original source.
  positioned = "generated.go: line 2: BASHPP-EIF-COND: if condition must be boolean, got Int\n"
  result = semantic('semantic-wrongpath', golden: positioned, engine_stderr: positioned)
  assert(!result[:status].success?, 'a diagnostic positioned at a generated path was accepted')
  assert_includes(result[:all], 'not at the original source', 'expected the origin diagnostic')
end

check 'SEMANTIC: a positioned diagnostic naming the original source is accepted' do
  positioned = "case.bpp: line 2: BASHPP-ESHORT-NONEW: no new variables on left side of :=\n"
  result = semantic('semantic-positioned-ok', golden: positioned, engine_stderr: positioned)
  assert(result[:status].success?, "a correctly positioned diagnostic was rejected:\n#{result[:all]}")
end

check 'SEMANTIC: a secondary positioned line is part of the contract' do
  two_line = "BASHPP-EBUILTIN-TYPE: cap argument must be an array or slice\n" \
             "case.bpp: line 2: BASHPP-ESHORT-NONEW: no new variables on left side of :=\n"
  ok = semantic('semantic-secondary-ok', golden: two_line, engine_stderr: two_line)
  assert(ok[:status].success?, "a two-line diagnostic was rejected:\n#{ok[:all]}")
  # Dropping the secondary line is a different diagnostic and must fail.
  partial = semantic('semantic-secondary-partial', golden: two_line,
                     cli_stderr: "BASHPP-EBUILTIN-TYPE: cap argument must be an array or slice\n",
                     engine_stderr: two_line)
  assert(!partial[:status].success?, 'a partial diagnostic was accepted')
  assert_includes(partial[:all], 'stderr does not match the manifest diagnostic', 'expected the byte-mismatch diagnostic')
end

check 'SEMANTIC: emitting Go while rejecting fails' do
  result = semantic('semantic-emit-go', emit_go: true)
  assert(!result[:status].success?, 'a rejection that emitted Go was accepted')
  assert_includes(result[:all], 'emitted Go for a rejected source', 'expected the emission diagnostic')
end

check 'SEMANTIC: emitting a source map while rejecting fails' do
  result = semantic('semantic-emit-map', emit_map: true)
  assert(!result[:status].success?, 'a rejection that emitted a source map was accepted')
  assert_includes(result[:all], 'emitted a source map for a rejected source', 'expected the map emission diagnostic')
end

check 'SEMANTIC: a wrong exit status fails even with the right diagnostic' do
  result = semantic('semantic-status', cli_status: 1)
  assert(!result[:status].success?, 'a rejection with the wrong status was accepted')
  assert_includes(result[:all], 'expected exit 2 but got 1', 'expected the status diagnostic')
end

check 'SEMANTIC: a nondeterministic rejection fails' do
  # The rejecting fake writes an attempt-dependent stream.
  dir = File.join(WORK, 'semantic-nondet')
  fixtures = File.join(dir, 'fixtures')
  FileUtils.mkdir_p(fixtures)
  File.write(File.join(fixtures, 'case.bpp'), "if 1 { echo x }\n")
  transpiler = File.join(dir, 'fake-transpiler')
  File.write(transpiler, <<~SH)
    #!/bin/sh
    for a in "$@"; do out="$a"; done
    case "$out" in
      *two*) printf '%s' 'BASHPP-EIF-COND: if condition must be boolean, got Bool
    ' >&2 ;;
      *) printf '%s' #{shell_quote(SEM_DIAG)} >&2 ;;
    esac
    exit 2
  SH
  FileUtils.chmod(0o755, transpiler)
  engine = File.join(dir, 'fake-engine')
  File.write(engine, "#!/bin/sh\n" + rejecting_engine(SEM_DIAG))
  FileUtils.chmod(0o755, engine)
  manifest = File.join(dir, 'manifest.tsv')
  File.write(manifest, "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref\n" +
                       semantic_rows('sem-1', 'case.bpp', SEM_DIAG).first + "\n")
  phases = phase_file(File.join(dir, 'phases.tsv'), [{ id: 'sem-1', phase: 'semantic-reject', fixture: 'case.bpp' }], fixtures)
  out, err, status = run({}, RUBY, RUNNER, '--bashy', transpiler, '--engine', engine, '--go', REAL_GO,
                         '--sh-module', REAL_SH_MODULE, '--manifest', manifest, '--fixture-root', fixtures,
                         '--phases', phases, '--artifacts', File.join(dir, 'artifacts'),
                         '--run-path', RUN_PATH, *CACHE_ARGS)
  assert(!status.success?, 'a nondeterministic rejection was accepted')
  assert_includes(out + err, 'the rejection is nondeterministic', 'expected the determinism diagnostic')
end

check 'SEMANTIC: an interpreter effect before the designated error fails' do
  result = semantic('semantic-effect', engine_before: "printf 'side\\n' > leaked.txt\n")
  assert(!result[:status].success?, 'an effect before the designated error was accepted')
  assert_includes(result[:all], 'left an effect before the designated error', 'expected the effect diagnostic')
  assert_includes(result[:all], 'leaked.txt', 'the diagnostic should name the leaked path')
end

check 'SEMANTIC: an interpreter that disagrees with the manifest fails' do
  result = semantic('semantic-interp', engine_stderr: "BASHPP-EIF-COND: different rendering\n")
  assert(!result[:status].success?, 'a disagreeing interpreter observation was accepted')
  assert_includes(result[:all], 'interpreted stderr does not match the manifest', 'expected the interpreter diagnostic')
end

check 'SEMANTIC: a truncated interpreter lifecycle cannot certify a rejection' do
  engine = "( exec >/dev/null 2>&1; sleep 8 ) &\n" + rejecting_engine(SEM_DIAG)
  result = mechanism('semantic-lifecycle', fixture: 'case.bpp', fixture_body: "if 1 { echo x }\n",
                     rows: semantic_rows('sem-1', 'case.bpp', SEM_DIAG),
                     phases: [{ id: 'sem-1', phase: 'semantic-reject', fixture: 'case.bpp' }],
                     reject: { status: 2, stdout: '', stderr: SEM_DIAG },
                     engine_body: engine, args: ['--timeout', '30'])
  assert(!result[:status].success?, 'a truncated interpreter lifecycle certified a rejection')
  assert_includes(result[:all], 'left a process alive in its own process group', 'expected the lifecycle diagnostic')
end

check 'SEMANTIC: an artifact-run identity still builds and runs' do
  # The other half of the phase policy: declaring a phase does not change what
  # an artifact-run case has to do.
  result = mechanism('phase-artifact-run', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     phases: [{ id: 'case-1', phase: 'artifact-run', fixture: 'case.bpp' }])
  assert(result[:status].success?, "an artifact-run case under an explicit phase failed:\n#{result[:all]}")
  assert_includes(result[:out], 'PARITY PASS case-1: artifact-run authenticated', 'expected the artifact-run pass line')
  assert_includes(result[:out], '1/1 artifact executions, 0/0 certified semantic rejections', 'expected the split counts')
  assert(File.file?(File.join(result[:artifacts], 'mech', 'case-1', 'artifact', 'lowered.bin')), 'no artifact was built')
end

puts 'go-profile contract: multi-case behaviour'

check 'every selected case runs even when earlier cases fail' do
  rows = (1..4).map do |index|
    "case-#{index}\tmech\tcase#{index}.bpp\t0\t\"hello\\n\"\t\"\"\tsh/interp/bashpp_test.go:TestBashPPMechanism/#{index}"
  end
  dir = File.join(WORK, 'continuation')
  fixtures = File.join(dir, 'fixtures')
  FileUtils.mkdir_p(fixtures)
  (1..4).each { |index| File.write(File.join(fixtures, "case#{index}.bpp"), "echo #{index}\n") }
  result = mechanism('continuation-run', go_source: GO_ERROR2, engine_body: ENGINE_ERROR2,
                     fixture: 'case1.bpp', rows: rows)
  (2..4).each { |index| File.write(File.join(result[:fixtures], "case#{index}.bpp"), "echo #{index}\n") }
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', File.join(result[:dir], 'fake-transpiler'),
                         '--engine', File.join(result[:dir], 'fake-engine'),
                         '--go', REAL_GO, '--sh-module', REAL_SH_MODULE,
                         '--manifest', result[:manifest], '--fixture-root', result[:fixtures],
                         '--artifacts', File.join(result[:dir], 'artifacts-all'), '--artifact-only',
                         '--run-path', RUN_PATH, '--timeout', '20', *CACHE_ARGS)
  assert(!status.success?, 'a run with four failing cases reported success')
  assert_includes(out + err, 'failures across 4 selected cases', 'expected the aggregate failure line')
  assert_includes(out + err, '4 failures', 'all four cases should have been evaluated')
  (1..4).each do |index|
    path = File.join(result[:dir], 'artifacts-all', 'mech', "case-#{index}", 'evidence.jsonl')
    assert(File.file?(path), "case-#{index} did not run: no evidence ledger")
  end
end

check 'a case filter that selects nothing is rejected' do
  result = mechanism('filter-empty', go_source: GO_HELLO, engine_body: ENGINE_HELLO, args: ['--case', 'nope-*'])
  assert(!result[:status].success?, 'an empty selection was accepted')
  assert_includes(result[:all], 'selected zero of', 'expected the empty-selection diagnostic')
end

check 'a subset selection is reported as a subset, not as full parity' do
  rows = (1..2).map do |index|
    "case-#{index}\tmech\tcase#{index}.bpp\t0\t\"hello\\n\"\t\"\"\tsh/interp/bashpp_test.go:TestBashPPMechanism/#{index}"
  end
  result = mechanism('subset', go_source: GO_HELLO, engine_body: ENGINE_HELLO,
                     fixture: 'case1.bpp', extra_files: { 'case2.bpp' => "echo 2\n" },
                     rows: rows, args: ['--case', 'case-1'])
  assert(result[:status].success?, "subset run failed:\n#{result[:all]}")
  assert_includes(result[:out], 'GO-PROFILE PARITY SUBSET PASS: 1/2', 'expected a subset pass line')
  assert(!result[:out].include?('GO-PROFILE PARITY PASS'), 'a subset must never be reported as full parity')
end

puts 'go-profile contract: ACCEPTANCE against the real toolchain'

def acceptance(name, args: [])
  dir = File.join(WORK, name)
  fixtures = File.join(dir, 'fixtures')
  FileUtils.mkdir_p(fixtures)
  File.write(File.join(fixtures, 'smoke.bpp'), "var x = 10\nprintln(x)\n")
  manifest = File.join(dir, 'manifest.tsv')
  File.write(manifest, <<~TSV)
    # ACCEPTANCE manifest: real bashy transpile CLI, real engine, real pinned Go.
    id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref
    smoke-1\tsmoke\tsmoke.bpp\t0\t"10\\n"\t""\tsh/interp/bashpp_test.go:TestBashPPPrintln
  TSV
  artifacts = File.join(dir, 'artifacts')
  out, err, status = run({}, RUBY, RUNNER,
                         '--bashy', REAL_BASHY, '--engine', REAL_ENGINE, '--go', REAL_GO,
                         '--sh-module', REAL_SH_MODULE, '--manifest', manifest,
                         '--fixture-root', fixtures, '--artifacts', artifacts,
                         '--artifact-only', *CACHE_ARGS, *args)
  { out: out, err: err, status: status, all: out + err, artifacts: artifacts }
end

check 'ACCEPTANCE: the real CLI lowers `var x = 10; println(x)` to a matching artifact' do
  result = acceptance('acceptance-plain')
  assert(result[:status].success?, "real CLI acceptance failed:\n#{result[:all]}")
  assert_includes(result[:out], 'GO-PROFILE PARITY PASS: 1/1', 'expected a full pass')
  records = ledger(result, 'smoke', 'smoke-1')
  map = phase(records, 'source-map')
  assert(map['schema'] == 'bashy-transpile-map-v1', "the real CLI map schema was #{map['schema'].inspect}")
  assert(map['origin'] == 'smoke.bpp', "the real CLI map origin was #{map['origin'].inspect}")
  assert(map['mappings'] >= 1, 'the real CLI map carried no coordinates')
  assert(map['go_digest'] == "sha256:#{map['generated_go_sha256']}", 'the real CLI map is not digest-bound')
  assert(File.binread(File.join(result[:artifacts], 'smoke', 'smoke-1', 'compiled.stdout.raw')) == "10\n",
         'the compiled artifact did not print 10')
  assert(File.binread(File.join(result[:artifacts], 'smoke', 'smoke-1', 'interpreted.stdout.raw')) == "10\n",
         'the interpreter did not print 10')
end

check 'ACCEPTANCE: the same case passes --typed-only with an empty PATH' do
  result = acceptance('acceptance-typed', args: ['--typed-only'])
  assert(result[:status].success?, "real CLI typed-only acceptance failed:\n#{result[:all]}")
  records = ledger(result, 'smoke', 'smoke-1')
  compiled = phase(records, 'compiled-run')
  assert(compiled['observation']['environment']['profile']['PATH'] == '', 'the typed artifact was given a PATH')
  assert(compiled['typed_only']['package'] == 'main', 'the typed artifact is not package main')
end

puts
if FAILURES.empty?
  puts "go-profile contract PASS: #{CHECKS.length} checks"
  exit 0
end
warn "go-profile contract FAIL: #{FAILURES.length} of #{CHECKS.length + FAILURES.length} checks failed"
FAILURES.each { |failure| warn "  - #{failure}" }
exit 1
