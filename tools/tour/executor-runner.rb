#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Produces tests/tour/executor-results.jsonl — the tour-executor/v2 ledger.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# Runs every one of the 97 pinned executable tour programs (93 applicable +
# 4 build-only) in all three declared modes and records exit status, raw
# stdout/stderr, explicit normalization, per-stage artifacts and provenance.
# It never invents a result: an unimplemented product selector produces a
# recorded FAILURE, never a skip, a PLANNED row or a not-applicable.
#
# Every subprocess goes through Corpus.capture (tools/corpus/executor.rb) via
# TourExecutor.run. There is no local capture implementation and no fallback:
# if the shared library is absent, tools/tour/executor.rb aborts.
#
# For the ten rows docs/tour/semantics.tsv declares volatile, the runner also
# collects an ORACLE — repeated observations of the very native binary the
# baseline stage just built — and adjudicates all three modes with the reviewed
# comparator against those repeats instead of against a frozen historical draw.
#
# Environment:
#   BASHPP_BIN                 candidate bashy launcher (required)
#   TOUR_CANDIDATE_MANIFEST    manager-supplied build manifest JSON (required)
#   TOUR_CORPUS_ROOT           committed corpus root (default: <repo>/tour)
#   TOUR_EXECUTOR_RESULTS      output ledger path
#   TOUR_EXECUTOR_EVIDENCE     durable root for raw capture logs and artifacts
#   TOUR_ORACLE_REPEATS        native repeats per volatile row (default 7)
#   TOUR_STEP_TIMEOUT          per-stage timeout in seconds (default 60)
#   TOUR_ONLY                  substring filter for focused development runs;
#                              a filtered ledger is marked partial and the gate
#                              rejects it, so it can never stand in for a gate

require_relative 'executor'

ROOT = File.expand_path('../..', __dir__)

def die(message)
  warn "FATAL: #{message}"
  exit 1
end

# --- pins -------------------------------------------------------------------

contract_path = File.join(ROOT, 'docs/tour/executor-contract.tsv')
candidate_path = File.join(ROOT, 'docs/tour/candidate.tsv')
migration_path = File.join(ROOT, 'docs/tour/phase-migration.tsv')
semantics_path = File.join(ROOT, 'docs/tour/semantics.tsv')
volatility_path = File.join(ROOT, 'docs/tour/volatility.tsv')
inventory_path = ENV.fetch('TOUR_INVENTORY', File.join(ROOT, 'tests/tour/inventory.tsv'))
accepted_path = ENV.fetch('TOUR_BASE_RESULTS', File.join(ROOT, 'tests/tour/results.tsv'))
normalizer = ENV.fetch('TOUR_NORMALIZER', File.join(ROOT, 'tools/tour/normalize.rb'))
output = ENV.fetch('TOUR_EXECUTOR_RESULTS', File.join(ROOT, 'tests/tour/executor-results.jsonl'))
corpus_root = ENV.fetch('TOUR_CORPUS_ROOT', File.join(ROOT, 'tour'))
timeout = Integer(ENV.fetch('TOUR_STEP_TIMEOUT', '60'))
oracle_repeats = Integer(ENV.fetch('TOUR_ORACLE_REPEATS', '7'))
only = ENV['TOUR_ONLY']

contract = TourExecutor.load_contract(contract_path)
migration = TourExecutor.load_phase_migration(migration_path)
inventory = TourExecutor.load_inventory(inventory_path)
items = inventory['items']
die "executable denominator must be #{TourExecutor::DENOMINATOR} rows, got #{items.length}" unless items.length == TourExecutor::DENOMINATOR
applicable = items.count { |i| i['applicability'] == 'applicable_go_program' }
build_only = items.count { |i| i['applicability'] == 'build_only_go_program' }
die "denominator split must be #{TourExecutor::APPLICABLE_ROWS}+#{TourExecutor::BUILD_ONLY_ROWS}, got #{applicable}+#{build_only}" unless
  applicable == TourExecutor::APPLICABLE_ROWS && build_only == TourExecutor::BUILD_ONLY_ROWS
accepted = TourExecutor.load_accepted(accepted_path)

migration_failures = TourExecutor.phase_migration_failures(migration, contract, items)
die "phase migration is inconsistent: #{migration_failures.join(', ')}" unless migration_failures.empty?

