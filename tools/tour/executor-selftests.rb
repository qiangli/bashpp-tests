#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Selftests for the tour three-mode executor and its offline gate.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# Two layers:
#
#   UNIT   — the pure decision functions in tools/tour/executor.rb: contract
#            loading, the phase-migration bridge, argv rendering, stage and
#            observation scoring, source-map validation, manifest-based
#            candidate authentication and the independent normalization audit.
#
#   GATE   — tools/tour/executor-gate.rb is executed as a real subprocess
#            against a synthetic 97-row fixture tree (93 applicable + 4
#            build-only, 291 observations, one declared-volatile row with a
#            native oracle). The fixture is built to PASS, which proves the
#            gate is capable of passing and is not merely always red; each
#            subsequent case mutates exactly one thing and requires the gate to
#            reject it with the expected finding.
#
# The mutations cover the failure classes story #4 names — missing, PLANNED,
# unexpected N/A and mismatched — plus the forgery classes the sprint-118 plan
# adds: substituted stages, executed `norun` bodies, forged commands, unbound
# candidates, source maps that do not describe their own artifact, blanket
# normalization, over-strong isolation claims, a private capture path, a forged
# semantic verdict, a fabricated oracle and tampered roots.
#
# The comparators themselves are driven negatively in
# tools/tour/semantics-selftests.rb.

require 'fileutils'
require 'tmpdir'
require_relative 'executor'

ROOT = File.expand_path('../..', __dir__)
GATE = File.join(ROOT, 'tools/tour/executor-gate.rb')
CONTRACT_PATH = File.join(ROOT, 'docs/tour/executor-contract.tsv')
CANDIDATE_PATH = File.join(ROOT, 'docs/tour/candidate.tsv')
MIGRATION_PATH = File.join(ROOT, 'docs/tour/phase-migration.tsv')

PASSED = []
FAILED = []
FIXTURE_DIR = []

def check(name)
  result = yield
  if result == true
    PASSED << name
  else
    FAILED << "#{name}: #{result}"
  end
rescue StandardError => e
  FAILED << "#{name}: raised #{e.class}: #{e.message}"
end

def expect(condition, message)
  condition ? true : message
end

# ============================================================ UNIT ==========

CONTRACT = TourExecutor.load_contract(CONTRACT_PATH)
MIGRATION = TourExecutor.load_phase_migration(MIGRATION_PATH)

check('contract: covers both applicabilities in all three modes') do
  missing = TourExecutor::EXECUTABLE_APPLICABILITIES.product(TourExecutor::MODES).reject { |k| CONTRACT.key?(k) }
  expect(missing.empty?, "missing #{missing.inspect}")
end

check('contract: interpreted mode carries --bashpp --source=go (not bare shell dispatch)') do
  argv = CONTRACT.fetch(%w[applicable_go_program interpreted])['stages'][0]['argv_template']
  expect(argv.include?('--bashpp') && argv.include?('--source=go'), argv.inspect)
end

check('contract: transpile carries --bashpp (transpile.go rejects it otherwise) and --source=go') do
  argv = CONTRACT.fetch(%w[applicable_go_program compiled])['stages'][0]['argv_template']
  expect(argv[0..3] == %w[{BASHY} transpile --bashpp --source=go], argv.inspect)
end

check('contract: transpile requests a source map artifact') do
  stage = CONTRACT.fetch(%w[applicable_go_program compiled])['stages'][0]
  expect(stage['argv_template'].include?('--map') && stage['produces'].sort == %w[go map], stage.inspect)
end

check('contract: build-only interpreted uses semantic --check, never -n') do
  stage = CONTRACT.fetch(%w[build_only_go_program interpreted])['stages'][0]
  expect(stage['stage'] == 'check' && stage['argv_template'].include?('--check') &&
         !stage['argv_template'].include?('-n') && stage['execute_body'] == false, stage.inspect)
end

check('contract: build-only compiled stops after build, never runs the body') do
  stages = CONTRACT.fetch(%w[build_only_go_program compiled])['stages']
  expect(stages.map { |s| s['stage'] } == %w[transpile build] && stages.none? { |s| s['execute_body'] }, stages.inspect)
end

check('contract: build-only baseline builds without executing') do
  stages = CONTRACT.fetch(%w[build_only_go_program baseline])['stages']
  expect(stages.map { |s| s['stage'] } == %w[build] && stages.none? { |s| s['execute_body'] }, stages.inspect)
end

check('contract: applicable baseline is go build + native artifact, never `go run`') do
  stages = CONTRACT.fetch(%w[applicable_go_program baseline])['stages']
  expect(stages.map { |s| s['stage'] } == %w[build run] && !stages[0]['argv_template'].include?('run'), stages.inspect)
end

# --- phase migration -------------------------------------------------------

check('phase migration: no build-only mode may execute a body') do
  offenders = MIGRATION.select { |(applicability, _), row| applicability == 'build_only_go_program' && row['executes_body'] }
  expect(offenders.empty?, offenders.keys.inspect)
end

check('phase migration: every current build-only phase is explicitly a no-run phase') do
  phases = MIGRATION.select { |(a, _), _| a == 'build_only_go_program' }.values.map { |r| r['current_phase'] }
  expect(phases.all? { |p| p.end_with?('-no-run') }, phases.inspect)
end

check('phase migration: the historical tokens are preserved verbatim') do
  historical = MIGRATION.select { |(a, _), _| a == 'build_only_go_program' }.values.map { |r| r['historical_token'] }.sort
  expect(historical == ['go-test-or-build', 'parse-or-run', 'transpile-build-run'], historical.inspect)
end

check('phase migration: agrees with the real contract') do
  items = [{ 'path' => 'x.go', 'applicability' => 'applicable_go_program',
             'differential_schema' => 'baseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run' },
           { 'path' => 'y.go', 'applicability' => 'build_only_go_program',
             'differential_schema' => 'baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build-run' }]
  failures = TourExecutor.phase_migration_failures(MIGRATION, CONTRACT, items)
  expect(failures.empty?, failures.inspect)
end

check('phase migration: a rewritten historical inventory token is a finding') do
  items = [{ 'path' => 'y.go', 'applicability' => 'build_only_go_program',
             'differential_schema' => 'baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build' }]
  failures = TourExecutor.phase_migration_failures(MIGRATION, CONTRACT, items)
  expect(failures.any? { |f| f.start_with?('phase_migration:historical_drift') }, failures.inspect)
end

check('phase migration: a contract that reintroduces a body for a norun row is a finding') do
  widened = CONTRACT.merge(%w[build_only_go_program compiled] =>
    { 'phase' => 'transpile-build-no-run',
      'stages' => CONTRACT.fetch(%w[build_only_go_program compiled])['stages'] +
                  [{ 'index' => 2, 'stage' => 'run', 'argv_template' => ['{BIN}'], 'produces' => [], 'execute_body' => true }] })
  failures = TourExecutor.phase_migration_failures(MIGRATION, widened, [])
  expect(failures.any? { |f| f.start_with?('phase_migration:body_policy') }, failures.inspect)
