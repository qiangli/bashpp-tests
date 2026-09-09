# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
# Portable contract tests for the compile-only single-file adapter. Every process
# here is a fake tool created by the test, so these tests are hermetic and prove
# harness behaviour only; they are never corpus certification. The real frozen
# candidate/SDK replay lives in compile_adapter_proof_test.rb.
#
# The fake tools drive the real stdlib export preparation: nothing here injects a
# ready-made @import_configuration, because the preparation and its reuse
# authentication are the code under test.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'rbconfig'
require_relative '../../tools/corpus/validate'
require_relative '../../tools/go-full/product'

class CompileAdapterContractTest < Minitest::Test
  GO_OBJECT_MAGIC = "\x00go120ld"
  # What the fake `go list -export ... std` publishes. Contents stand in for real
  # export archives; only their bytes and their stability matter to the contract.
  STDLIB_PACKAGES = { 'errors' => "fake errors export\n", 'fmt' => "fake fmt export\n" }.freeze

  def setup
    @tmp = Dir.mktmpdir('compile-adapter-')
    @cache = File.join(@tmp, 'cache')
    @stdlib = File.join(@tmp, 'stdlib')
    [@cache, @stdlib].each { |dir| FileUtils.mkdir_p(dir) }
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def importcfg_path
    File.join(@cache, Corpus::IMPORTCFG_NAME)
  end

  def receipt_path
    File.join(@cache, Corpus::IMPORTCFG_RECEIPT)
  end

  def archive_path(name)
    File.join(@stdlib, name + '.a')
  end

  # An ar container carrying the two members and the goobj magic that the pinned
  # toolchain writes. Byte-identical shape to `go tool compile -o`, built without
  # a toolchain so the contract stays portable.
  def object_archive_bytes(members = nil)
    members ||= { '__.PKGDEF' => "go object test\n\n!\n",
                  '_go_.o' => "go object test\n\n!\n" + GO_OBJECT_MAGIC + "body" }
    out = +"!<arch>\n"
    members.each do |name, body|
      out << format('%-16s%-12d%-6d%-6d%-8o%-10d`', name, 0, 0, 0, 0o644, body.bytesize) << "\n"
      out << body
      out << "\n" if body.bytesize.odd?
    end
    out.b
  end

  def tool(name, body)
    path = File.join(@tmp, name)
    File.write(path, "#!#{RbConfig.ruby}\n" + body)
    File.chmod(0o755, path)
    path
  end

  # A fake `go` that records its argv and then produces exactly what the plan
  # asks for, for both `list -export ... std` and `tool compile`. `plan` is baked
  # into the script: the executor clears the environment, so no variable can
  # smuggle the plan in. `name` lets a test build a second, differently-digested
  # toolchain for the cache-substitution negatives.
  def fake_go(plan = {}, name: 'go')
    log = File.join(@tmp, name + '-argv.jsonl')
    baked = plan.merge('log' => log, 'stdlib' => @stdlib, 'packages' => STDLIB_PACKAGES,
                       'identity' => name, 'archive' => object_archive_bytes.unpack1('H*'))
    tool(name, <<~SCRIPT)
      require 'json'
      require 'fileutils'
      plan = #{baked.inspect}
      File.open(plan['log'], 'a') { |f| f.puts(JSON.generate(ARGV)) }
      if ARGV.first == 'list'
        sleep(plan['list_sleep']) if plan['list_sleep']
        FileUtils.mkdir_p(plan['stdlib'])
        rows = plan['packages'].map do |package, body|
          archive = File.join(plan['stdlib'], package + '.a')
          File.binwrite(archive, body) unless File.file?(archive)
          'packagefile ' + package + '=' + archive
        end
        rows = plan['list_rows'] if plan['list_rows']
        warn(plan['list_stderr']) if plan['list_stderr']
        puts(rows) unless plan['list_silent']
        exit(plan['list_exit'] || 0)
      end
      out = ARGV[ARGV.index('-o') + 1] if ARGV.include?('-o')
      case plan['behaviour']
      when 'object' then File.binwrite(out, [plan['archive']].pack('H*'))
      when 'junk' then File.binwrite(out, 'not an archive, but certainly not empty')
      when 'empty' then nil
      when 'tamper'
        File.binwrite(plan['tamper_path'], "package p\\n// rewritten by the tool\\n")
        File.binwrite(out, [plan['archive']].pack('H*'))
      when 'fail'
        warn 'source.go:3:14: undefined: x'
        exit 2
      end
      exit 0
    SCRIPT
    [File.realpath(File.join(@tmp, name)), log]
  end

  # A fake `bashy` that answers `--check` and emits a marker-free generated file
  # with the exact source map the executor requires.
  def fake_bashy(check_exit: 0, tamper_archive: nil)
    tool('bashy', <<~SCRIPT)
      require 'json'
      require 'digest'
      if ARGV.include?('--check')
        exit #{check_exit}
      elsif ARGV.first == 'transpile'
        #{tamper_archive ? "File.binwrite(#{tamper_archive.inspect}, 'swapped between transpile and compile')" : ''}
        source = ARGV[ARGV.index('--source=go') + 1]
        generated = ARGV[ARGV.index('-o') + 1]
        map = ARGV[ARGV.index('--map') + 1]
        bytes = File.binread(source)
        File.binwrite(generated, "package main\\n\\nfunc main() {}\\n")
        File.write(map, JSON.generate(
          'schema_version' => 'bashy-transpile-map-v1', 'origin' => source,
          'go_digest' => 'sha256:' + Digest::SHA256.file(generated).hexdigest,
          'source_kind' => 'go', 'front_end' => 'gosource-v1', 'mappings' => [],
          'sources' => [{ 'name' => source, 'sha256' => Digest::SHA256.hexdigest(bytes),
                          'size' => bytes.bytesize, 'base' => 0 }]))
      end
      exit 0
    SCRIPT
    File.realpath(File.join(@tmp, 'bashy'))
  end

  # A fake toolchain identity in the shape `go version` prints. Nothing here is a
  # real SDK, so the platform is deliberately unlike any host: the contract under
  # test is that the preparation environment is bound to whatever identity
  # provenance carries, not that it matches this machine.
  IDENTITY = 'go version gofake1.0 testos/testarch'

  # The executor build environment a real Executor#initialize always establishes.
  BUILD_ENVIRONMENT = { 'PATH' => '/usr/bin:/bin', 'LC_ALL' => 'C', 'TZ' => 'UTC', 'GOTOOLCHAIN' => 'local',
                        'GOPROXY' => 'off', 'GOSUMDB' => 'off', 'GOFLAGS' => '-mod=readonly -p=2' }.freeze

  # Only the toolchain identity and the shared cache are injected. The import
  # configuration is prepared by the executor's own code path under test.
  def executor(go:, bashy: '/certainly/not/a/bashy', importcfg_timeout: 60, env: {})
    instance = Corpus::Executor.allocate
    instance.instance_variable_set(:@go, go)
    instance.instance_variable_set(:@bashy, bashy)
    instance.instance_variable_set(:@env, BUILD_ENVIRONMENT.merge(env))
    instance.instance_variable_set(:@cache, @cache)
    instance.instance_variable_set(:@timeout, 30)
    instance.instance_variable_set(:@importcfg_timeout, importcfg_timeout)
    # Modes that never reach the toolchain are given a deliberately absent one.
    instance.instance_variable_set(:@provenance, 'sdk' => { 'identity' => IDENTITY,
                                                            'binary' => File.file?(go) ? Corpus.file_record(go) : { 'path' => go, 'sha256' => nil } })
    instance
  end

  # The context a receipt prepared by this fake toolchain must carry.
  def context_of(go, env: {})
    { 'identity' => IDENTITY, 'goroot' => File.dirname(File.dirname(go)), 'goos' => 'testos', 'goarch' => 'testarch',
      'cache' => @cache, 'environment' => BUILD_ENVIRONMENT.merge(env).sort.to_h }
  end

  def sdk_of(go)
    { 'path' => go, 'sha256' => Corpus.digest(go) }
  end

  def source(body = "package main\n\nfunc f() {}\n", name = 'main-without-main.go')
    path = File.join(@tmp, name)
    File.write(path, body)
    [{ name => Corpus.file_record(path) }, [name]]
  end

  def run_mode(instance, mode, inputs, sources, phase: 'compile')
    case_dir = File.join(@tmp, 'case')
    FileUtils.mkdir_p(case_dir)
    instance.send(:execute_mode, case_dir, mode, inputs, sources, [], {}, phase, [], {}, nil)
  end

  def prepared(go = nil)
    go ||= fake_go.first
    executor(go: go).send(:import_configuration)
  end

  def rewrite_receipt
    receipt = JSON.parse(File.read(receipt_path))
    yield receipt
    File.chmod(0o644, receipt_path)
    File.write(receipt_path, Corpus.canonical(receipt) + "\n")
    receipt
  end

  # ---- stdlib export preparation -----------------------------------------

  def test_import_configuration_is_prepared_by_a_bounded_captured_authenticated_process
    go, log = fake_go
    receipt = prepared(go)

    assert_equal Corpus::IMPORTCFG_SCHEMA, receipt.fetch('schema')
    assert_equal importcfg_path, receipt.fetch('path')
    assert_equal sdk_of(go), receipt.fetch('tool').slice('path', 'sha256')

    preparation = receipt.fetch('preparation')
    assert_equal [go, 'list', '-export', '-f', Corpus::IMPORTCFG_TEMPLATE, 'std'], preparation.fetch('argv')
    assert_equal [JSON.parse(File.readlines(log).first)], [preparation.fetch('argv').drop(1)]
    # Bounded and captured exactly like every other stage: a deadline, a real
    # process receipt, file-backed streams and no surviving descendant.
    assert_equal 60, preparation.fetch('timeout_seconds')
    assert_equal 'exited', preparation.fetch('state')
    assert_equal 0, preparation.fetch('exit')
    assert_nil preparation.fetch('signal')
    assert_equal false, preparation.fetch('descendants_survived')
    assert preparation.fetch('duration_seconds') <= 60
    %w[stdout stderr].each do |stream|
      record = preparation.fetch(stream)
      assert_equal record.fetch('sha256'), Corpus.digest(record.fetch('path')), stream
    end
    # The preparation ran in the exact known context, not merely with a local
    # toolchain: the pinned SDK root, the identity's platform, GOENV and GOWORK
    # disabled, and HOME/TMPDIR/GOCACHE bound to the cache holding the receipt.
    assert_equal context_of(go), receipt.fetch('context')
    assert_equal Corpus.importcfg_environment(context_of(go)), preparation.fetch('environment')
    assert_equal 'local', preparation.fetch('environment').fetch('GOTOOLCHAIN')
    assert_equal File.dirname(File.dirname(go)), preparation.fetch('environment').fetch('GOROOT')
    assert_equal %w[off off], preparation.fetch('environment').values_at('GOENV', 'GOWORK')
    assert_equal %w[testos testarch], preparation.fetch('environment').values_at('GOOS', 'GOARCH')
    assert_equal @cache, preparation.fetch('environment').fetch('GOCACHE')
    assert_equal File.join(@cache, Corpus::IMPORTCFG_HOME), preparation.fetch('environment').fetch('HOME')
    assert_equal File.join(@cache, Corpus::IMPORTCFG_TMP), preparation.fetch('environment').fetch('TMPDIR')
    assert_equal File.join(@cache, Corpus::IMPORTCFG_HOME), preparation.fetch('cwd')
    assert_equal '-mod=readonly -p=2', preparation.fetch('environment').fetch('GOFLAGS'), 'the executor GOFLAGS contract survives preparation'

    # Every published archive is hashed, and the retained rows are exactly the
    # retained package set.
    assert_equal STDLIB_PACKAGES.keys.sort, receipt.fetch('packages').map { |p| p.fetch('name') }.sort
    receipt.fetch('packages').each do |package|
      archive = package.fetch('archive')
      assert_equal archive_path(package.fetch('name')), archive.fetch('path')
      assert_equal Corpus.digest(archive.fetch('path')), archive.fetch('sha256')
      assert_equal File.size(archive.fetch('path')), archive.fetch('bytes')
    end
    assert_equal receipt.fetch('packages').map { |p| "packagefile #{p.fetch('name')}=#{p.fetch('archive').fetch('path')}" },
                 File.read(importcfg_path).lines.map(&:chomp)
  end

  def test_the_retained_configuration_and_receipt_are_immutable
    prepared
    [importcfg_path, receipt_path].each do |path|
      assert_equal 0o444, File.stat(path).mode & 0o777, path
    end
  end

  def test_preparation_happens_once_and_reuse_reauthenticates
    go, log = fake_go
    first = executor(go: go).send(:import_configuration)
    # A separate executor sharing the cache reuses the retained configuration
    # rather than re-running the toolchain, and still authenticates it.
    second = executor(go: go).send(:import_configuration)
    assert_equal first, second
    assert_equal 1, File.readlines(log).length, 'the stdlib export must be prepared once per cache'
  end

  def test_a_configuration_present_without_a_receipt_is_refused
    go, log = fake_go
    File.write(importcfg_path, "packagefile fmt=#{archive_path('fmt')}\n")
    File.binwrite(archive_path('fmt'), STDLIB_PACKAGES.fetch('fmt'))
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/without a preparation receipt/, error.message)
    refute File.exist?(log), 'an unauthenticated configuration must not be adopted'
  end

  def test_a_changed_stdlib_archive_invalidates_the_configuration
    go, = fake_go
    prepared(go)
    File.binwrite(archive_path('fmt'), 'a different archive with the same name')
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/stdlib archive changed since preparation: fmt/, error.message)
  end

  def test_a_missing_stdlib_archive_is_named_rather_than_silently_reprepared
    go, log = fake_go
    prepared(go)
    FileUtils.rm_f(archive_path('errors'))
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/stdlib archive is missing: errors/, error.message)
    assert_equal 1, File.readlines(log).length, 'a lost archive must not silently re-prepare'
  end

  def test_a_configuration_edited_after_preparation_is_refused
    go, = fake_go
    prepared(go)
    File.chmod(0o644, importcfg_path)
    File.write(importcfg_path, File.read(importcfg_path) + "packagefile smuggled=#{archive_path('fmt')}\n")
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/changed since preparation/, error.message)
  end

  def test_an_archive_path_substituted_in_the_retained_rows_is_refused
    go, = fake_go
    receipt = prepared(go)
    File.binwrite(File.join(@tmp, 'substitute.a'), STDLIB_PACKAGES.fetch('fmt'))
    rows = receipt.fetch('packages').map do |package|
      archive = package.fetch('name') == 'fmt' ? File.join(@tmp, 'substitute.a') : package.fetch('archive').fetch('path')
      "packagefile #{package.fetch('name')}=#{archive}"
    end
    File.chmod(0o644, importcfg_path)
    File.write(importcfg_path, rows.join("\n") + "\n")
    # The bytes of the configuration are re-hashed first, so the substitution is
    # caught even though the substitute archive has identical contents.
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/changed since preparation/, error.message)

    # And with the file record refreshed, the rows themselves no longer match the
    # retained package set.
    rewrite_receipt { |r| r.merge!(Corpus.file_record(importcfg_path)) }
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/rows differ from the retained package set/, error.message)
  end

  def test_a_configuration_prepared_by_a_different_toolchain_is_refused
    first, = fake_go
    prepared(first)
    other, = fake_go({ 'behaviour' => 'object' }, name: 'go-other')
    refute_equal Corpus.digest(first), Corpus.digest(other)
    error = assert_raises(Corpus::ContractError) { executor(go: other).send(:import_configuration) }
    assert_match(/prepared by a different toolchain/, error.message)
  end

  def test_a_replaced_toolchain_binary_invalidates_the_configuration
    go, = fake_go
    receipt = prepared(go)
    File.chmod(0o755, go)
    File.write(go, File.read(go) + "\n# a different toolchain at the same path\n")
    error = assert_raises(Corpus::ContractError) do
      Corpus.authenticate_import_configuration!(receipt, tool: nil)
    end
    assert_match(/digest mismatch/, error.message)
  end

  def test_an_unbounded_or_uncaptured_preparation_receipt_is_refused
    go, = fake_go
    prepared(go)
    {
      /not bounded/ => ->(r) { r['preparation']['timeout_seconds'] = nil },
      /not a captured process receipt/ => ->(r) { r['preparation'].delete('stdout') },
      /did not complete/ => ->(r) { r['preparation']['state'] = 'deadline' },
      /leaked a descendant/ => ->(r) { r['preparation']['descendants_survived'] = true },
      /different recipe/ => ->(r) { r['preparation']['argv'] = [go, 'build', 'std'] },
      /escaped the local toolchain/ => ->(r) { r['preparation']['environment']['GOTOOLCHAIN'] = 'auto' },
      /package set changed/ => ->(r) { r['packages_sha256'] = Digest::SHA256.hexdigest('nope') },
      /unknown import configuration schema/ => ->(r) { r['schema'] = 'corpus-importcfg/v0' }
    }.each do |pattern, mutate|
      receipt = JSON.parse(File.read(receipt_path))
      mutate.call(receipt)
      error = assert_raises(Corpus::ContractError, pattern.source) do
        Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go))
      end
      assert_match(pattern, error.message)
    end
  end

  def test_a_preparation_stream_deleted_after_the_fact_is_refused
    go, = fake_go
    receipt = prepared(go)
    stdout = receipt.fetch('preparation').fetch('stdout').fetch('path')
    File.binwrite(stdout, File.binread(stdout) + "packagefile smuggled=/dev/null\n")
    error = assert_raises(Corpus::ContractError) do
      Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go))
    end
    assert_match(/preparation stdout changed/, error.message)
  end

  # ---- named tamper negatives --------------------------------------------

  # The retained stream hash proves only that the log still holds the bytes the
  # receipt claims. An attacker who rewrites the preparation output and refreshes
  # that hash leaves a wholly self-consistent receipt, so the rows have to be
  # re-derived from the stream and joined to the package set and the
  # configuration the compiler is actually handed.
  def test_altered_preparation_output_with_a_self_consistent_stream_hash_is_refused
    go, = fake_go
    prepared(go)
    stdout = JSON.parse(File.read(receipt_path)).fetch('preparation').fetch('stdout').fetch('path')
    smuggled = File.join(@tmp, 'smuggled.a')
    File.binwrite(smuggled, 'a package the toolchain never exported')
    File.binwrite(stdout, "packagefile errors=#{archive_path('errors')}\npackagefile fmt=#{smuggled}\n")
    # Self-consistent: the receipt now names exactly the bytes on disk.
    receipt = rewrite_receipt { |r| r['preparation']['stdout'] = Corpus.file_record(stdout) }
    assert_equal Corpus.digest(stdout), receipt.fetch('preparation').fetch('stdout').fetch('sha256')

    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/retained packages differ from the preparation output: fmt/, error.message)

    # Dropping a row entirely is caught the same way, and names the package.
    File.binwrite(stdout, "packagefile errors=#{archive_path('errors')}\n")
    rewrite_receipt { |r| r['preparation']['stdout'] = Corpus.file_record(stdout) }
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/retained packages differ from the preparation output: fmt/, error.message)

    # An emptied stream cannot publish anything at all.
    File.binwrite(stdout, '')
    rewrite_receipt { |r| r['preparation']['stdout'] = Corpus.file_record(stdout) }
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/published no packages/, error.message)
  end

  # Relocating the stream sidesteps the join by pointing the receipt at a log the
  # cache does not own, so the capture path is part of the contract.
  def test_a_preparation_stream_relocated_out_of_the_cache_is_refused
    go, = fake_go
    prepared(go)
    %w[stdout stderr].each do |stream|
      receipt = JSON.parse(File.read(receipt_path))
      forged = File.join(@tmp, 'forged-' + stream)
      FileUtils.cp(receipt.fetch('preparation').fetch(stream).fetch('path'), forged)
      receipt['preparation'][stream] = Corpus.file_record(forged)
      error = assert_raises(Corpus::ContractError) { Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go)) }
      assert_match(/preparation #{stream} is not the retained capture/, error.message)
    end
  end

  # A receipt that certifies only GOTOOLCHAIN=local would let a preparation run
  # against another SDK root, another platform, an inherited go env or workspace
  # file, or a foreign cache certify a compile. Every one of those is named.
  def test_a_preparation_environment_outside_the_known_context_is_refused
    go, = fake_go
    prepared(go)
    elsewhere = File.join(@tmp, 'another-sdk')
    {
      'GOROOT' => elsewhere, 'GOENV' => File.join(@tmp, 'go/env'), 'GOWORK' => File.join(@tmp, 'go.work'),
      'GOOS' => 'otheros', 'GOARCH' => 'otherarch', 'GOCACHE' => elsewhere,
      'HOME' => elsewhere, 'TMPDIR' => elsewhere, 'GOFLAGS' => '-mod=mod'
    }.each do |key, value|
      receipt = JSON.parse(File.read(receipt_path))
      receipt['preparation']['environment'][key] = value
      error = assert_raises(Corpus::ContractError, key) do
        Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go))
      end
      assert_match(/preparation environment differs: #{key}/, error.message, key)
    end

    # A variable removed outright is a difference too, not an absence to ignore.
    receipt = JSON.parse(File.read(receipt_path))
    receipt['preparation']['environment'].delete('GOENV')
    assert_match(/preparation environment differs: GOENV/,
                 assert_raises(Corpus::ContractError) { Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go)) }.message)

    # And the preparation must have run inside the cache it claims.
    receipt = JSON.parse(File.read(receipt_path))
    receipt['preparation']['cwd'] = @tmp
    assert_match(/ran outside its cache/,
                 assert_raises(Corpus::ContractError) { Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go)) }.message)
  end

  # Rewriting the environment alone is caught above, so the interesting forgery
  # rewrites the retained context to match it. The context is not self-sealing:
  # it is anchored to the authenticated toolchain binary's own path, to the SDK
  # identity, and to the directory the configuration actually lives in.
  def test_a_context_rewritten_to_match_a_wrong_environment_is_still_refused
    go, = fake_go
    prepared(go)
    forge = lambda do |mutate|
      receipt = JSON.parse(File.read(receipt_path))
      mutate.call(receipt['context'])
      receipt['preparation']['environment'] = Corpus.importcfg_environment(receipt['context'])
      assert_raises(Corpus::ContractError) { Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go)) }.message
    end

    assert_match(/GOROOT is not the pinned SDK root/, forge.call(->(c) { c['goroot'] = File.join(@tmp, 'another-sdk') }))
    assert_match(/platform differs from the SDK identity/, forge.call(->(c) { c['goos'] = 'otheros' }))
    assert_match(/platform differs from the SDK identity/, forge.call(->(c) { c['identity'] = 'go version gofake1.0 otheros/testarch' }))
    assert_match(/unusable SDK identity/, forge.call(->(c) { c['identity'] = 'gofake1.0' }))
    assert_match(/cache differs from the directory holding it/, forge.call(->(c) { c['cache'] = File.join(@tmp, 'another-cache') }))
    assert_match(/build environment GOTOOLCHAIN is not "local"/, forge.call(->(c) { c['environment']['GOTOOLCHAIN'] = 'auto' }))
    assert_match(/build environment GOPROXY is not "off"/, forge.call(->(c) { c['environment']['GOPROXY'] = 'https://proxy.example' }))
    assert_match(/build environment GOROOT is not the pinned SDK root/, forge.call(->(c) { c['environment']['GOROOT'] = File.join(@tmp, 'another-sdk') }))
  end

  # A caller that already holds a validated context supplies it, and every
  # supplied key must match exactly. This is what makes an executor refuse a
  # cached configuration prepared for a different build environment.
  def test_a_configuration_prepared_for_a_different_validated_context_is_refused
    go, = fake_go
    prepared(go)
    error = assert_raises(Corpus::ContractError) do
      executor(go: go, env: { 'GOFLAGS' => '-mod=mod' }).send(:import_configuration)
    end
    assert_match(/environment differs from the validated context/, error.message)

    receipt = JSON.parse(File.read(receipt_path))
    error = assert_raises(Corpus::ContractError) do
      Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go), context: { 'cache' => File.join(@tmp, 'another-cache') })
    end
    assert_match(/cache differs from the validated context/, error.message)

    # A receipt with no context at all is refused by name rather than adopted.
    receipt = rewrite_receipt { |r| r.delete('context') }
    assert_match(/retains no known context/,
                 assert_raises(Corpus::ContractError) { Corpus.authenticate_import_configuration!(receipt, tool: sdk_of(go)) }.message)
  end

  # Authenticating once and reusing the answer would certify the archives as they
  # stood at the first compile, not at the compile that actually used them. The
  # same executor instance must refuse the second compile.
  def test_an_archive_changed_after_a_first_successful_compile_is_refused_on_reuse
    go, = fake_go('behaviour' => 'object')
    inputs, sources = source
    instance = executor(go: go, bashy: fake_bashy)
    assert_equal 'complete', run_mode(instance, 'baseline', inputs, sources)['state']

    File.binwrite(archive_path('fmt'), 'a different archive after the first compile')
    error = assert_raises(Corpus::ContractError) { run_mode(instance, 'compiled', inputs, sources) }
    assert_match(/stdlib archive changed since preparation: fmt/, error.message)
    refute File.exist?(File.join(@tmp, 'case/compiled/artifacts/object.o')), 'no compile may proceed against a changed archive'
  end

  # The configuration is resolved where it is used, so an archive swapped by an
  # earlier stage of the very same mode is caught before the compile spawns.
  def test_an_archive_changed_between_transpile_and_compile_is_refused
    go, = fake_go('behaviour' => 'object')
    prepared(go)
    inputs, sources = source
    instance = executor(go: go, bashy: fake_bashy(tamper_archive: archive_path('errors')))
    error = assert_raises(Corpus::ContractError) { run_mode(instance, 'compiled', inputs, sources) }
    assert_match(/stdlib archive changed since preparation: errors/, error.message)
    refute File.exist?(File.join(@tmp, 'case/compiled/artifacts/object.o')), 'the compile must never spawn'
  end

  def test_a_failed_or_hung_preparation_never_yields_a_configuration
    go, = fake_go('list_exit' => 3, 'list_stderr' => 'go: cannot load standard library')
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/stdlib importcfg unavailable \(exited\): go: cannot load standard library/, error.message)
    refute File.exist?(importcfg_path)
    refute File.exist?(receipt_path)

    FileUtils.rm_rf(@cache)
    FileUtils.mkdir_p(@cache)
    hung, = fake_go({ 'list_sleep' => 30 }, name: 'go-hung')
    error = assert_raises(Corpus::ContractError) do
      executor(go: hung, importcfg_timeout: 1).send(:import_configuration)
    end
    assert_match(/stdlib importcfg unavailable \(deadline\)/, error.message)
    refute File.exist?(receipt_path), 'a deadline must not publish a configuration'
  end

  def test_an_empty_or_malformed_export_listing_is_refused
    go, = fake_go('list_silent' => true)
    error = assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }
    assert_match(/stdlib importcfg is empty/, error.message)

    FileUtils.rm_rf(@cache); FileUtils.mkdir_p(@cache)
    go, = fake_go({ 'list_rows' => ['packagefile fmt='] }, name: 'go-empty-archive')
    assert_match(/malformed importcfg row/, assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }.message)

    FileUtils.rm_rf(@cache); FileUtils.mkdir_p(@cache)
    go, = fake_go({ 'list_rows' => ['packagefile fmt=/certainly/not/an/archive.a'] }, name: 'go-absent-archive')
    assert_match(%r{importcfg archive missing: /certainly/not/an/archive\.a}, assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }.message)

    FileUtils.rm_rf(@cache); FileUtils.mkdir_p(@cache)
    duplicate = "packagefile fmt=#{archive_path('fmt')}"
    File.binwrite(archive_path('fmt'), STDLIB_PACKAGES.fetch('fmt'))
    go, = fake_go({ 'list_rows' => [duplicate, duplicate] }, name: 'go-duplicate')
    assert_match(/repeats a package/, assert_raises(Corpus::ContractError) { executor(go: go).send(:import_configuration) }.message)
  end

  def test_an_unbounded_preparation_deadline_is_rejected_at_construction
    error = assert_raises(Corpus::ContractError) do
      Corpus::Executor.new(bashy: '/certainly/not/a/bashy', go: fake_go.first, evidence_root: @tmp,
                           candidate: {}, sdk: {}, importcfg_timeout: 0)
    end
    assert_equal 'importcfg preparation must be bounded', error.message
  end

  # ---- compile phases -----------------------------------------------------

  def test_compile_baseline_uses_the_upstream_compile_recipe_and_never_links
    go, log = fake_go('behaviour' => 'object')
    inputs, sources = source
    result = run_mode(executor(go: go), 'baseline', inputs, sources)

    assert_equal 'complete', result['state'], result.inspect
    assert_equal ['compile'], result['stages'].map { |stage| stage['stage'] }
    argv = result['stages'].fetch(0).fetch('argv')
    object = result.fetch('artifacts').fetch('object').fetch('path')
    assert_equal [go, 'tool', 'compile', '-e', '-p=p', '-importcfg=' + importcfg_path, '-o', object, sources.fetch(0)], argv
    # An ordinary `go build` links, so it rejects a valid `package main` that
    # declares no `main`. It can never stand in as the compile oracle.
    refute_includes argv, 'build'
    refute result.fetch('artifacts').key?('native'), 'compile-only phase must not retain a linked program'

    configuration = result.fetch('import_configuration')
    assert_equal importcfg_path, configuration.fetch('path')
    # The retained configuration is the authenticated receipt, not a bare digest.
    assert Corpus.authenticate_import_configuration!(configuration, tool: sdk_of(go))
    assert_equal [%w[list -export], %w[tool compile]],
                 File.readlines(log).map { |line| JSON.parse(line).first(2) }
  end

  def test_compile_interpreted_mode_checks_the_original_source_and_never_runs_it
    inputs, sources = source
    instance = executor(go: '/certainly/not/a/go', bashy: fake_bashy)
    result = run_mode(instance, 'interpreted', inputs, sources)

    assert_equal 'complete', result['state'], result.inspect
    assert_equal ['check'], result['stages'].map { |stage| stage['stage'] }
    argv = result['stages'].fetch(0).fetch('argv')
    assert_equal File.join(@tmp, 'case/interpreted/work', sources.fetch(0)), argv.last, 'the interpreter checks the copied original source itself'
    %w[--bashpp --source=go --check].each { |flag| assert_includes argv, flag }
    assert_empty result.fetch('artifacts')
    refute result.key?('effects'), 'a compile-only obligation never observes runtime effects'
    # The interpreted mode publishes no stdlib archives, so it retains no
    # configuration and never triggers preparation.
    refute result.key?('import_configuration')
    refute File.exist?(receipt_path)
  end

  def test_compile_interpreted_check_failure_is_not_credited
    inputs, sources = source
    instance = executor(go: '/certainly/not/a/go', bashy: fake_bashy(check_exit: 1))
    result = run_mode(instance, 'interpreted', inputs, sources)
    assert_equal 'stage_failure', result['state']
  end

  def test_compiled_mode_requires_a_generated_source_map_and_object_archive
    go, = fake_go('behaviour' => 'object')
    inputs, sources = source
    result = run_mode(executor(go: go, bashy: fake_bashy), 'compiled', inputs, sources)

    assert_equal 'complete', result['state'], result.inspect
    assert_equal %w[transpile compile], result['stages'].map { |stage| stage['stage'] }
    artifacts = result.fetch('artifacts')
    assert_equal %w[generated object source_map], artifacts.keys.sort
    assert_equal artifacts.fetch('generated').fetch('path'), result['stages'].fetch(1).fetch('argv').last
    assert Corpus.go_object_archive?(artifacts.fetch('object').fetch('path'))
    assert Corpus.authenticate_import_configuration!(result.fetch('import_configuration'), tool: sdk_of(go))
  end

  def test_a_compile_phase_cannot_run_without_a_usable_import_configuration
    go, = fake_go('behaviour' => 'object', 'list_exit' => 1)
    inputs, sources = source
    assert_raises(Corpus::ContractError) { run_mode(executor(go: go), 'baseline', inputs, sources) }
    refute File.exist?(File.join(@tmp, 'case/baseline/artifacts/object.o')), 'no compile may start without an authenticated configuration'
  end

  def test_successful_compile_without_an_object_fails_closed
    go, = fake_go('behaviour' => 'empty')
    inputs, sources = source
    result = run_mode(executor(go: go), 'baseline', inputs, sources)
    assert_equal 'missing_artifact', result['state']
    assert_equal 0, result['stages'].fetch(0).fetch('exit')
    refute result.fetch('artifacts').key?('object')
  end

  def test_nonempty_output_that_is_not_a_go_archive_is_not_a_compile_result
    go, = fake_go('behaviour' => 'junk')
    inputs, sources = source
    result = run_mode(executor(go: go), 'baseline', inputs, sources)
    assert_equal 'missing_artifact', result['state']
    refute result.fetch('artifacts').key?('object')
  end

  def test_compile_diagnostics_are_a_stage_failure_never_a_pass
    go, = fake_go('behaviour' => 'fail')
    inputs, sources = source("package p\n\nfunc bad() { x }\n", 'bad.go')
    result = run_mode(executor(go: go), 'baseline', inputs, sources)
    assert_equal 'stage_failure', result['state']
    assert_equal 2, result['stages'].fetch(0).fetch('exit')
    assert_match(/undefined: x/, File.binread(result['stages'].fetch(0).fetch('stderr').fetch('path')))
  end

  def test_source_rewritten_by_the_toolchain_fails_closed
    inputs, sources = source
    tampered = File.join(@tmp, 'case/baseline/work', sources.fetch(0))
    go, = fake_go('behaviour' => 'tamper', 'tamper_path' => tampered)
    result = run_mode(executor(go: go), 'baseline', inputs, sources)

    assert_equal 'input_mutation', result['state']
    refute result['input_integrity']
    assert_includes result.fetch('input_checks').map { |check| check['valid'] }, false
    # The immutable upstream input itself is untouched.
    assert_equal inputs.fetch(sources.fetch(0)).fetch('sha256'), Corpus.digest(File.join(@tmp, sources.fetch(0)))
  end

  def test_object_archive_validator_rejects_malformed_and_foreign_files
    path = File.join(@tmp, 'candidate.o')
    write = lambda do |bytes|
      File.binwrite(path, bytes)
      Corpus.go_object_archive?(path)
    end

    assert write.call(object_archive_bytes)
    refute write.call(''), 'empty file'
    refute write.call('not an archive'), 'arbitrary nonempty file'
    refute write.call(object_archive_bytes[0, 40]), 'truncated member header'
    refute write.call(object_archive_bytes + 'trailing'), 'trailing garbage outside the members'
    refute write.call(object_archive_bytes('__.PKGDEF' => "go object test\n")), 'missing compiled object member'
    refute write.call(object_archive_bytes('_go_.o' => "go object test\n" + GO_OBJECT_MAGIC)), 'missing package export member'
    refute write.call(object_archive_bytes('__.PKGDEF' => "go object test\n\n!\n",
                                           '_go_.o' => "go object test\n\n!\nno magic here")), 'object member without goobj magic'
    refute write.call(object_archive_bytes('__.PKGDEF' => 'foreign export data',
                                           '_go_.o' => 'foreign' + GO_OBJECT_MAGIC)), 'members that are not Go objects'
    refute Corpus.native_binary?(path.tap { File.binwrite(path, object_archive_bytes) }), 'an archive is not a native program'
  end

  def test_compile_verdict_requires_every_mode_to_complete_with_intact_input
    complete = Corpus::MODES.to_h { |mode| [mode, { 'state' => 'complete', 'input_integrity' => true }] }
    instance = executor(go: '/certainly/not/a/go')
    assert_equal 'PASS', instance.send(:exact_verdict, 'modes' => complete, 'phase' => 'compile')
    Corpus::MODES.each do |mode|
      broken = complete.merge(mode => { 'state' => 'stage_failure', 'input_integrity' => true })
      assert_equal 'FAIL', instance.send(:exact_verdict, 'modes' => broken, 'phase' => 'compile'), mode
      mutated = complete.merge(mode => { 'state' => 'complete', 'input_integrity' => false })
      assert_equal 'FAIL', instance.send(:exact_verdict, 'modes' => mutated, 'phase' => 'compile'), mode
    end
  end

  def test_directory_and_link_phases_are_still_refused_by_name
    instance = executor(go: '/certainly/not/a/go')
    authenticated = %w[launcher payload sdk].to_h do |name|
      path = File.join(@tmp, name)
      File.write(path, name)
      [name, { 'path' => path, 'sha256' => Corpus.digest(path) }]
    end
    instance.instance_variable_set(:@provenance, 'candidate' => { 'launcher' => authenticated.fetch('launcher'), 'payload' => authenticated.fetch('payload') },
                                                 'sdk' => { 'binary' => authenticated.fetch('sdk') })
    File.write(File.join(@tmp, 'a.go'), "package p\n")
    %w[compiledir builddir link buildrun].each do |phase|
      error = assert_raises(Corpus::ContractError) do
        instance.execute(id: 'phase-' + phase, source_root: @tmp, sources: ['a.go'], phase: phase)
      end
      assert_equal 'unknown phase', error.message, phase
    end
  end

  def test_only_plain_unflagged_compile_recipes_enter_the_adapter
    root = { 'recipe' => { 'action' => 'compile', 'flags' => [], 'args' => [], 'environment_append' => [] },
             'expected_failure_sets' => [] }
    assert GoFullProduct.simple_recipe?(root)
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('flags' => ['-tags=magic'])))
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('environment_append' => [%w[GODEBUG x=1]])))
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('timeout_seconds_before_scale' => 5)))
    refute GoFullProduct.simple_recipe?(root.merge('expected_failure_sets' => ['types2']))
    %w[compiledir directory generated_program program_directory_inputs nested_process_obligation].each do |key|
      next if key == 'compiledir'
      refute GoFullProduct.simple_recipe?(root.merge(key => {})), key
    end
    refute GoFullProduct.simple_recipe?(root.merge('recipe' => root['recipe'].merge('action' => 'compiledir')))
  end
end