by_path = items.to_h { |item| [item['path'], item] }
semantics = TourSemantics.load_table(semantics_path, inventory: by_path)
# The measured volatility record and the comparator bindings must name exactly
# the same rows: a comparator for a row nobody measured, or a measured volatile
# row left under byte comparison, are both contract errors.
volatility = TourExecutor.tsv_rows(volatility_path)
             .to_h { |path, element, comparator| [path, { 'volatile_element' => element, 'comparator_needed' => comparator }] }
die "volatility and semantics tables disagree: #{(volatility.keys ^ semantics.keys).sort.inspect}" unless
  volatility.keys.sort == semantics.keys.sort
semantics.each do |path, row|
  die "semantics: #{path} volatile_element does not match docs/tour/volatility.tsv" unless
    row['volatile_element'] == volatility.fetch(path)['volatile_element']
end

pin = TourExecutor.tsv_rows(File.join(ROOT, 'docs/tour/pin.tsv')).first
tc = TourExecutor.tsv_rows(File.join(ROOT, 'docs/tour/toolchain.tsv')).first
helper = TourExecutor.tsv_rows(File.join(ROOT, 'docs/tour/helpers.tsv')).first
corpus = TourExecutor.tsv_rows(File.join(ROOT, 'docs/tour/corpus.tsv')).first

die "pin inventory_data_sha256 mismatch: docs/tour/pin.tsv says #{pin[7]}, inventory hashes to #{inventory['data_sha256']}" unless pin[7] == inventory['data_sha256']
die "pin declares #{pin[6]} inventory rows, inventory has #{inventory['rows']}" unless Integer(pin[6]) == inventory['rows']

# --- pinned Go toolchain, fail closed --------------------------------------

goroot = `GOTOOLCHAIN=#{tc[2]} go env GOROOT 2>/dev/null`.strip
die "cannot resolve GOROOT for #{tc[2]}" if goroot.empty?
go_bin = File.join(goroot, 'bin/go')
die "pinned Go binary missing at #{go_bin}" unless File.executable?(go_bin)
go_version, = Open3.capture2e(go_bin, 'version')
go_version = go_version.lines.first.to_s.strip
die "Go binary is not the pinned toolchain (#{go_version.inspect}, expected #{tc[3].inspect})" unless go_version == tc[3]
go_sha = TourExecutor.sha(File.binread(go_bin))
die "Go binary checksum does not match docs/tour/toolchain.tsv (#{go_sha})" unless go_sha == tc[4]

# --- candidate product ------------------------------------------------------
#
# Authenticated against the EXACT manager-supplied manifest by the shared
# library. No commit is derived here, and failure is fatal.

bashy = ENV['BASHPP_BIN'].to_s
die 'BASHPP_BIN must name the candidate bashy launcher' if bashy.empty? || !File.executable?(bashy)
bashy = File.realpath(bashy)
manifest_path = ENV['TOUR_CANDIDATE_MANIFEST'].to_s
die 'TOUR_CANDIDATE_MANIFEST must name the manager-supplied candidate manifest' if manifest_path.empty? || !File.file?(manifest_path)
candidate_contract = TourExecutor.load_candidate_contract(candidate_path)
candidate =
  begin
    TourExecutor.authenticate_candidate(bashy_path: bashy, manifest_path: File.expand_path(manifest_path), contract: candidate_contract)
  rescue Corpus::ContractError => e
    die "candidate authentication failed: #{e.message}"
  end
candidate['contract_sha256'] = TourExecutor.sha(File.binread(candidate_path))
candidate_reasons = TourExecutor.candidate_failures(candidate)
die "candidate binding is incomplete: #{candidate_reasons.join(', ')}" unless candidate_reasons.empty?
runtime_dependency = TourExecutor.runtime_dependency(candidate)

# --- work root, durable evidence root ---------------------------------------

work = Dir.mktmpdir('tour-executor')
at_exit { FileUtils.remove_entry(work) if File.directory?(work) }
evidence_root = File.expand_path(ENV.fetch('TOUR_EXECUTOR_EVIDENCE', File.join(ROOT, '.cache/tour/executor-evidence')))
FileUtils.rm_rf(evidence_root)
FileUtils.mkdir_p(evidence_root)

gomodcache = `#{go_bin} env GOMODCACHE`.strip
gocache = `#{go_bin} env GOCACHE`.strip
die 'cannot resolve GOMODCACHE/GOCACHE' if gomodcache.empty? || gocache.empty?