end

check('render_argv: substitutes every placeholder') do
  argv = TourExecutor.render_argv(%w[{BASHY} --bashpp --source=go {SRC}], 'BASHY' => '/b', 'SRC' => 'a.go')
  expect(argv == ['/b', '--bashpp', '--source=go', 'a.go'], argv.inspect)
end

check('render_argv: an unknown placeholder is a hard error, never a literal argument') do
  begin
    TourExecutor.render_argv(%w[{NOPE}], {})
    'no error raised'
  rescue RuntimeError
    true
  end
end

# --- stage scoring ---------------------------------------------------------

def stage(overrides = {})
  {
    'index' => 0, 'stage' => 'run', 'execute_body' => true, 'command' => %w[/bin/true],
    'spawned' => true, 'state' => 'exited', 'exit' => 0, 'descendants_survived' => false, 'artifacts' => {},
    'normalized' => { 'stdout' => { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => TourExecutor.sha('') },
                      'stderr' => { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => TourExecutor.sha('') } }
  }.merge(overrides)
end

check('stage_failure: clean stage passes') { expect(TourExecutor.stage_failure(stage).nil?, 'expected nil') }
check('stage_failure: nonzero exit fails') { expect(TourExecutor.stage_failure(stage('exit' => 2)) == 'exit:2', 'x') }
check('stage_failure: deadline fails') { expect(TourExecutor.stage_failure(stage('state' => 'deadline')) == 'deadline', 'x') }
check('stage_failure: launch failure fails') { expect(TourExecutor.stage_failure(stage('spawned' => false)) == 'launch_failure', 'x') }
check('stage_failure: a leaked process group fails even with exit 0') do
  s = stage('state' => 'process_leak')
  expect(TourExecutor.stage_failure(s) == 'state:process_leak', TourExecutor.stage_failure(s).inspect)
end
check('stage_failure: a surviving descendant fails even with a clean exit') do
  s = stage('descendants_survived' => true)
  expect(TourExecutor.stage_failure(s) == 'descendants_survived', TourExecutor.stage_failure(s).inspect)
end
check('stage_failure: a declared artifact that was not produced fails') do
  s = stage('artifacts' => { 'bin' => { 'present' => false } })
  expect(TourExecutor.stage_failure(s) == 'missing_artifact:bin', TourExecutor.stage_failure(s).inspect)
end
check('stage_failure: a no-body stage that printed program output fails') do
  s = stage('execute_body' => false, 'normalized' => { 'stdout' => { 'valid_utf8' => true, 'bytes' => 5, 'sha256' => 'x' },
                                                      'stderr' => { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => 'y' } })
  expect(TourExecutor.stage_failure(s) == 'body_executed', TourExecutor.stage_failure(s).inspect)
end
check('stage_failure: invalid UTF-8 is rejected, never transliterated') do
  s = stage('normalized' => { 'stdout' => { 'valid_utf8' => false, 'bytes' => nil, 'sha256' => nil },
                              'stderr' => { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => 'y' } })
  expect(TourExecutor.stage_failure(s) == 'invalid_utf8', TourExecutor.stage_failure(s).inspect)
end

check('authoritative_index: the FIRST failing stage owns the verdict') do
  stages = [stage('stage' => 'transpile', 'index' => 0), stage('stage' => 'build', 'index' => 1, 'exit' => 1), stage('stage' => 'run', 'index' => 2)]
  expect(TourExecutor.authoritative_index(stages) == 1, TourExecutor.authoritative_index(stages).inspect)
end
check('authoritative_index: an all-green pipeline is owned by its last stage') do
  stages = [stage('index' => 0), stage('index' => 1), stage('index' => 2)]
  expect(TourExecutor.authoritative_index(stages) == 2, 'x')
end

# --- source maps -----------------------------------------------------------

def map_stage(summary_overrides = {}, generated_sha: 'd' * 64)
  summary = { 'schema_version' => 'bashy-transpile-map-v1', 'origin' => 'a/b.go',
              'go_digest' => "sha256:#{generated_sha}", 'mappings' => 12,
              'source_files' => ['a/b.go'], 'positioned' => true }.merge(summary_overrides)
  stage('stage' => 'transpile', 'execute_body' => false,
        'artifacts' => { 'go' => { 'present' => true, 'sha256' => generated_sha },
                         'map' => { 'present' => true, 'sha256' => 'e' * 64, 'source_map' => summary } })
end

check('source_map: a well-formed map for its own artifact passes') do
  expect(TourExecutor.source_map_failures(map_stage, 'a/b.go').empty?, TourExecutor.source_map_failures(map_stage, 'a/b.go').inspect)
end
check('source_map: a map whose generation digest is not this artifact fails') do
  f = TourExecutor.source_map_failures(map_stage('go_digest' => "sha256:#{'9' * 64}"), 'a/b.go')
  expect(f.include?('source_map_generation_digest'), f.inspect)
end
check('source_map: a map pointing at ANOTHER original source fails') do
  f = TourExecutor.source_map_failures(map_stage('origin' => 'other.go', 'source_files' => ['other.go']), 'a/b.go')
  expect(f.any? { |x| x.start_with?('source_map_origin') }, f.inspect)
end
check('source_map: an empty mapping list fails') do
  f = TourExecutor.source_map_failures(map_stage('mappings' => 0), 'a/b.go')
  expect(f.include?('source_map_empty'), f.inspect)
end
check('source_map: unpositioned mappings fail') do
  f = TourExecutor.source_map_failures(map_stage('positioned' => false), 'a/b.go')
  expect(f.include?('source_map_unpositioned'), f.inspect)
end
check('source_map: a wrong schema version fails') do
  f = TourExecutor.source_map_failures(map_stage('schema_version' => 'other/v9'), 'a/b.go')
  expect(f.any? { |x| x.start_with?('source_map_schema') }, f.inspect)
end
check('source_map: an absent map fails') do
  s = stage('stage' => 'transpile', 'artifacts' => { 'map' => { 'present' => false } })
  expect(TourExecutor.source_map_failures(s, 'a/b.go') == ['source_map_missing'], 'x')
end

# --- normalization audit ---------------------------------------------------

check('audit_normalize: collapses CRLF and masks pointer-sized hex only') do
  out = TourExecutor.audit_normalize("a\r\nb 0xdeadbeefcafe 0x1f\n".b)
  expect(out == "a\nb 0xADDR 0x1f\n", out.inspect)
end
check('audit_normalize: leaves timestamps, numbers and paths intact (no blanket masking)') do
  raw = "2026-09-08T12:00:00Z 42 /tmp/x/y\n".b
  expect(TourExecutor.audit_normalize(raw) == raw.force_encoding('UTF-8'), 'stream was altered')
end
check('audit_normalize: rejects invalid UTF-8 instead of replacing it') do
  expect(TourExecutor.audit_normalize("\xff\xfe".b).nil?, 'expected nil')
end

# --- candidate authentication ----------------------------------------------

COMPONENTS = TourExecutor.load_candidate_contract(CANDIDATE_PATH).freeze

def candidate_fixture(overrides = {})
  repositories = COMPONENTS.map { |c| { 'name' => c['component'], 'path' => "/src/#{c['component']}", 'commit' => 'a' * 40 } }
  {
    'binding' => 'manifest:launcher+payload+repository-commits',
    'manifest_sha256' => 'm' * 64,
    'binaries' => { 'launcher' => { 'present' => true, 'sha256' => 'a' * 64, 'path' => '/b/bashy' },
                    'payload' => { 'present' => true, 'sha256' => 'b' * 64, 'path' => '/b/bashy.real' } },
    'repositories' => repositories,
    'components' => COMPONENTS.map { |c| c.merge('bound' => true, 'commit' => 'a' * 40, 'dir' => "/src/#{c['component']}") }
  }.merge(overrides)
end

check('candidate: the declared component set includes every replaced dependency, filebrowser included') do
  expect(COMPONENTS.map { |c| c['component'] }.sort == %w[bashy coreutils filebrowser readline sh],
         COMPONENTS.map { |c| c['component'] }.inspect)
end
check('candidate: a manifest-authenticated Makefile build is ACCEPTED (no release tag required)') do
  reasons = TourExecutor.candidate_failures(candidate_fixture)
  expect(reasons.empty?, reasons.inspect)
end
check('candidate: a declared component missing from the manifest fails') do
  c = candidate_fixture
  c['components'] = c['components'].map { |x| x['component'] == 'filebrowser' ? x.merge('bound' => false, 'commit' => nil) : x }
  expect(TourExecutor.candidate_failures(c).include?('candidate:unbound:filebrowser'), TourExecutor.candidate_failures(c).inspect)
end
check('candidate: a manifest repository nobody declared fails') do
  c = candidate_fixture
  c['repositories'] += [{ 'name' => 'surprise', 'path' => '/src/surprise', 'commit' => 'c' * 40 }]
  expect(TourExecutor.candidate_failures(c).include?('candidate:undeclared_repository:surprise'), 'x')
end
check('candidate: a truncated revision is not a binding') do
  c = candidate_fixture
  c['repositories'][1] = c['repositories'][1].merge('commit' => 'abc1234')
  expect(TourExecutor.candidate_failures(c).include?('candidate:unbound_revision:sh'), 'x')
end
check('candidate: a missing .real payload fails (launcher digest alone is not a binding)') do
  c = candidate_fixture
  c['binaries'] = c['binaries'].merge('payload' => { 'present' => false, 'sha256' => nil })
  expect(TourExecutor.candidate_failures(c).include?('candidate:missing_payload'), 'x')
end
check('candidate: a frozen commit that does not match the manifest fails') do
  c = candidate_fixture
  c['components'] = c['components'].map { |x| x['component'] == 'bashy' ? x.merge('frozen_commit' => 'd' * 40) : x }
  expect(TourExecutor.candidate_failures(c).include?('candidate:frozen_mismatch:bashy'), 'x')
end
check('candidate: a candidate that was not manifest-authenticated fails') do
  c = candidate_fixture('binding' => 'source-commits+makefile-launcher+payload-digests')
  expect(TourExecutor.candidate_failures(c).include?('candidate:unauthenticated_manifest'), 'x')
end

# ============================================================ GATE ==========
#
# A synthetic 97-row fixture tree. Nothing is executed: the gate is a pure
# offline auditor, so a fixture only needs internally consistent files and a
# ledger. Every reference file the gate re-derives from is written here, and
# the CONTRACT, MIGRATION, NORMALIZER and the shared capture library are copies
# of the real ones.

APPLICABLE_PATHS = (0...TourExecutor::APPLICABLE_ROWS).map { |i| format('_content/tour/fixture/prog-%03d.go', i) }
NORUN_PATHS = (0...TourExecutor::BUILD_ONLY_ROWS).map { |i| format('_content/tour/fixture/norun-%d.go', i) }
VOLATILE_PATH = APPLICABLE_PATHS[0]
SCHEMA_FOR = {
  'applicable_go_program' => 'baseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run',
  'build_only_go_program' => 'baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build-run'
}.freeze

def fixture_items
  APPLICABLE_PATHS.map { |p| { 'path' => p, 'applicability' => 'applicable_go_program' } } +
    NORUN_PATHS.map { |p| { 'path' => p, 'applicability' => 'build_only_go_program' } }
end

def fixture_stdout(path)
  "#{File.basename(path, '.go')} output\n".b
end

def fixture_source(path)
  "package main // #{path}\n".b
end