TOOLCHAIN_PATH = '/usr/bin:/bin'

# GOROOT names the pinned SDK. It is supplied IDENTICALLY to all three modes:
# the product resolves Go stdlib imports through it, exactly as `go build` does.
# Withholding it from one mode would compare two different environments rather
# than two engines. It is toolchain configuration, not a source-access grant —
# see the input-absence scope recorded on every body stage.
def base_env(home:, tmp:, gomodcache:, gocache:, goproxy:, goroot:)
  { 'HOME' => home, 'TMPDIR' => tmp, 'LC_ALL' => 'C',
    'GOMAXPROCS' => '2', 'GOROOT' => goroot, 'GOTOOLCHAIN' => 'local', 'GOFLAGS' => '-mod=mod', 'GOPROXY' => goproxy,
    'GOMODCACHE' => gomodcache, 'GOCACHE' => gocache, 'GOPATH' => File.join(home, 'go'),
    'BASHY_HINTS' => 'off', 'BASHY_AGENTIC' => '' }
end

# Materializes one fresh, read-only module tree: go.mod/go.sum for the official
# helper module, the upstream LICENSE (BSD redistribution requires the license
# to travel with the code), and every pinned source verified byte-for-byte
# against its inventory row on the way in.
def materialize(mod_dir, corpus_root:, corpus:, items:, go_version:, helper:, runtime_dependency:)
  FileUtils.mkdir_p(mod_dir)
  module_text = "module tour.executor.local\n\ngo #{go_version.delete_prefix('go')}\n\nrequire #{helper[0]} #{helper[1]}\n"
  module_text += "require #{runtime_dependency.fetch('module')} #{runtime_dependency.fetch('require_version')}\n"
  module_text += "replace #{runtime_dependency.fetch('module')} => #{JSON.generate(runtime_dependency.fetch('dir'))}\n"
  File.write(File.join(mod_dir, 'go.mod'), module_text)
  File.write(File.join(mod_dir, 'go.sum'), "#{helper[0]} #{helper[1]} #{helper[4]}\n#{helper[0]} #{helper[1]}/go.mod #{helper[3]}\n")
  # Bashy predates BASHY_HINTS suppression of its one-time startup
  # advertisement; a deterministic agent-config marker keeps that
  # provenance-neutral, driver-specific line out of evidence. Not Go source,
  # and it alters no program under test.
  File.write(File.join(mod_dir, 'AGENTS.md'), "# Hermetic tour executor workspace\n")
  license_source = File.join(corpus_root, corpus[1].sub(%r{\A#{Regexp.escape(corpus[0])}/}, ''))
  raise "missing upstream LICENSE #{license_source}" unless File.file?(license_source)
  license_bytes = File.binread(license_source)
  raise 'LICENSE byte count does not match docs/tour/corpus.tsv' unless license_bytes.bytesize == Integer(corpus[2])
  raise 'LICENSE sha256 does not match docs/tour/corpus.tsv' unless TourExecutor.sha(license_bytes) == corpus[3]
  File.binwrite(File.join(mod_dir, 'LICENSE'), license_bytes)
  File.chmod(0o444, File.join(mod_dir, 'LICENSE'))
  items.each do |item|
    source = File.join(corpus_root, item['path'])
    raise "missing pinned source #{source}" unless File.file?(source)
    bytes = File.binread(source)
    raise "source pin mismatch #{item['path']}" unless bytes.bytesize == item['bytes'] && TourExecutor.sha(bytes) == item['sha256']
    local = File.join(mod_dir, item['path'])
    FileUtils.mkdir_p(File.dirname(local))
    File.binwrite(local, bytes)
    File.chmod(0o444, local)
    raise "copy drift #{item['path']}" unless TourExecutor.sha(File.binread(local)) == item['sha256']
  end
end

# Re-verifies every original source after a mode has run. "Original upstream
# bytes unchanged" is only evidence if it is checked on the way out too.
def verify_sources(mod_dir, corpus_root:, items:)
  items.each do |item|
    %W[#{mod_dir}/#{item['path']} #{corpus_root}/#{item['path']}].each do |path|
      raise "source disappeared: #{path}" unless File.file?(path)
      raise "SOURCE MUTATED during run: #{path}" unless TourExecutor.sha(File.binread(path)) == item['sha256']
    end
  end
end

# --- helper module provisioning --------------------------------------------
#
# The official golang.org/x/tour helper module (pic, reader, tree, wc) is the
# only non-stdlib import in the executable denominator, and the pinned
# x/website go.mod requires it. It is provisioned once, from the pinned sums,
# into the shared module cache; every subsequent stage runs with GOPROXY=off,
# so the graded run is offline and cannot silently fetch anything else.
provision_dir = File.join(work, 'provision')
provision_home = File.join(work, 'provision-home')
FileUtils.mkdir_p([provision_dir, provision_home, File.join(work, 'provision-tmp')])
materialize(provision_dir, corpus_root: corpus_root, corpus: corpus, items: items, go_version: tc[2], helper: helper, runtime_dependency: runtime_dependency)
provision_env = base_env(home: provision_home, tmp: File.join(work, 'provision-tmp'), goroot: goroot,
                         gomodcache: gomodcache, gocache: gocache, goproxy: 'https://proxy.golang.org,direct')
                .merge('PATH' => TOOLCHAIN_PATH)
provision = TourExecutor.run([go_bin, 'mod', 'download', helper[0]], chdir: provision_dir,
                             timeout: [timeout, 300].max, env: provision_env,
                             log_prefix: File.join(evidence_root, 'provision/mod-download'))
unless provision['spawned'] && provision['exit'] == 0
  warn provision['stderr']
  die "cannot provision helper module #{helper[0]}@#{helper[1]} from the pinned sums"
end
helper_dir = File.join(gomodcache, "#{helper[0]}@#{helper[1]}")
die "helper module not materialized at #{helper_dir}" unless File.directory?(helper_dir)
helper_provision = {
  'module' => helper[0], 'version' => helper[1], 'license' => helper[2],
  'go_mod_sum' => helper[3], 'zip_sum' => helper[4], 'packages' => helper[5].split(','),
  'materialized_dir' => helper_dir,
  'ziphash_sha256' => (f = File.join(gomodcache, "cache/download/#{helper[0]}/@v/#{helper[1]}.ziphash"); File.file?(f) ? TourExecutor.sha(File.binread(f)) : nil),
  'provisioned_by' => "#{go_bin} mod download #{helper[0]}"
}

# --- manifest ---------------------------------------------------------------

run_started_at = Time.now.to_f
manifest = {
  'type' => 'manifest', 'schema' => TourExecutor::SCHEMA,
  'generated_by' => 'tools/tour/executor-runner.rb',
  'story' => { 'sprint' => 118, 'story' => 4, 'story_id' => '759341a95870' },
  'partial' => !only.nil?,
  'capture_implementation' => TourExecutor::CAPTURE_IMPLEMENTATION,
  'capture_library_sha256' => TourExecutor.sha(File.binread(File.join(ROOT, 'tools/corpus/executor.rb'))),
  'contract' => { 'path' => 'docs/tour/executor-contract.tsv', 'sha256' => TourExecutor.sha(File.binread(contract_path)) },
  'phase_migration' => { 'path' => 'docs/tour/phase-migration.tsv', 'sha256' => TourExecutor.sha(File.binread(migration_path)),
                         'rows' => migration.length,
                         'policy' => 'current master plan outranks the stale pinned phase string; historical inventory schema preserved' },
  'inventory' => { 'path' => 'tests/tour/inventory.tsv', 'sha256' => TourExecutor.sha(File.binread(inventory_path)), 'rows' => inventory['rows'],
                   'executable_programs' => items.length, 'applicable' => applicable, 'build_only' => build_only,
                   'data_sha256' => inventory['data_sha256'] },
  'accepted_baseline' => { 'path' => 'tests/tour/results.tsv', 'sha256' => TourExecutor.sha(File.binread(accepted_path)),
                           'pin' => 'docs/tour/baseline-pin.tsv',
                           'pin_sha256' => TourExecutor.sha(File.binread(File.join(ROOT, 'docs/tour/baseline-pin.tsv'))),
                           'role' => 'exact oracle for the 87 stable rows; HISTORICAL stream evidence only for the 10 semantic rows' },
  'source_pin' => { 'path' => 'docs/tour/pin.tsv', 'release' => "#{pin[0]}@#{pin[1]}", 'commit' => pin[2], 'license' => pin[4],
                    'sha256' => TourExecutor.sha(File.binread(File.join(ROOT, 'docs/tour/pin.tsv'))) },
  'corpus' => { 'path' => 'docs/tour/corpus.tsv', 'root' => corpus[0], 'license_sha256' => corpus[3],
                'source_rows' => Integer(corpus[4]), 'corpus_files' => Integer(corpus[5]),
                'sha256' => TourExecutor.sha(File.binread(File.join(ROOT, 'docs/tour/corpus.tsv'))) },
  'go' => { 'path' => go_bin, 'identity' => go_version, 'sha256' => go_sha, 'pinned_identity' => tc[3], 'pinned_sha256' => tc[4],
            'goroot' => goroot },
  'helper_module' => helper_provision,
  'candidate' => candidate,
  'runtime_dependency' => runtime_dependency,
  'candidate_failures' => candidate_reasons,
  'volatility' => { 'path' => 'docs/tour/volatility.tsv', 'gate_effect' => 'measurement-record',
                    'rows' => volatility.length,
                    'sha256' => TourExecutor.sha(File.binread(volatility_path)) },
  'semantics' => { 'path' => 'docs/tour/semantics.tsv', 'gate_effect' => 'semantic-comparator',
                   'version' => TourSemantics::VERSION, 'rows' => semantics.length,
                   'oracle_repeats' => oracle_repeats, 'min_oracle_runs' => TourSemantics::MIN_ORACLE_RUNS,
                   'library_sha256' => TourExecutor.sha(File.binread(File.join(ROOT, 'tools/tour/semantics.rb'))),
                   'sha256' => TourExecutor.sha(File.binread(semantics_path)) },
  'normalizer' => { 'path' => 'tools/tour/normalize.rb', 'sha256' => TourExecutor.sha(File.binread(normalizer)),
                    'version' => `#{RbConfig.ruby} #{normalizer} --version`.strip },
  'environment' => { 'toolchain_path' => TOOLCHAIN_PATH, 'body_path' => '', 'lc_all' => 'C', 'gomaxprocs' => 2,
                     'goproxy_during_run' => 'off', 'gomodcache' => gomodcache, 'gocache' => gocache,
                     'goroot_shared_by_all_modes' => goroot,
                     'input_absence_scope' => TourExecutor::INPUT_ABSENCE_SCOPE,
                     'os_sandbox' => false,
                     'fresh_state' => 'module tree per mode; HOME, TMPDIR, artifact and runtime directories per (row, mode)' },
  'evidence_root' => evidence_root,
  'platform' => { 'goos' => `#{go_bin} env GOOS`.strip, 'goarch' => `#{go_bin} env GOARCH`.strip, 'ruby' => RUBY_VERSION },
  'expected_observations' => TourExecutor::OBSERVATIONS
}

records = [manifest]

# --- execution --------------------------------------------------------------

selected = only ? items.select { |i| i['path'].include?(only) } : items
warn "WARN: TOUR_ONLY=#{only} selects #{selected.length}/#{items.length} rows; this ledger is PARTIAL and the gate will reject it" if only

module_dirs = {}
TourExecutor::MODES.each do |mode|
  module_dirs[mode] = File.join(work, 'state', mode, 'module')
  materialize(module_dirs[mode], corpus_root: corpus_root, corpus: corpus, items: items, go_version: tc[2], helper: helper, runtime_dependency: runtime_dependency)
end

def stage_record(spec, argv, raw, subs, normalizer, cwd_label:, path_env:)
  artifact_records = spec['produces'].to_h do |name|
    key = { 'go' => 'OUT_GO', 'map' => 'OUT_MAP', 'bin' => 'BIN' }.fetch(name)
    record = TourExecutor.artifact_record(subs.fetch(key))
    record['path'] = File.basename(subs.fetch(key))
    record['source_map'] = TourExecutor.source_map_summary(subs.fetch(key)) if name == 'map'
    [name, record]
  end
  normalized = {
    'stdout' => TourExecutor.normalize(raw['stdout'], normalizer),
    'stderr' => TourExecutor.normalize(raw['stderr'], normalizer)
  }
  record = {
    'index' => spec['index'], 'stage' => spec['stage'], 'execute_body' => spec['execute_body'],
    'command' => argv, 'cwd' => cwd_label, 'path_env' => path_env,
    'spawned' => raw['spawned'], 'state' => raw['state'], 'exit' => raw['exit'], 'signal' => raw['signal'],
    'descendants_survived' => raw['descendants_survived'], 'duration_ms' => raw['duration_ms'],
    'started_at' => raw['started_at'], 'finished_at' => raw['finished_at'],
    'artifacts' => artifact_records, 'inputs' => raw.fetch('input_artifacts', {}),
    'raw' => { 'stdout_base64' => Base64.strict_encode64(raw['stdout']), 'stdout_bytes' => raw['stdout'].bytesize,
               'stderr_base64' => Base64.strict_encode64(raw['stderr']), 'stderr_bytes' => raw['stderr'].bytesize },
    'logs' => { 'stdout_sha256' => raw.dig('logs', 'stdout', 'sha256'), 'stderr_sha256' => raw.dig('logs', 'stderr', 'sha256') },
    'normalized' => normalized,
    'masking' => { 'stdout' => TourExecutor.masking_report(raw['stdout'], normalized['stdout']['bytes']),
                   'stderr' => TourExecutor.masking_report(raw['stderr'], normalized['stderr']['bytes']) }
  }
  if spec['execute_body']
    record['input_absence'] = { 'scope' => TourExecutor::INPUT_ABSENCE_SCOPE, 'cwd' => cwd_label,
                                'path_env' => path_env, 'os_sandbox' => false }
  end
  record
end

def unreached_stage(spec, argv, subs)
  {
    'index' => spec['index'], 'stage' => spec['stage'], 'execute_body' => spec['execute_body'],
    'command' => argv, 'cwd' => nil, 'path_env' => nil,
    'inputs' => {},
    'spawned' => false, 'state' => 'not_reached', 'exit' => nil, 'signal' => nil,
    'descendants_survived' => false, 'duration_ms' => 0, 'started_at' => nil, 'finished_at' => nil,
    'artifacts' => spec['produces'].to_h { |name| [name, { 'present' => false, 'bytes' => nil, 'sha256' => nil, 'path' => File.basename(subs.fetch({ 'go' => 'OUT_GO', 'map' => 'OUT_MAP', 'bin' => 'BIN' }.fetch(name))) }] },
    'raw' => { 'stdout_base64' => '', 'stdout_bytes' => 0, 'stderr_base64' => '', 'stderr_bytes' => 0 },
    'logs' => { 'stdout_sha256' => nil, 'stderr_sha256' => nil },
    'normalized' => { 'stdout' => { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => TourExecutor.sha('') },
                      'stderr' => { 'valid_utf8' => true, 'bytes' => 0, 'sha256' => TourExecutor.sha('') } },
    'masking' => { 'stdout' => TourExecutor.masking_report('', 0), 'stderr' => TourExecutor.masking_report('', 0) }
  }
end

progress = 0
selected.each do |item|
  slug = TourExecutor.slug(item['path'])
  semantic_row = semantics[item['path']]
  mode_records = {}
  oracle_runs = []
  oracle_binary = nil

  TourExecutor::MODES.each do |mode|
    recipe = contract.fetch([item['applicability'], mode])
    mod = module_dirs[mode]
    state = File.join(work, 'state', mode, slug)
    home = File.join(state, 'home')
    tmp = File.join(state, 'tmp')
    # The artifact directory is DURABLE: transpiled Go, source maps, native
    # binaries and the raw capture logs stay on disk for review next to the
    # ledger's copies.
    artifacts = File.join(evidence_root, mode, slug, 'artifacts')
    # A body stage that executes a NATIVE artifact runs from this fresh, empty
    # directory: the compilation inputs are not reachable through the cwd.
    runtime = File.join(state, 'runtime')
    logs = File.join(evidence_root, mode, slug, 'logs')
    FileUtils.mkdir_p([home, tmp, artifacts, runtime, logs])
    subs = TourExecutor.substitutions(item, bashy: bashy, go_bin: go_bin, artifact_dir: artifacts)

    stages = []
    recipe['stages'].each do |spec|
      argv = TourExecutor.render_argv(spec['argv_template'], subs)
      toolchain_stage = argv.first == go_bin
      # A native body stage runs in the empty runtime cwd; interpreted mode
      # necessarily reads its source from the module context.
      body_in_runtime = spec['execute_body'] && !toolchain_stage && argv.first != bashy
      cwd = body_in_runtime ? runtime : mod
      cwd_label = body_in_runtime ? 'runtime' : 'module'
      if body_in_runtime
        leaked = Dir.glob(File.join(runtime, '**/*')).length
        die "runtime cwd for #{item['path']}/#{mode} is not empty (#{leaked} entries)" unless leaked.zero?
      end
      path_env = toolchain_stage ? TOOLCHAIN_PATH : ''
      env = base_env(home: home, tmp: tmp, gomodcache: gomodcache, gocache: gocache, goproxy: 'off', goroot: goroot)
            .merge('PATH' => path_env)
      inputs = TourExecutor.consumed_artifacts(spec).to_h do |name|
        input_path = subs.fetch({ 'go' => 'OUT_GO', 'bin' => 'BIN' }.fetch(name))
        record = TourExecutor.artifact_record(input_path)
        record['path'] = File.basename(input_path)
        [name, record]
      end
      raw = TourExecutor.run(argv, chdir: cwd, timeout: timeout, env: env,
                             log_prefix: File.join(logs, format('%02d-%s', spec['index'], spec['stage'])))
      raw['input_artifacts'] = inputs
      stages << stage_record(spec, argv, raw, subs, normalizer, cwd_label: cwd_label, path_env: path_env)
      # Stop the pipeline at the first failing stage: a later stage must never
      # run against an artifact its predecessor did not produce.
      break unless TourExecutor.stage_failure(stages.last).nil?
    end

    # A short pipeline is itself the evidence of where it stopped; pad the
    # record so the gate sees the declared stage count and the exact stage
    # that was never reached.
    recipe['stages'][stages.length..].to_a.each do |spec|
      stages << unreached_stage(spec, TourExecutor.render_argv(spec['argv_template'], subs), subs)
    end

    observation = {
      'type' => 'observation', 'path' => item['path'], 'applicability' => item['applicability'],
      'exception' => item['exception'], 'differential_schema' => item['differential_schema'],
      'mode' => mode, 'phase' => recipe['phase'],
      'historical_phase_token' => migration.fetch([item['applicability'], mode])['historical_token'],
      'source' => { 'bytes' => item['bytes'], 'sha256' => item['sha256'] },
      'stages' => stages
    }
    observation['authoritative_stage'] = TourExecutor.authoritative_index(stages)
    observation['accepted_observation'] = accepted[item['path']] if mode == 'baseline'
    observation['volatility'] = volatility[item['path']] if volatility.key?(item['path'])
    mode_records[mode] = observation

    # -- the native oracle: repeated observations of the binary the baseline
    #    stage just built, for the declared-volatile rows only.
    next unless mode == 'baseline' && semantic_row
    binary = subs.fetch('BIN')
    next unless File.file?(binary)
    oracle_binary = TourExecutor.artifact_record(binary)
    body_env = base_env(home: home, tmp: tmp, gomodcache: gomodcache, gocache: gocache, goproxy: 'off', goroot: goroot)
               .merge('PATH' => '')
    oracle_repeats.times do |i|
      repeat_dir = File.join(state, "oracle-#{i}")
      FileUtils.mkdir_p(repeat_dir)
      raw = TourExecutor.run([binary], chdir: repeat_dir, timeout: timeout, env: body_env,
                             log_prefix: File.join(logs, format('oracle-%02d', i)))
      oracle_runs << {
        'index' => i, 'spawned' => raw['spawned'], 'state' => raw['state'], 'exit' => raw['exit'],
        'signal' => raw['signal'], 'descendants_survived' => raw['descendants_survived'],
        'duration_ms' => raw['duration_ms'], 'started_at' => raw['started_at'], 'finished_at' => raw['finished_at'],
        'stdout_base64' => Base64.strict_encode64(raw['stdout']), 'stdout_bytes' => raw['stdout'].bytesize,
        'stderr_base64' => Base64.strict_encode64(raw['stderr']), 'stderr_bytes' => raw['stderr'].bytesize
      }
    end
  end

  # -- semantic adjudication for a declared-volatile row -----------------------
  if semantic_row
    utc_offset = Time.now.utc_offset
    oracle_window = TourExecutor.semantic_window([], oracle_runs, utc_offset)
    oracle = oracle_runs.map do |r|
      { 'exit' => r['exit'], 'stdout' => Base64.decode64(r['stdout_base64']).force_encoding('UTF-8'),
        'stderr' => Base64.decode64(r['stderr_base64']).force_encoding('UTF-8') }
    end
    records << {
      'type' => 'oracle', 'path' => item['path'], 'comparator' => semantic_row['comparator'],
      'source_sha256' => semantic_row['source_sha256'], 'repeats' => oracle_runs.length,
      'binary' => oracle_binary, 'window' => oracle_window, 'runs' => oracle_runs,
      'provenance' => 'repeated execution of the native artifact built from the unchanged upstream source in this run'
    }
    mode_records.each_value do |observation|
      final = observation['stages'][TourExecutor.authoritative_index(observation['stages'])]
      candidate_streams = {
        'exit' => final['exit'],
        'stdout' => Base64.decode64(final.dig('raw', 'stdout_base64').to_s).force_encoding('UTF-8'),
        'stderr' => Base64.decode64(final.dig('raw', 'stderr_base64').to_s).force_encoding('UTF-8')
      }
      window = TourExecutor.semantic_window(observation['stages'], oracle_runs, utc_offset)
      observation['window'] = window
      observation['semantic'] = TourSemantics.compare(semantic_row, candidate: candidate_streams,
                                                      oracle: oracle, window: window)
      observation['semantic']['stage'] = final['stage']
      observation['historical_accepted'] = 'informational: streams adjudicated by the comparator against the native oracle'
    end
  end

  TourExecutor::MODES.each do |mode|
    observation = mode_records.fetch(mode)
    observation['status'] = TourExecutor.observation_status(
      observation, recipe: contract.fetch([item['applicability'], mode]), accepted: accepted[item['path']],
      baseline_observation: mode == 'baseline' ? nil : mode_records['baseline'],
      semantic_row: semantic_row
    )
    records << observation
  end

  progress += 1
  warn "  [#{progress}/#{selected.length}] #{item['path']}" if ENV['TOUR_VERBOSE']
end

TourExecutor::MODES.each { |mode| verify_sources(module_dirs[mode], corpus_root: corpus_root, items: items) }
# Reauthenticate the exact launcher/payload/source revision set after execution.
final_candidate = TourExecutor.authenticate_candidate(bashy_path: bashy, manifest_path: File.expand_path(manifest_path), contract: candidate_contract)
final_candidate['contract_sha256'] = TourExecutor.sha(File.binread(candidate_path))
die 'candidate changed while the Tour corpus ran' unless final_candidate == candidate


# --- summary, root, verdict -------------------------------------------------

manifest['run_window'] = { 'from' => run_started_at, 'to' => Time.now.to_f, 'utc_offset' => Time.now.utc_offset }

observations = records.select { |r| r['type'] == 'observation' }
counts = observations.group_by { |r| r['status'] }.transform_values(&:length).sort.to_h
by_mode = TourExecutor::MODES.to_h do |mode|
  [mode, observations.select { |r| r['mode'] == mode }.group_by { |r| r['status'] }.transform_values(&:length).sort.to_h]
end
oracles = records.select { |r| r['type'] == 'oracle' }
summary = { 'type' => 'summary', 'observations' => observations.length, 'programs' => selected.length,
            'modes' => TourExecutor::MODES, 'outcomes' => counts, 'by_mode' => by_mode,
            'expected_observations' => TourExecutor::OBSERVATIONS,
            'semantic_rows' => oracles.length, 'oracle_runs' => oracles.sum { |o| o['repeats'] },
            'sources_unchanged' => true, 'candidate_reauthenticated' => true }
records << summary
root = { 'type' => 'root', 'algorithm' => 'sha256-canonical-jsonl', 'sha256' => TourExecutor.ledger_root(records) }
records << root
pass = !manifest['partial'] && candidate_reasons.empty? &&
       observations.length == TourExecutor::OBSERVATIONS && counts == { 'PASS' => TourExecutor::OBSERVATIONS }
records << { 'type' => 'verdict', 'value' => pass ? 'PASS' : 'FAIL', 'root_sha256' => root['sha256'] }

TourExecutor.write_ledger(output, records)
puts "#{TourExecutor::SCHEMA} #{pass ? 'PASS' : 'FAIL'}: #{observations.length}/#{TourExecutor::OBSERVATIONS} observations"
by_mode.each { |mode, outcomes| puts "  #{mode.ljust(12)} #{outcomes.map { |k, v| "#{k}=#{v}" }.join(' ')}" }
puts "  candidate: #{candidate_reasons.empty? ? 'authenticated' : candidate_reasons.join(', ')}"
puts "  semantic:  #{oracles.length} rows, #{oracles.sum { |o| o['repeats'] }} native oracle runs"
puts "  root #{root['sha256']}"
puts "  ledger #{output.sub("#{ROOT}/", '')}"
exit(pass ? 0 : 1)