def build_fixture(dir)
  FileUtils.mkdir_p([File.join(dir, 'docs/tour'), File.join(dir, 'tests/tour'),
                     File.join(dir, 'tools/tour'), File.join(dir, 'tools/corpus')])
  FileUtils.cp(CONTRACT_PATH, File.join(dir, 'docs/tour/executor-contract.tsv'))
  FileUtils.cp(CANDIDATE_PATH, File.join(dir, 'docs/tour/candidate.tsv'))
  FileUtils.cp(MIGRATION_PATH, File.join(dir, 'docs/tour/phase-migration.tsv'))
  FileUtils.cp(File.join(ROOT, 'tools/tour/normalize.rb'), File.join(dir, 'tools/tour/normalize.rb'))
  FileUtils.cp(File.join(ROOT, 'tools/tour/semantics.rb'), File.join(dir, 'tools/tour/semantics.rb'))
  FileUtils.cp(File.join(ROOT, 'tools/corpus/executor.rb'), File.join(dir, 'tools/corpus/executor.rb'))

  inventory_rows = fixture_items.map do |item|
    source = fixture_source(item['path'])
    [item['path'], 'lesson_play_program', 'n/a', item['applicability'], 'exception:none',
     SCHEMA_FOR.fetch(item['applicability']), source.bytesize.to_s, TourExecutor.sha(source)]
  end
  inventory_body = inventory_rows.map { |f| f.join("\t") }.join("\n") + "\n"
  File.write(File.join(dir, 'tests/tour/inventory.tsv'), "# fixture\n#{inventory_body}")
  data_sha = TourExecutor.sha(inventory_body)

  results_rows = fixture_items.map do |item|
    row = [item['path'], item['applicability'], '0', '0', '444']
    if item['applicability'] == 'applicable_go_program'
      out = fixture_stdout(item['path'])
      row += ['go-run', '0', '0', out.bytesize.to_s, TourExecutor.sha(out), '0', TourExecutor.sha(''.b), 'strict', 'pass']
    else
      row += ['go-test-or-build', '0', '-', '-', '-', '-', '-', '-', 'pass']
    end
    row
  end
  File.write(File.join(dir, 'tests/tour/results.tsv'), "# fixture\n" + results_rows.map { |r| r.join("\t") }.join("\n") + "\n")

  File.write(File.join(dir, 'docs/tour/pin.tsv'),
             "# fixture\nfixture.example/website\tv0.0.0\tdeadbeef\th1:x=\tBSD-3-Clause\tfixture\t#{inventory_rows.length}\t#{data_sha}\n")
  File.write(File.join(dir, 'docs/tour/toolchain.tsv'),
             "# fixture\ndarwin\tarm64\tgo1.27.0\tgo version go1.27.0 darwin/arm64\t#{'c' * 64}\tfixture\tfixture\n")
  File.write(File.join(dir, 'docs/tour/helpers.tsv'),
             "# fixture\ngolang.org/x/tour\tv0.1.0\tBSD-3-Clause\th1:mod=\th1:zip=\tpic,reader,tree,wc\tfixture\n")
  license = "BSD fixture license\n".b
  File.write(File.join(dir, 'docs/tour/corpus.tsv'),
             "# fixture\ntour\ttour/LICENSE\t#{license.bytesize}\t#{TourExecutor.sha(license)}\t97\t98\tfixture\n")
  File.write(File.join(dir, 'docs/tour/baseline-pin.tsv'), "# fixture\nfixture\n")
  # One declared-volatile fixture row, adjudicated by the real `line_set`
  # comparator against a real oracle record.
  File.write(File.join(dir, 'docs/tour/volatility.tsv'),
             "# fixture\n#{VOLATILE_PATH}\tfixture map order\tline set comparison\n")
  params = JSON.generate('lines' => [fixture_stdout(VOLATILE_PATH).chomp])
  File.write(File.join(dir, 'docs/tour/semantics.tsv'),
             "# fixture\n#{VOLATILE_PATH}\tline_set\t#{TourExecutor.sha(fixture_source(VOLATILE_PATH))}\tnot_required\tfixture map order\t#{params}\n")
  { 'dir' => dir, 'inventory_data_sha256' => data_sha, 'inventory_rows' => inventory_rows.length }
end

def normalized_for(raw)
  out = TourExecutor.audit_normalize(raw)
  return { 'valid_utf8' => false, 'bytes' => nil, 'sha256' => nil } if out.nil?
  { 'valid_utf8' => true, 'bytes' => out.bytesize, 'sha256' => TourExecutor.sha(out) }
end

CLOCK = { 'now' => Time.new(2026, 9, 8, 12, 0, 0).to_f }
def next_stamp
  CLOCK['now'] += 0.5
end

def fixture_stage(spec, argv, mode, stdout: ''.b, stderr: ''.b, artifacts: nil, path: nil)
  generated_sha = TourExecutor.sha("generated:#{path}")
  produced = artifacts || spec['produces'].to_h do |name|
    record = { 'present' => true, 'bytes' => 10, 'sha256' => name == 'go' ? generated_sha : TourExecutor.sha("#{name}:#{path}"),
               'path' => File.basename(argv[spec['argv_template'].index({ 'go' => '{OUT_GO}', 'map' => '{OUT_MAP}', 'bin' => '{BIN}' }.fetch(name))]) }
    if name == 'map'
      record['source_map'] = { 'schema_version' => 'bashy-transpile-map-v1', 'origin' => path,
                               'go_digest' => "sha256:#{generated_sha}", 'mappings' => 12,
                               'source_files' => [path], 'positioned' => true }
    end
    [name, record]
  end
  cwd = if !spec['execute_body'] then 'module'
        elsif mode == 'interpreted' then 'module'
        else 'runtime'
        end
  path_env = spec['execute_body'] ? '' : '/usr/bin:/bin'
  record = {
    'index' => spec['index'], 'stage' => spec['stage'], 'execute_body' => spec['execute_body'],
    'command' => argv, 'cwd' => cwd, 'path_env' => path_env,
    'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil, 'descendants_survived' => false,
    'duration_ms' => 1, 'started_at' => next_stamp, 'finished_at' => next_stamp,
    'artifacts' => produced,
    'raw' => { 'stdout_base64' => Base64.strict_encode64(stdout), 'stdout_bytes' => stdout.bytesize,
               'stderr_base64' => Base64.strict_encode64(stderr), 'stderr_bytes' => stderr.bytesize },
    'logs' => { 'stdout_sha256' => TourExecutor.sha(stdout), 'stderr_sha256' => TourExecutor.sha(stderr) },
    'normalized' => { 'stdout' => normalized_for(stdout), 'stderr' => normalized_for(stderr) },
    'masking' => { 'stdout' => TourExecutor.masking_report(stdout, normalized_for(stdout)['bytes']),
                   'stderr' => TourExecutor.masking_report(stderr, normalized_for(stderr)['bytes']) }
  }
  if spec['execute_body']
    record['input_absence'] = { 'scope' => TourExecutor::INPUT_ABSENCE_SCOPE, 'cwd' => cwd,
                                'path_env' => '', 'os_sandbox' => false }
  end
  record
end

GO_PATH = '/fixture/go'
BASHY_PATH = '/fixture/bashy'

def build_ledger(fixture)
  CLOCK['now'] = Time.new(2026, 9, 8, 12, 0, 0).to_f
  run_from = CLOCK['now']
  dir = fixture['dir']
  sha_of = ->(rel) { TourExecutor.sha(File.binread(File.join(dir, rel))) }
  components = TourExecutor.load_candidate_contract(File.join(dir, 'docs/tour/candidate.tsv'))
  repositories = components.map { |c| { 'name' => c['component'], 'path' => "/fixture/#{c['component']}", 'commit' => 'a' * 40 } }
  candidate = {
    'binding' => 'manifest:launcher+payload+repository-commits',
    'authenticated_by' => 'Corpus.authenticate_candidate (tools/corpus/executor.rb)',
    'manifest_path' => '/fixture/candidate.json', 'manifest_sha256' => 'm' * 64,
    'frontend_version' => 'gosource-v1', 'build_recipe' => 'make build BASHY_GOSOURCE=1',
    'manifest_status' => 'fixture',
    'version_line' => 'bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-dev (abc1234)',
    'binaries' => { 'launcher' => { 'path' => BASHY_PATH, 'present' => true, 'bytes' => 1, 'sha256' => 'a' * 64 },
                    'payload' => { 'path' => "#{BASHY_PATH}.real", 'present' => true, 'expected' => true, 'bytes' => 2, 'sha256' => 'b' * 64 } },
    'repositories' => repositories,
    'components' => components.map { |c| c.merge('bound' => true, 'dir' => "/fixture/#{c['component']}", 'commit' => 'a' * 40) },
    'contract_sha256' => sha_of.call('docs/tour/candidate.tsv')
  }
  semantics = TourSemantics.load_table(File.join(dir, 'docs/tour/semantics.tsv'))
  manifest = {
    'type' => 'manifest', 'schema' => TourExecutor::SCHEMA, 'generated_by' => 'fixture', 'partial' => false,
    'evidence_root' => '/fixture/evidence',
    'capture_implementation' => TourExecutor::CAPTURE_IMPLEMENTATION,
    'capture_library_sha256' => sha_of.call('tools/corpus/executor.rb'),
    'story' => { 'sprint' => 118, 'story' => 4, 'story_id' => '759341a95870' },
    'contract' => { 'path' => 'docs/tour/executor-contract.tsv', 'sha256' => sha_of.call('docs/tour/executor-contract.tsv') },
    'phase_migration' => { 'path' => 'docs/tour/phase-migration.tsv', 'sha256' => sha_of.call('docs/tour/phase-migration.tsv'), 'rows' => 6 },
    'semantics' => { 'path' => 'docs/tour/semantics.tsv', 'sha256' => sha_of.call('docs/tour/semantics.tsv'),
                     'gate_effect' => 'semantic-comparator', 'version' => TourSemantics::VERSION, 'rows' => 1,
                     'oracle_repeats' => 7, 'min_oracle_runs' => TourSemantics::MIN_ORACLE_RUNS,
                     'library_sha256' => sha_of.call('tools/tour/semantics.rb') },
    'inventory' => { 'path' => 'tests/tour/inventory.tsv', 'sha256' => sha_of.call('tests/tour/inventory.tsv'),
                     'rows' => fixture['inventory_rows'],
                     'executable_programs' => TourExecutor::DENOMINATOR, 'applicable' => TourExecutor::APPLICABLE_ROWS,
                     'build_only' => TourExecutor::BUILD_ONLY_ROWS, 'data_sha256' => fixture['inventory_data_sha256'] },
    'accepted_baseline' => { 'path' => 'tests/tour/results.tsv', 'sha256' => sha_of.call('tests/tour/results.tsv'),
                             'pin' => 'docs/tour/baseline-pin.tsv', 'pin_sha256' => sha_of.call('docs/tour/baseline-pin.tsv') },
    'source_pin' => { 'path' => 'docs/tour/pin.tsv', 'sha256' => sha_of.call('docs/tour/pin.tsv') },
    'corpus' => { 'path' => 'docs/tour/corpus.tsv', 'sha256' => sha_of.call('docs/tour/corpus.tsv') },
    'go' => { 'path' => GO_PATH, 'identity' => 'go version go1.27.0 darwin/arm64', 'sha256' => 'c' * 64 },
    'helper_module' => { 'module' => 'golang.org/x/tour', 'version' => 'v0.1.0', 'license' => 'BSD-3-Clause', 'go_mod_sum' => 'h1:mod=',
                         'zip_sum' => 'h1:zip=', 'packages' => %w[pic reader tree wc],
                         'materialized_dir' => '/fixture/gomodcache/golang.org/x/tour@v0.1.0' },
    'candidate' => candidate, 'candidate_failures' => TourExecutor.candidate_failures(candidate),
    'volatility' => { 'path' => 'docs/tour/volatility.tsv', 'gate_effect' => 'measurement-record', 'rows' => 1,
                      'sha256' => sha_of.call('docs/tour/volatility.tsv') },
    'normalizer' => { 'path' => 'tools/tour/normalize.rb', 'sha256' => sha_of.call('tools/tour/normalize.rb'),
                      'version' => 'tour-normalizer/v1' },
    'environment' => { 'input_absence_scope' => TourExecutor::INPUT_ABSENCE_SCOPE, 'os_sandbox' => false },
    'expected_observations' => TourExecutor::OBSERVATIONS
  }
  records = [manifest]
  fixture_items.each do |item|
    path = item['path']
    semantic_row = semantics[path]
    observations = TourExecutor::MODES.map do |mode|
      recipe = CONTRACT.fetch([item['applicability'], mode])
      source = fixture_source(path)
      subs = TourExecutor.substitutions(item, bashy: BASHY_PATH, go_bin: GO_PATH, artifact_dir: File.join('/fixture/evidence', mode, TourExecutor.slug(path), 'artifacts'))
      body_out = item['applicability'] == 'applicable_go_program' ? fixture_stdout(path) : ''.b
      stages = recipe['stages'].map do |spec|
        argv = TourExecutor.render_argv(spec['argv_template'], subs)
        fixture_stage(spec, argv, mode, stdout: spec['execute_body'] ? body_out : ''.b, path: path)
      end
      stages.each_with_index do |stage, i|
        stage['inputs'] = TourExecutor.consumed_artifacts(recipe['stages'][i]).to_h do |name|
          producer = stages[0...i].reverse.find { |previous| previous['artifacts'].key?(name) }
          [name, producer['artifacts'][name].dup]
        end
      end
      {
        'type' => 'observation', 'path' => path, 'applicability' => item['applicability'],
        'exception' => 'none', 'differential_schema' => SCHEMA_FOR.fetch(item['applicability']),
        'mode' => mode, 'phase' => recipe['phase'],
        'historical_phase_token' => MIGRATION.fetch([item['applicability'], mode])['historical_token'],
        'source' => { 'bytes' => source.bytesize, 'sha256' => TourExecutor.sha(source) },
        'stages' => stages, 'authoritative_stage' => stages.length - 1
      }
    end

    if semantic_row
      binary_sha = TourExecutor.sha("bin:#{path}")
      runs = (0...7).map do |i|
        { 'index' => i, 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'signal' => nil,
          'descendants_survived' => false, 'duration_ms' => 1,
          'started_at' => next_stamp, 'finished_at' => next_stamp,
          'stdout_base64' => Base64.strict_encode64(fixture_stdout(path)), 'stdout_bytes' => fixture_stdout(path).bytesize,
          'stderr_base64' => '', 'stderr_bytes' => 0 }
      end
      utc_offset = Time.now.utc_offset
      records << { 'type' => 'oracle', 'path' => path, 'comparator' => semantic_row['comparator'],
                   'source_sha256' => semantic_row['source_sha256'], 'repeats' => runs.length,
                   'binary' => { 'present' => true, 'bytes' => 10, 'sha256' => binary_sha },
                   'window' => TourExecutor.semantic_window([], runs, utc_offset),
                   'runs' => runs, 'provenance' => 'fixture native repeats' }
      oracle = runs.map { |r| { 'exit' => 0, 'stdout' => fixture_stdout(path).force_encoding('UTF-8'), 'stderr' => '' } }
      observations.each do |observation|
        final = observation['stages'].last
        window = TourExecutor.semantic_window(observation['stages'], runs, utc_offset)
        observation['window'] = window
        observation['semantic'] = TourSemantics.compare(
          semantic_row,
          candidate: { 'exit' => final['exit'],
                       'stdout' => Base64.decode64(final.dig('raw', 'stdout_base64')).force_encoding('UTF-8'),
                       'stderr' => '' },
          oracle: oracle, window: window
        ).merge('stage' => final['stage'])
        observation['historical_accepted'] = 'informational'
      end
    end

    observations.each do |observation|
      observation['status'] = TourExecutor.observation_status(
        observation, recipe: CONTRACT.fetch([item['applicability'], observation['mode']]),
        accepted: TourExecutor.load_accepted(File.join(dir, 'tests/tour/results.tsv'))[path],
        baseline_observation: observation['mode'] == 'baseline' ? nil : observations.first,
        semantic_row: semantic_row
      )
      records << observation
    end
  end
  manifest['run_window'] = { 'from' => run_from - 1, 'to' => CLOCK['now'] + 1, 'utc_offset' => Time.now.utc_offset }
  observations = records.select { |r| r['type'] == 'observation' }
  records << { 'type' => 'summary', 'observations' => observations.length, 'programs' => fixture_items.length,
               'modes' => TourExecutor::MODES, 'outcomes' => { 'PASS' => observations.length },
               'semantic_rows' => records.count { |r| r['type'] == 'oracle' },
               'expected_observations' => TourExecutor::OBSERVATIONS, 'sources_unchanged' => true }
  reseal(records)
end

# Recomputes the root and verdict so a mutated ledger stays internally
# consistent everywhere EXCEPT the thing the test mutated. Without this a
# mutation would always be caught by the root check and the test would prove
# nothing about the specific rule under test.
def reseal(records)
  body = records.reject { |r| %w[root verdict].include?(r['type']) }
  observations = body.select { |r| r['type'] == 'observation' }
  summary = body.find { |r| r['type'] == 'summary' }
  summary['outcomes'] = observations.group_by { |r| r['status'] }.transform_values(&:length).sort.to_h
  summary['observations'] = observations.length
  summary['semantic_rows'] = body.count { |r| r['type'] == 'oracle' }
  root = { 'type' => 'root', 'algorithm' => 'sha256-canonical-jsonl', 'sha256' => TourExecutor.ledger_root(body) }
  pass = observations.length == TourExecutor::OBSERVATIONS && summary['outcomes'] == { 'PASS' => TourExecutor::OBSERVATIONS }
  body + [root, { 'type' => 'verdict', 'value' => pass ? 'PASS' : 'FAIL', 'root_sha256' => root['sha256'] }]
end

def run_gate(fixture, records)
  ledger = File.join(fixture['dir'], 'ledger.jsonl')
  TourExecutor.write_ledger(ledger, records)
  out, status = Open3.capture2e(
    { 'TOUR_GATE_ROOT' => fixture['dir'], 'TOUR_EXECUTOR_RESULTS' => ledger },
    RbConfig.ruby, GATE
  )
  [status.exitstatus, out]
end

def deep_copy(records)
  records.map { |r| JSON.parse(JSON.generate(r)) }
end

def volatile_observation(records, mode)
  records.find { |r| r['type'] == 'observation' && r['path'] == VOLATILE_PATH && r['mode'] == mode }
end

def restate(observation, stdout)
  final = observation['stages'].last
  final['raw'] = { 'stdout_base64' => Base64.strict_encode64(stdout), 'stdout_bytes' => stdout.bytesize,
                   'stderr_base64' => '', 'stderr_bytes' => 0 }
  final['normalized']['stdout'] = normalized_for(stdout)
  final['logs']['stdout_sha256'] = TourExecutor.sha(stdout)
end

Dir.mktmpdir('tour-executor-selftest') do |dir|
  fixture = build_fixture(dir)
  FIXTURE_DIR << dir
  clean = build_ledger(fixture)

  check('gate: a well-formed 97x3 ledger with a native oracle PASSES (the gate is not merely always red)') do
    code, out = run_gate(fixture, clean)
    expect(code.zero?, "exit #{code}: #{out}")
  end

  cases = [
    ['gate: compiled run cannot use the native baseline binary', 'argv_identity:', lambda do |records|
      target = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' && r['applicability'] == 'applicable_go_program' }
      baseline = records.find { |r| r['type'] == 'observation' && r['mode'] == 'baseline' && r['path'] == target['path'] }
      raise 'fixture modes must have different binaries' if target['stages'].last['command'] == baseline['stages'].last['command']
      target['stages'].last['command'] = baseline['stages'].last['command'].dup
      records
    end],
    ['gate: compiled build cannot use original source instead of transpiled output', 'argv_identity:', lambda do |records|
      target = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      target['stages'][1]['command'][-1] = target['path']
      records
    end],
    ['gate: input artifact digest must match its producer', 'artifact_input_identity:', lambda do |records|
      target = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      target['stages'][1]['inputs']['go']['sha256'] = 'f' * 64
      records
    end],
    ['gate: output artifact path cannot impersonate another artifact', 'artifact_path:', lambda do |records|
      target = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      target['stages'][1]['artifacts']['bin']['path'] = 'wrong.bin'
      records
    end],
    ['gate: candidate component commit must match repository', 'candidate:component_repository:', lambda do |records|
      records.first['candidate']['components'].first['commit'] = 'f' * 40
      records
    end],

    ['gate: a MISSING observation is rejected', 'missing:', lambda do |records|
      idx = records.index { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      records.delete_at(idx)
      records
    end],
    ['gate: a PLANNED placeholder status is rejected', 'placeholder_status:', lambda do |records|
      records.find { |r| r['type'] == 'observation' }['status'] = 'PLANNED'
      records
    end],
    ['gate: an unexpected not-applicable claim is rejected', 'unexpected_na:', lambda do |records|
      records.find { |r| r['type'] == 'observation' }['not_applicable'] = 'host'
      records
    end],
    ['gate: an N/A status inside the executable denominator is rejected', 'placeholder_status:', lambda do |records|
      records.find { |r| r['type'] == 'observation' }['status'] = 'N/A'
      records
    end],
    ['gate: a duplicated observation is rejected', 'duplicate:', lambda do |records|
      dup = deep_copy([records.find { |r| r['type'] == 'observation' }]).first
      records.insert(1, dup)
      records
    end],
    ['gate: a MISMATCHED product mode is rejected', 'not_pass:', lambda do |records|
      observation = records.find do |r|
        r['type'] == 'observation' && r['mode'] == 'interpreted' && r['applicability'] == 'applicable_go_program' && r['path'] != VOLATILE_PATH
      end
      restate(observation, "different output\n".b)
      records
    end],
    ['gate: a baseline that does not reproduce the accepted observation is rejected', 'not_pass:', lambda do |records|
      observation = records.find do |r|
        r['type'] == 'observation' && r['mode'] == 'baseline' && r['applicability'] == 'applicable_go_program' && r['path'] != VOLATILE_PATH
      end
      observation['stages'].last['exit'] = 3
      records
    end],
    ['gate: a hand-edited PASS on a failed stage is rejected', 'status_forged:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      observation['stages'].first['exit'] = 2
      records
    end],
    ['gate: a successful transpile cannot stand in for the artifact run', 'stage_substitution:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' && r['applicability'] == 'applicable_go_program' }
      observation['stages'][1]['artifacts']['bin']['present'] = false
      records
    end],
    ['gate: a build-only row whose no-body stage printed output is rejected', 'body_executed:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'interpreted' && r['applicability'] == 'build_only_go_program' }
      leaked = "hello from the body\n".b
      s = observation['stages'].first
      s['raw'] = { 'stdout_base64' => Base64.strict_encode64(leaked), 'stdout_bytes' => leaked.bytesize, 'stderr_base64' => '', 'stderr_bytes' => 0 }
      s['normalized']['stdout'] = normalized_for(leaked)
      records
    end],
    ['gate: a forged command (source swapped for another row) is rejected', 'argv_src:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'interpreted' && r['applicability'] == 'applicable_go_program' }
      argv = observation['stages'].first['command']
      argv[argv.length - 1] = APPLICABLE_PATHS[1]
      records
    end],
    ['gate: dropping --source=go from the recorded command is rejected', 'argv_literal:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'interpreted' && r['applicability'] == 'applicable_go_program' }
      observation['stages'].first['command'][2] = '--posix'
      records
    end],
    ['gate: a missing transpiler source map is rejected', 'source_map_missing:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      observation['stages'].first['artifacts']['map']['present'] = false
      records
    end],
    ['gate: a source map with no mappings is rejected', 'source_map_empty:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      observation['stages'].first['artifacts']['map']['source_map']['mappings'] = 0
      records
    end],
    ['gate: a source map that does not describe its own generated artifact is rejected', 'source_map_generation_digest:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      observation['stages'].first['artifacts']['map']['source_map']['go_digest'] = "sha256:#{'9' * 64}"
      records
    end],
    ['gate: a source map pointing at another original source is rejected', 'source_map_origin:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' }
      observation['stages'].first['artifacts']['map']['source_map']['origin'] = APPLICABLE_PATHS[2]
      records
    end],
    ['gate: blanket normalization that erases a stream is rejected', 'normalizer_drift:', lambda do |records|
      observation = records.find do |r|
        r['type'] == 'observation' && r['mode'] == 'baseline' && r['applicability'] == 'applicable_go_program' && r['path'] != VOLATILE_PATH
      end
      observation['stages'].last['normalized']['stdout'] = { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => TourExecutor.sha('') }
      records
    end],
    ['gate: a private capture implementation is rejected', 'capture:implementation', lambda do |records|
      records.first['capture_implementation'] = 'tools/tour/executor.rb'
      records
    end],
    ['gate: a rebound shared capture library digest is rejected', 'capture:library_sha256', lambda do |records|
      records.first['capture_library_sha256'] = '0' * 64
      records
    end],
    ['gate: an unbound replaced dependency fails the candidate', 'candidate:unbound:filebrowser', lambda do |records|
      component = records.first['candidate']['components'].find { |c| c['component'] == 'filebrowser' }
      component['bound'] = false
      component['commit'] = nil
      records.first['candidate_failures'] = TourExecutor.candidate_failures(records.first['candidate'])
      records
    end],
    ['gate: a manifest repository nobody declared fails the candidate', 'candidate:repository_set', lambda do |records|
      records.first['candidate']['repositories'] << { 'name' => 'surprise', 'path' => '/x', 'commit' => 'c' * 40 }
      records.first['candidate_failures'] = TourExecutor.candidate_failures(records.first['candidate'])
      records
    end],
    ['gate: a candidate that hides its own failures in the manifest is rejected', 'candidate:runner_hid_failures', lambda do |records|
      records.first['candidate']['binaries']['payload']['present'] = false
      records
    end],
    ['gate: an OS-sandbox claim the corpus cannot honour is rejected', 'input_absence:os_sandbox_claimed', lambda do |records|
      records.first['environment']['os_sandbox'] = true
      records
    end],
    ['gate: a weakened input-absence scope claim is rejected', 'input_absence:scope', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'baseline' && r['applicability'] == 'applicable_go_program' }
      observation['stages'].last['input_absence']['scope'] = 'fully sandboxed'
      records
    end],
    ['gate: a native body stage that ran in the source directory is rejected', 'input_absence:cwd', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'compiled' && r['applicability'] == 'applicable_go_program' }
      observation['stages'].last['cwd'] = 'module'
      observation['stages'].last['input_absence']['cwd'] = 'module'
      records
    end],
    ['gate: a body stage with a populated PATH is rejected', 'input_absence:path', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['mode'] == 'interpreted' && r['applicability'] == 'applicable_go_program' }
      observation['stages'].last['path_env'] = '/usr/bin:/bin'
      records
    end],
    ['gate: a partial ledger cannot stand in for a full run', 'ledger:partial', lambda do |records|
      records.first['partial'] = true
      records
    end],
    ['gate: a rebound inventory row digest is rejected', 'denominator:inventory_data_sha256', lambda do |records|
      records.first['inventory']['data_sha256'] = 'f' * 64
      records
    end],
    ['gate: a rebound inventory file digest is rejected', 'binding:inventory:sha256', lambda do |records|
      records.first['inventory']['sha256'] = 'f' * 64
      records
    end],
    ['gate: a swapped normalizer binding is rejected', 'binding:normalizer:sha256', lambda do |records|
      records.first['normalizer']['sha256'] = '0' * 64
      records
    end],
    ['gate: a rebound phase-migration table is rejected', 'binding:phase_migration:sha256', lambda do |records|
      records.first['phase_migration']['sha256'] = '0' * 64
      records
    end],
    ['gate: a rewritten historical phase token on an observation is rejected', 'historical_phase_drift:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['applicability'] == 'build_only_go_program' && r['mode'] == 'compiled' }
      observation['historical_phase_token'] = 'transpile-build-no-run'
      records
    end],
    ['gate: a ledger claiming the volatility MEASUREMENT table excuses a mismatch is rejected', 'volatility:claims_gate_effect', lambda do |records|
      records.first['volatility']['gate_effect'] = 'waives-mismatch'
      records
    end],
    ['gate: an undeclared volatility annotation is rejected', 'volatility_undeclared:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['path'] == APPLICABLE_PATHS[5] }
      observation['volatility'] = { 'volatile_element' => 'invented', 'comparator_needed' => 'none' }
      records
    end],
    ['gate: an observation-level waiver is rejected', 'unexpected_na:', lambda do |records|
      records.find { |r| r['type'] == 'observation' }['expected_failure'] = 'unimplemented'
      records
    end],
    ['gate: an off-pin Go toolchain identity is rejected', 'toolchain:identity', lambda do |records|
      records.first['go']['identity'] = 'go version go1.26.0 darwin/arm64'
      records
    end],
    # ---- semantic comparator forgery -------------------------------------
    ['gate: a FORGED semantic verdict over wrong output is rejected', 'semantic_forged:', lambda do |records|
      observation = volatile_observation(records, 'interpreted')
      restate(observation, "totally different\n".b)
      records # `semantic.ok` stays true; the gate recomputes it
    end],
    ['gate: a semantic verdict flipped to ok is rejected', 'semantic_forged:', lambda do |records|
      observation = volatile_observation(records, 'compiled')
      restate(observation, "totally different\n".b)
      observation['semantic']['ok'] = true
      observation['semantic']['findings'] = []
      records
    end],
    # An HONESTLY recomputed semantic verdict over wrong output must still FAIL:
    # the comparator is not an escape hatch, it is a different (and narrow)
    # comparison. This is the case that proves a volatile row can still fail.
    ['gate: wrong output on a volatile row still FAILS, comparator and all', 'not_pass:', lambda do |records|
      observation = volatile_observation(records, 'interpreted')
      restate(observation, "totally different\n".b)
      row = TourSemantics.load_table(File.join(FIXTURE_DIR[0], 'docs/tour/semantics.tsv')).fetch(VOLATILE_PATH)
      oracle_record = records.find { |r| r['type'] == 'oracle' && r['path'] == VOLATILE_PATH }
      oracle = oracle_record['runs'].map do |r|
        { 'exit' => r['exit'], 'stdout' => Base64.decode64(r['stdout_base64']).force_encoding('UTF-8'), 'stderr' => '' }
      end
      final = observation['stages'].last
      observation['semantic'] = TourSemantics.compare(
        row,
        candidate: { 'exit' => final['exit'],
                     'stdout' => Base64.decode64(final.dig('raw', 'stdout_base64')).force_encoding('UTF-8'),
                     'stderr' => '' },
        oracle: oracle, window: observation['window']
      ).merge('stage' => final['stage'])
      observation['status'] = 'FAIL:semantic:' + observation['semantic']['findings'].first.to_s
      records
    end],
    ['gate: a semantic verdict claimed for an undeclared row is rejected', 'semantic_undeclared:', lambda do |records|
      observation = records.find { |r| r['type'] == 'observation' && r['path'] == APPLICABLE_PATHS[7] && r['mode'] == 'baseline' }
      observation['semantic'] = { 'comparator' => 'line_set', 'version' => TourSemantics::VERSION, 'ok' => true, 'findings' => [], 'evidence' => {} }
      records
    end],
    ['gate: a volatile row with no oracle record is rejected', 'oracle:row_set', lambda do |records|
      records.delete_at(records.index { |r| r['type'] == 'oracle' })
      records
    end],
    ['gate: an oracle thinner than the declared minimum is rejected', 'oracle:repeats', lambda do |records|
      oracle = records.find { |r| r['type'] == 'oracle' }
      oracle['runs'] = oracle['runs'].first(3)
      oracle['repeats'] = 3
      records
    end],
    ['gate: an oracle that is not repeats of the built artifact is rejected', 'oracle_binary_mismatch:', lambda do |records|
      records.find { |r| r['type'] == 'oracle' }['binary']['sha256'] = '7' * 64
      records
    end],
    ['gate: an oracle bound to another source digest is rejected', 'oracle:source_binding:', lambda do |records|
      records.find { |r| r['type'] == 'oracle' }['source_sha256'] = '8' * 64
      records
    end],
    ['gate: a widened comparison window is rejected', 'semantic_window_forged:', lambda do |records|
      observation = volatile_observation(records, 'baseline')
      observation['window'] = observation['window'].merge('to' => observation['window']['to'] + 100_000)
      records
    end],
    ['gate: an oracle run that leaked a process is rejected', 'oracle:run_not_clean:', lambda do |records|
      records.find { |r| r['type'] == 'oracle' }['runs'][0]['descendants_survived'] = true
      records
    end]
  ]

  cases.each do |name, expected, mutate|
    check(name) do
      records = mutate.call(deep_copy(clean))
      code, out = run_gate(fixture, reseal(records))
      next "gate passed (exit 0)\n#{out}" if code.zero?
      expect(out.include?(expected), "expected finding #{expected.inspect}, got:\n#{out}")
    end
  end

  # A mutation of a REFERENCE FILE rather than the ledger: the historical
  # inventory schema and the current contract must stay joined by the migration
  # table, and rewriting either end is a finding.
  check('gate: rewriting the pinned historical schema to agree with the new phase is rejected') do
    inventory_path = File.join(fixture['dir'], 'tests/tour/inventory.tsv')
    original = File.binread(inventory_path)
    begin
      File.binwrite(inventory_path, original.gsub('bpp_compiled:transpile-build-run', 'bpp_compiled:transpile-build-no-run'))
      code, out = run_gate(fixture, clean)
      next 'gate passed (exit 0)' if code.zero?
      expect(out.include?('phase_migration:historical_drift') || out.include?('binding:inventory:sha256'), out)
    ensure
      File.binwrite(inventory_path, original)
    end
  end

  # A tampered root must be caught even though everything else balances: this
  # is the one case that must NOT be resealed.
  check('gate: a tampered root hash is rejected') do
    records = deep_copy(clean)
    records[-2]['sha256'] = '1' * 64
    records[-1]['root_sha256'] = '1' * 64
    code, out = run_gate(fixture, records)
    next 'gate passed (exit 0)' if code.zero?
    expect(out.include?('root:tampered'), out)
  end

  check('gate: a forged PASS verdict over failing observations is rejected') do
    records = deep_copy(clean)
    records.find { |r| r['type'] == 'observation' }['stages'].last['exit'] = 9
    sealed = reseal(records)
    sealed[-1]['value'] = 'PASS'
    code, out = run_gate(fixture, sealed)
    next 'gate passed (exit 0)' if code.zero?
    expect(out.include?('verdict:forged') || out.include?('not_pass:'), out)
  end
end

puts "tour executor selftests: #{PASSED.length} passed, #{FAILED.length} failed"
FAILED.each { |f| warn "  FAIL #{f}" }
exit(FAILED.empty? ? 0 : 1)
