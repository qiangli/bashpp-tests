# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
#
# Focused tests for the official Go type-checker recipe adapter. The integration
# controls execute the real frozen candidate against real, byte-identical
# fixtures from the pinned SDK source inventory; they are bounded to a handful of
# roots and never claim any corpus-wide result.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../../tools/corpus/executor'
require_relative '../../tools/go-full/typechecker'

class TypecheckerRecipeOptionsTest < Minitest::Test
  INVENTORY = File.expand_path('../../docs/go-full/typechecker-roots.jsonl', __dir__)
  SOURCE_ROOT = '/Users/qiangli/.bashy/sprint118/sources/go-full/go'

  def roots
    @roots ||= File.foreach(INVENTORY).map { |line| JSON.parse(line).merge('axis' => 'typechecker') }
  end

  def test_phases_are_the_two_declared_root_obligations
    assert_equal %w[check-original-fixture match-source-positioned-diagnostics], GoFullTypechecker::PHASES
    assert_equal %w[interpreted compiled], GoFullTypechecker::MODES
  end

  def test_recipe_flags_ports_the_harness_first_line_rule
    assert_equal ['-lang=go1.21'], GoFullTypechecker.recipe_flags("// -lang=go1.21\npackage p\n")
    assert_equal ['-goexperiment', 'aliastypeparams'], GoFullTypechecker.recipe_flags("//   -goexperiment aliastypeparams\npackage p\n")
    assert_equal ['-fakeImportC'], GoFullTypechecker.recipe_flags("// -fakeImportC\npackage p\n")
    # Not a flags line: no leading line comment, or text before the first dash.
    assert_empty GoFullTypechecker.recipe_flags("package p\n")
    assert_empty GoFullTypechecker.recipe_flags("/* -lang=go1.21 */\npackage p\n")
    assert_empty GoFullTypechecker.recipe_flags("// Copyright 2011 The Go Authors.\npackage p\n")
  end

  def test_over_long_flag_line_is_a_contract_error_not_a_silent_pass
    assert_raises(Corpus::ContractError) { GoFullTypechecker.recipe_flags('// -lang=' + ('x' * 300) + "\npackage p\n") }
  end

  def test_unsupported_options_are_named_for_every_inexecutable_recipe
    Dir.mktmpdir('tc-opts-') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'src'))
      File.write(File.join(dir, 'src/flagged.go'), "// -lang=go1.21\npackage p\n")
      File.write(File.join(dir, 'src/plain.go'), "package p\n")
      File.write(File.join(dir, 'src/other.go'), "package p\n")

      flagged = { 'axis' => 'typechecker', 'input_files' => ['src/flagged.go'], 'build_constraints' => { 'src/flagged.go' => [] } }
      assert_empty GoFullTypechecker.unsupported_options(flagged, dir)
      assert GoFullTypechecker.adaptable?(flagged, dir)

      gated = { 'axis' => 'typechecker', 'input_files' => ['src/plain.go'], 'build_constraints' => { 'src/plain.go' => ['//go:build ignore'] } }
      assert_equal ['build-tag-applicability:src/plain.go'], GoFullTypechecker.unsupported_options(gated, dir)

      joint = { 'axis' => 'typechecker', 'input_files' => ['src/plain.go', 'src/other.go'], 'build_constraints' => {} }
      assert_empty GoFullTypechecker.unsupported_options(joint, dir)
      assert GoFullTypechecker.adaptable?(joint, dir)

      plain = { 'axis' => 'typechecker', 'input_files' => ['src/plain.go'], 'build_constraints' => { 'src/plain.go' => [] } }
      assert_empty GoFullTypechecker.unsupported_options(plain, dir)
      assert GoFullTypechecker.adaptable?(plain, dir)
    end
  end

  def test_an_unreadable_recipe_header_is_an_unsupported_option_not_an_abort
    Dir.mktmpdir('tc-bad-') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'src'))
      File.write(File.join(dir, 'src/bad.go'), '// -lang=' + ('x' * 300) + "\npackage p\n")
      root = { 'axis' => 'typechecker', 'input_files' => ['src/bad.go'], 'build_constraints' => {} }
      assert_equal ['unreadable-recipe-header:src/bad.go'], GoFullTypechecker.unsupported_options(root, dir)
      refute GoFullTypechecker.adaptable?(root, dir)

      missing = { 'axis' => 'typechecker', 'input_files' => ['src/absent.go'], 'build_constraints' => {} }
      assert_equal ['unreadable-recipe-header:src/absent.go'], GoFullTypechecker.unsupported_options(missing, dir)
    end
  end

  def test_only_typechecker_roots_are_adaptable
    Dir.mktmpdir('tc-axis-') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'src'))
      File.write(File.join(dir, 'src/plain.go'), "package p\n")
      root = { 'axis' => 'testdir', 'input_files' => ['src/plain.go'], 'build_constraints' => {} }
      refute GoFullTypechecker.adaptable?(root, dir)
    end
  end

  def test_complete_743_root_denominator_is_partitioned_without_any_skip
    skip 'pinned SDK source inventory is unavailable' unless File.directory?(SOURCE_ROOT)
    assert_equal 743, roots.length
    adaptable, unsupported = roots.partition { |root| GoFullTypechecker.adaptable?(root, SOURCE_ROOT) }
    assert_equal 743, adaptable.length + unsupported.length
    assert_equal 721, adaptable.length
    assert_equal 22, unsupported.length
    # Every unsupported root names why, and still owes both obligations.
    unsupported.each do |root|
      refute_empty GoFullTypechecker.unsupported_options(root, SOURCE_ROOT), root.fetch('id')
    end
  end

  def test_unsupported_roots_fail_with_named_phases_and_never_a_new_skip
    driver = File.read(File.expand_path('../../tools/go-full/product.rb', __dir__))
    resume = File.read(File.expand_path('../../tools/go-full/resume.rb', __dir__))
    phases = '%w[' + GoFullTypechecker::PHASES.join(' ') + ']'
    assert_includes driver, phases, 'the driver must still owe both check obligations'
    assert_includes resume, phases, 'the resume validator must still owe both check obligations'
    assert_includes driver, "row['unsupported_recipe_options'] = GoFullTypechecker.unsupported_options"
    # The only skip verdict in the driver remains the retained native skip.
    assert_equal 1, driver.scan("'UPSTREAM_SKIP'").length
    refute_includes driver, 'TYPECHECKER_SKIP'
  end

  def test_the_new_adapter_is_fail_closed_for_resume_until_independently_validated
    resume = File.read(File.expand_path('../../tools/go-full/resume.rb', __dir__))
    assert_includes resume, "root['axis'] == 'typechecker' && row.key?('typechecker_evidence')"
    # New harness code changes the checkpoint context, so old receipts cannot be
    # upgraded into credit for this adapter.
    assert_includes resume, "typecheck-diagnostics/*"
  end

  # The colDelta each runner passes to testFiles, read from the pinned SDK:
  # src/go/types/check_test.go pins `const colDelta = 0` for every family, and
  # src/cmd/compile/internal/types2/check_test.go passes a per-family delta.
  # Pinning the whole family->tolerance mapping, not just the set of values,
  # so a mapping shuffled between families cannot silently widen a tolerance.
  GO_TYPES_COLDELTA = { 'TestCheck' => 0, 'TestSpec' => 0, 'TestExamples' => 0, 'TestFixedbugs' => 0, 'TestLocal' => 0 }.freeze
  TYPES2_COLDELTA = { 'TestCheck' => 50, 'TestSpec' => 20, 'TestExamples' => 125, 'TestFixedbugs' => 100, 'TestLocal' => 0 }.freeze

  def test_column_tolerance_mirrors_each_runner
    skip 'pinned SDK source inventory is unavailable' unless File.directory?(SOURCE_ROOT)
    go_types = roots.select { |root| root.fetch('runner').start_with?('src/go/types/') }
    assert_equal [0], go_types.map { |root| root.fetch('column_tolerance') }.uniq
    types2 = roots.select { |root| root.fetch('runner').start_with?('src/cmd/compile/') }
    assert_equal [0, 20, 50, 100, 125], types2.map { |root| root.fetch('column_tolerance') }.uniq.sort

    # Every root carries exactly the colDelta its own runner and family pin.
    { go_types => GO_TYPES_COLDELTA, types2 => TYPES2_COLDELTA }.each do |group, expected|
      observed = group.group_by { |root| root.fetch('family') }.transform_values do |rows|
        rows.map { |root| root.fetch('column_tolerance') }.uniq
      end
      assert_equal expected.keys.sort, observed.keys.sort
      expected.each { |family, delta| assert_equal [delta], observed.fetch(family), "#{family} column tolerance" }
    end
    # types2 TestLocal shares go/types' exact-position requirement: it is 0, not
    # a widened family delta, so it must never be lumped in with the twins.
    assert_equal 0, TYPES2_COLDELTA.fetch('TestLocal')
  end

  # --- joint multi-file package controls (portable: no candidate, no SDK) ---

  # check_test.go testFiles applies parseFlags(srcs[0], flags). The flags line of
  # the first file is the entire checker configuration; a flags line in a later
  # file of the same package is ignored by upstream and must be ignored here.
  # Choosing "the first file that carries flags" instead would apply a -lang that
  # the native harness never applies.
  def test_checker_configuration_is_read_from_the_first_file_only
    Dir.mktmpdir('tc-first-') do |dir|
      File.write(File.join(dir, 'a.go'), "package p\n")
      File.write(File.join(dir, 'b.go'), "// -lang=go1.12\npackage p\n")
      assert_nil GoFullTypechecker.package_configuration(dir, %w[a.go b.go]).fetch('go_version')
      # Reversing the package order moves the flags line into srcs[0].
      assert_equal 'go1.12', GoFullTypechecker.package_configuration(dir, %w[b.go a.go]).fetch('go_version')
      # A later file's unsupported flag is likewise not this root's obligation.
      File.write(File.join(dir, 'c.go'), "// -fakeImportC\npackage p\n")
      root = { 'axis' => 'typechecker', 'input_files' => %w[a.go c.go], 'build_constraints' => {} }
      assert_empty GoFullTypechecker.unsupported_options(root, dir)
      first = { 'axis' => 'typechecker', 'input_files' => %w[c.go a.go], 'build_constraints' => {} }
      assert_equal ['harness-flag:-fakeImportC'], GoFullTypechecker.unsupported_options(first, dir)
    end
  end

  # Every file of the package is copied and checked, so any file being absent or
  # carrying an unparsable header is an unexecutable option - never a silent
  # fallback to checking whichever files happen to be readable.
  def test_a_missing_or_malformed_second_file_is_an_unsupported_option
    Dir.mktmpdir('tc-second-') do |dir|
      File.write(File.join(dir, 'a.go'), "package p\n")
      File.write(File.join(dir, 'bad.go'), '// -lang=' + ('x' * 300) + "\npackage p\n")

      missing = { 'axis' => 'typechecker', 'input_files' => %w[a.go gone.go], 'build_constraints' => {} }
      assert_equal ['unreadable-recipe-header:gone.go'], GoFullTypechecker.unsupported_options(missing, dir)
      refute GoFullTypechecker.adaptable?(missing, dir)

      # An over-long flags line in srcs[0] is the upstream parseFlags error.
      malformed = { 'axis' => 'typechecker', 'input_files' => %w[bad.go a.go], 'build_constraints' => {} }
      assert_equal ['unreadable-recipe-header:bad.go'], GoFullTypechecker.unsupported_options(malformed, dir)

      empty = { 'axis' => 'typechecker', 'input_files' => [], 'build_constraints' => {} }
      assert_equal ['empty-input-file-set'], GoFullTypechecker.unsupported_options(empty, dir)
      refute GoFullTypechecker.adaptable?(empty, dir)
    end
  end

  # A bare positional selector makes the frontend check only the first file and
  # silently drop the rest, which reports a cross-file definition as undefined.
  # Every file must therefore arrive as its own --go-file, in the root's order.
  def test_checking_argv_carries_every_file_exactly_once_in_order
    %w[interpreted compiled].each do |mode|
      argv = GoFullTypechecker.checking_argv('/candidate/bashy', mode, %w[a.go b.go c.go], '/fresh/generated.go')
      assert_equal ['--go-file=a.go', '--go-file=b.go', '--go-file=c.go'], argv.grep(/\A--go-file=/)
      assert_equal 3, argv.length - argv.reject { |a| a.start_with?('--go-file=') }.length
      # No file is also passed positionally, which would check it twice.
      %w[a.go b.go c.go].each { |f| refute_includes argv, f }
      assert_equal 1, argv.count('--source=go')
    end
    assert_raises(Corpus::ContractError) { GoFullTypechecker.checking_argv('/b', 'interpreted', [], '/g.go') }
  end
end

# Bounded integration controls against the real frozen candidate and the real
# pinned fixtures. Nothing here is evidence for the full 743-root denominator.
class TypecheckerIntegrationControlTest < Minitest::Test
  SOURCE_ROOT = '/Users/qiangli/.bashy/sprint118/sources/go-full/go'
  SDK_IDENTITY = '/Users/qiangli/.bashy/sprint118/sources/go-full-sdk-identity-relocated.json'
  CANDIDATE = '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-006/candidate.json'
  BASHY = '/private/tmp/s118-runtime-006/bashy/bin/bashy'

  # A negative fixture whose single annotation the candidate reports exactly.
  NEGATIVE = 'src/internal/types/testdata/check/blank.go'
  # A positive fixture with no annotations that the candidate accepts.
  POSITIVE = 'src/internal/types/testdata/check/chans.go'
  # A negative fixture the candidate does not yet satisfy: it emits diagnostics
  # that no annotation covers. It must FAIL, never pass on its exit status.
  SHORTFALL = 'src/internal/types/testdata/check/conversions0.go'

  def available?
    [SOURCE_ROOT, SDK_IDENTITY, CANDIDATE, BASHY].all? { |path| File.exist?(path) }
  end

  # The matcher is built once per process: it is an immutable input to every
  # control below, and rebuilding it per test buys no additional coverage.
  def self.shared_matcher(sdk)
    @shared_matcher ||= begin
      root = Dir.mktmpdir('tc-matcher-')
      Minitest.after_run { FileUtils.remove_entry(root) if File.directory?(root) }
      GoFullTypechecker.build_matcher(File.join(root, 'matcher'), sdk)
    end
  end

  def setup
    skip 'frozen candidate006 or pinned SDK is unavailable' unless available?
    @tmp = Dir.mktmpdir('tc-integration-')
    @sdk = JSON.parse(File.read(SDK_IDENTITY))
    @candidate = JSON.parse(File.read(CANDIDATE))
    @matcher = self.class.shared_matcher(@sdk)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  def root_for(relative, family: 'TestCheck', tolerance: 0)
    { 'axis' => 'typechecker', 'id' => 'go/types:' + family + '/' + File.basename(relative), 'family' => family,
      'input_files' => [relative], 'path' => relative, 'build_constraints' => { relative => [] },
      'column_tolerance' => tolerance, 'runner' => 'src/go/types/check_test.go', 'runner_sha256' => 'x' * 64 }
  end

  def run_root(relative, name, **kwargs)
    root = root_for(relative, **kwargs)
    GoFullTypechecker.execute(root: root, options: { bashy: BASHY, timeout: 60 }, source_root: SOURCE_ROOT,
                              evidence: File.join(@tmp, name), sdk_identity: @sdk, candidate: @candidate, matcher: @matcher)
  end

  def test_matcher_is_built_from_its_own_sources_and_is_separate_from_the_testdir_matcher
    assert_operator @matcher.fetch('binary').fetch('bytes'), :>, 0
    assert_operator @matcher.fetch('sources').length, :>=, 4
    refute_includes @matcher.fetch('sources').keys.join(','), '/diagnostics/'
  end

  def test_negative_fixture_with_exact_positioned_diagnostic_passes_in_both_phases
    result = run_root(NEGATIVE, 'negative')
    assert_equal 'PASS', result.fetch('verdict'), result.fetch('modes').to_s[0, 400]
    assert_equal %w[interpreted compiled], result.fetch('modes').keys
    result.fetch('modes').each_value do |mode|
      assert_equal 'PASS', mode.fetch('verdict')
      assert mode.fetch('input_integrity')
      assert_equal 'exited', mode.dig('stage', 'state')
      refute_equal 0, mode.dig('stage', 'exit'), 'a negative fixture must be rejected'
      # Real argv/env/status/streams are retained for every checking phase.
      assert_includes mode.dig('stage', 'argv'), '--source=go'
      assert_equal '2', mode.dig('stage', 'environment', 'GOMAXPROCS')
      assert_equal '-p=2', mode.dig('stage', 'environment', 'GOFLAGS')
      assert_equal 60, mode.dig('stage', 'timeout_seconds')
      assert_operator mode.dig('match', 'response', 'match', 'expected_diagnostics'), :>, 0
      assert_equal mode.dig('match', 'response', 'match', 'expected_diagnostics'), mode.dig('match', 'response', 'match', 'matched_diagnostics')
    end
    assert_equal GoFullTypechecker::PHASES, result.dig('evidence', 'phases')
    assert_equal({ 'expected' => 2, 'observed' => 2 }, result.dig('evidence', 'mode_denominator'))
  end

  def test_positive_fixture_without_annotations_passes_only_when_accepted_silently
    result = run_root(POSITIVE, 'positive')
    assert_equal 'PASS', result.fetch('verdict'), result.fetch('modes').to_s[0, 400]
    result.fetch('modes').each_value do |mode|
      assert_equal 0, mode.dig('stage', 'exit')
      refute mode.dig('match', 'response', 'want_error')
      assert_equal 0, mode.dig('match', 'response', 'match', 'observed_diagnostics')
    end
  end

  def test_unmatched_product_diagnostics_fail_instead_of_passing_on_the_exit_status
    result = run_root(SHORTFALL, 'shortfall')
    assert_equal 'FAIL', result.fetch('verdict')
    result.fetch('modes').each_value do |mode|
      # The frontend does reject the fixture, but the exit code alone earns nothing.
      refute_equal 0, mode.dig('stage', 'exit')
      assert_equal 'FAIL', mode.fetch('verdict')
      assert_operator mode.dig('match', 'response', 'match', 'unmatched_observed').length, :>, 0
      assert_match(/unexpected diagnostic/, mode.fetch('reason'))
    end
  end

  def test_original_fixture_bytes_are_checked_unchanged_and_retained
    result = run_root(NEGATIVE, 'integrity')
    original = File.join(SOURCE_ROOT, NEGATIVE)
    record = result.dig('evidence', 'checked_fixture')
    assert_equal Corpus.digest(original), record.fetch('sha256')
    assert_equal File.size(original), record.fetch('bytes')
    result.fetch('modes').each_value do |mode|
      copy = File.join(mode.dig('stage', 'cwd'), NEGATIVE)
      assert_equal File.binread(original), File.binread(copy), 'the checked input must be the full original file'
    end
  end

  def test_a_tampered_fixture_copy_cannot_be_adjudicated
    result = run_root(NEGATIVE, 'tamper')
    mode = result.fetch('modes').fetch('interpreted')
    directory = File.dirname(mode.dig('stage', 'cwd'))
    copy = File.join(mode.dig('stage', 'cwd'), NEGATIVE)
    File.binwrite(copy, "package p\n")
    request = JSON.parse(File.read(mode.dig('match', 'request', 'path')))
    tampered = GoFullTypechecker.adjudicate(@matcher, request, File.join(directory, 'retry'), 60)
    assert_equal 'FAIL', tampered.dig('response', 'verdict')
    assert_match(/checksum mismatch/, tampered.dig('response', 'reason'))
  end

  def test_a_tampered_output_stream_cannot_be_adjudicated
    result = run_root(NEGATIVE, 'tamper-stream')
    mode = result.fetch('modes').fetch('interpreted')
    directory = File.dirname(mode.dig('stage', 'cwd'))
    request = JSON.parse(File.read(mode.dig('match', 'request', 'path')))
    File.binwrite(request.fetch('stderr').fetch('path'), "src/internal/types/testdata/check/blank.go:1:1: invalid package name _\n")
    tampered = GoFullTypechecker.adjudicate(@matcher, request, File.join(directory, 'retry-stream'), 60)
    assert_equal 'FAIL', tampered.dig('response', 'verdict')
    assert_match(/checksum mismatch/, tampered.dig('response', 'reason'))
  end

  def test_the_adapter_makes_no_corpus_wide_claim
    result = run_root(NEGATIVE, 'scope')
    assert_equal 'go-full-typechecker/v1', result.dig('evidence', 'adapter')
    assert_match(/never supplies diagnostics/, result.dig('evidence', 'native_oracle_binding'))
    assert_match(/both checking phases/, result.dig('evidence', 'credit_rule'))
  end
end

# Bounded joint multi-file controls against the real frozen candidate012 and the
# real pinned fixtures. These cover the 8 multi-file roots of the 743-root
# denominator; nothing here is evidence for the other 735.
class TypecheckerJointPackageControlTest < Minitest::Test
  INVENTORY = File.expand_path('../../docs/go-full/typechecker-roots.jsonl', __dir__)
  SOURCE_ROOT = '/Users/qiangli/.bashy/sprint118/sources/go-full/go'
  SDK_IDENTITY = '/Users/qiangli/.bashy/sprint118/sources/go-full-sdk-identity-relocated.json'
  CANDIDATE = '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-012/candidate.json'
  BASHY = '/tmp/s118-runtime-012/bashy/bin/bashy'

  def self.joint_roots
    @joint_roots ||= File.foreach(INVENTORY).map { |line| JSON.parse(line).merge('axis' => 'typechecker') }
                         .select { |root| root.fetch('input_files').length > 1 }
  end

  def available?
    [SOURCE_ROOT, SDK_IDENTITY, CANDIDATE, BASHY, BASHY + '.real'].all? { |path| File.exist?(path) }
  end

  def setup
    skip 'frozen candidate012 or pinned SDK is unavailable' unless available?
    @tmp = Dir.mktmpdir('tc-joint-')
    @sdk = JSON.parse(File.read(SDK_IDENTITY))
    # The real frozen candidate record: both hashes are the recorded ones, and
    # the adapter authenticates the launcher and its payload against them.
    @candidate = JSON.parse(File.read(CANDIDATE))
    @matcher = TypecheckerIntegrationControlTest.shared_matcher(@sdk)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  def execute(root, name, source_root: SOURCE_ROOT)
    GoFullTypechecker.execute(root: root, options: { bashy: BASHY, timeout: 120 }, source_root: source_root,
                              evidence: File.join(@tmp, name), sdk_identity: @sdk, candidate: @candidate, matcher: @matcher)
  end

  # The frozen candidate is authenticated by its real recorded digests: a fixture
  # bearing any other bytes cannot be checked in the candidate's name.
  def test_the_frozen_candidate_is_authenticated_by_its_recorded_digests
    assert_equal Corpus.digest(BASHY), @candidate.fetch('launcher_sha256')
    assert_equal Corpus.digest(BASHY + '.real'), @candidate.fetch('payload_sha256')
    imposter = @candidate.merge('payload_sha256' => '0' * 64)
    root = self.class.joint_roots.fetch(0)
    assert_raises(Corpus::ContractError) do
      GoFullTypechecker.execute(root: root, options: { bashy: BASHY, timeout: 120 }, source_root: SOURCE_ROOT,
                                evidence: File.join(@tmp, 'imposter'), sdk_identity: @sdk, candidate: imposter, matcher: @matcher)
    end
  end

  # All 8 multi-file roots of the denominator, executed for real. The verdicts
  # are recorded as observed; a root that does not satisfy both obligations FAILs
  # and is reported, never coerced to PASS.
  def test_every_joint_root_is_checked_as_one_package_in_both_phases
    roots = self.class.joint_roots
    assert_equal 8, roots.length
    observed = roots.to_h do |root|
      result = execute(root, 'joint/' + root.fetch('id').gsub(%r{[/:]}, '_'))
      # Every file of the package really was handed to a single checking phase.
      assert_equal root.fetch('input_files'), result.dig('evidence', 'joint_package_files'), root.fetch('id')
      assert_equal root.fetch('input_files').fetch(0), result.dig('evidence', 'checker_configuration_source')
      assert_equal root.fetch('runner_sha256'), result.dig('evidence', 'runner_sha256')
      assert_equal %w[interpreted compiled], result.fetch('modes').keys
      result.fetch('modes').each_value do |mode|
        assert mode.fetch('input_integrity'), root.fetch('id')
        assert_equal 'exited', mode.dig('stage', 'state')
        # Exactly one --go-file per file of the package, and no positional copy.
        assert_equal root.fetch('input_files').map { |f| "--go-file=#{f}" },
                     mode.dig('stage', 'argv').grep(/\A--go-file=/), root.fetch('id')
        # Each file's real recorded digest is retained as a checked input.
        assert_equal root.fetch('input_files').sort, mode.fetch('inputs').keys.sort
        root.fetch('input_files').each do |relative|
          assert_equal Corpus.digest(File.join(SOURCE_ROOT, relative)), mode.fetch('inputs').fetch(relative).fetch('sha256')
        end
      end
      [root.fetch('id'), result.fetch('verdict')]
    end
    # The real, observed partition of the 8 joint roots against candidate012.
    # Six satisfy both obligations jointly. The two importdecl0 twins do not,
    # and are recorded as FAIL rather than coerced into a PASS: see
    # JOINT_ROOT_GAP below for the exact gap they still owe.
    assert_equal 8, observed.length
    assert_equal JOINT_ROOT_GAP.keys.sort, observed.reject { |_, v| v == 'PASS' }.keys.sort, observed.to_s
    assert_equal 6, observed.count { |_, v| v == 'PASS' }
  end

  # The two joint roots the frozen candidate does not yet satisfy. Every expected
  # diagnostic is matched and no observed diagnostic is unaccounted for; what
  # fails is one line of product output that carries no source position at all,
  # emitted for a declaration that comes from a dot-imported package. It is a
  # real product gap, retained here so it cannot be lost or silently waived.
  JOINT_ROOT_GAP = {
    'go/types:TestCheck/importdecl0' => "-: \tother declaration of Value",
    'cmd/compile/internal/types2:TestCheck/importdecl0' => "-: \tother declaration of Value"
  }.freeze

  def test_the_two_unsatisfied_joint_roots_fail_for_a_named_gap_not_a_skip
    JOINT_ROOT_GAP.each do |id, unpositioned|
      root = self.class.joint_roots.find { |candidate| candidate.fetch('id') == id }
      refute_nil root, id
      result = execute(root, 'gap/' + id.gsub(%r{[/:]}, '_'))
      assert_equal 'FAIL', result.fetch('verdict'), id
      result.fetch('modes').each_value do |mode|
        match = mode.dig('match', 'response', 'match')
        # The gap is not a diagnostic mismatch: every annotation is reported and
        # every reported diagnostic consumes one.
        assert_equal match.fetch('expected_diagnostics'), match.fetch('matched_diagnostics'), id
        assert_empty match['unmatched_observed'] || [], id
        assert_empty match['unmatched_expected'] || [], id
        # It is one unpositioned continuation line the frontend still emits.
        assert_equal [unpositioned], mode.dig('match', 'response', 'unparsed_output'), id
        assert_match(/not positioned diagnostics for the fixture/, mode.fetch('reason'), id)
      end
    end
  end

  # The point of joint checking: a definition in one file resolves a reference in
  # another. Checked against the real candidate, not asserted from the argv.
  def test_a_cross_file_definition_resolves_only_when_the_package_is_checked_jointly
    Dir.mktmpdir('tc-cross-') do |dir|
      File.write(File.join(dir, 'a.go'), "package p\n\nfunc F() int { return G() }\n")
      File.write(File.join(dir, 'b.go'), "package p\n\nfunc G() int { return 1 }\n")
      joint = { 'axis' => 'typechecker', 'id' => 'control:cross-file', 'family' => 'TestCheck',
                'input_files' => %w[a.go b.go], 'build_constraints' => { 'a.go' => [], 'b.go' => [] },
                'column_tolerance' => 0, 'runner' => 'src/go/types/check_test.go',
                'runner_sha256' => Corpus.digest(File.join(SOURCE_ROOT, 'src/go/types/check_test.go')) }
      result = execute(joint, 'cross-joint', source_root: dir)
      assert_equal 'PASS', result.fetch('verdict'), result.fetch('modes').to_s[0, 600]
      result.fetch('modes').each_value { |mode| assert_equal 0, mode.dig('stage', 'exit') }

      # The same file alone must report the reference as undefined, which is what
      # a positional single-file selector would have silently produced instead.
      alone = joint.merge('id' => 'control:cross-file-alone', 'input_files' => %w[a.go],
                          'build_constraints' => { 'a.go' => [] })
      lone = execute(alone, 'cross-alone', source_root: dir)
      assert_equal 'FAIL', lone.fetch('verdict')
      assert_match(/undefined: G/, File.binread(lone.dig('modes', 'interpreted', 'stage', 'stderr', 'path')))
    end
  end

  # An annotation no diagnostic covers, and a diagnostic no annotation covers,
  # each FAIL - in the second file of the package as much as in the first.
  def test_a_missing_or_unmatched_diagnostic_in_either_file_fails
    { 'a.go' => 'first', 'b.go' => 'second' }.each do |carrier, label|
      Dir.mktmpdir('tc-diag-') do |dir|
        # A well-formed package: neither file has a real type error.
        File.write(File.join(dir, 'a.go'), "package p\n\nfunc F() int { return G() }\n")
        File.write(File.join(dir, 'b.go'), "package p\n\nfunc G() int { return 1 }\n")
        # ...but one file claims an error the checker will never report.
        body = File.read(File.join(dir, carrier))
        File.write(File.join(dir, carrier), body + "\nvar _ int /* ERROR \"never reported\" */\n")
        root = { 'axis' => 'typechecker', 'id' => "control:missing-#{label}", 'family' => 'TestCheck',
                 'input_files' => %w[a.go b.go], 'build_constraints' => { 'a.go' => [], 'b.go' => [] },
                 'column_tolerance' => 0, 'runner' => 'src/go/types/check_test.go',
                 'runner_sha256' => Corpus.digest(File.join(SOURCE_ROOT, 'src/go/types/check_test.go')) }
        result = execute(root, "missing-#{label}", source_root: dir)
        assert_equal 'FAIL', result.fetch('verdict'), "an unreported annotation in the #{label} file must FAIL"
        result.fetch('modes').each_value do |mode|
          assert_equal 'FAIL', mode.fetch('verdict')
          # The package really is accepted, so the exit status alone would have
          # read as a pass; the annotation the checker never reported is what
          # denies credit, and it is named.
          assert_equal 0, mode.dig('stage', 'exit')
          assert mode.dig('match', 'response', 'want_error')
          assert_match(/exit 0 disagrees with 1 required source annotation/, mode.fetch('reason'))
        end
      end
    end
  end

  # The other direction: a real diagnostic in the second file that no annotation
  # covers, and a duplicate annotation only one diagnostic can consume. Neither
  # may be absorbed by the joint check.
  def test_an_unmatched_diagnostic_or_a_duplicate_annotation_in_the_second_file_fails
    Dir.mktmpdir('tc-extra-') do |dir|
      File.write(File.join(dir, 'a.go'), "package p\n\nfunc F() int { return G() }\n")
      # A real type error in the second file, with no annotation at all.
      File.write(File.join(dir, 'b.go'), "package p\n\nfunc G() int { return 1 }\n\nvar _ int = \"s\"\n")
      root = { 'axis' => 'typechecker', 'id' => 'control:unmatched-second', 'family' => 'TestCheck',
               'input_files' => %w[a.go b.go], 'build_constraints' => { 'a.go' => [], 'b.go' => [] },
               'column_tolerance' => 0, 'runner' => 'src/go/types/check_test.go',
               'runner_sha256' => Corpus.digest(File.join(SOURCE_ROOT, 'src/go/types/check_test.go')) }
      result = execute(root, 'unmatched-second', source_root: dir)
      assert_equal 'FAIL', result.fetch('verdict')
      result.fetch('modes').each_value do |mode|
        refute_equal 0, mode.dig('stage', 'exit')
        # The diagnostic is positioned in the second file, which only a joint
        # check can report, and no annotation covers it.
        assert_match(/\Ab\.go:5:13: cannot use/, File.binread(mode.dig('stage', 'stderr', 'path')))
        refute mode.dig('match', 'response', 'want_error')
        assert_match(/exit 2 disagrees with 0 required source annotation/, mode.fetch('reason'))
      end

      # Now annotate that error twice on the same line: one annotation is
      # consumed, the duplicate stays unreported and still denies credit.
      File.write(File.join(dir, 'b.go'),
                 "package p\n\nfunc G() int { return 1 }\n\nvar _ int = \"s\" /* ERROR \"cannot use\" */ /* ERROR \"cannot use\" */\n")
      duplicate = root.merge('id' => 'control:duplicate-second')
      dup = execute(duplicate, 'duplicate-second', source_root: dir)
      assert_equal 'FAIL', dup.fetch('verdict'), 'a duplicate annotation must not be satisfied twice'
      dup.fetch('modes').each_value do |mode|
        match = mode.dig('match', 'response', 'match')
        assert_equal 2, match.fetch('expected_diagnostics')
        assert_equal 1, match.fetch('observed_diagnostics')
        refute_empty match['unmatched_expected'] || [], 'the duplicate annotation must be named as unreported'
      end
    end
  end

  # Tampering with any original input of the package - not just the first -
  # breaks the byte-identity obligation and cannot be adjudicated.
  def test_tampering_with_any_original_input_cannot_be_adjudicated
    %w[a.go b.go].each do |target|
      Dir.mktmpdir('tc-tamper-') do |dir|
        File.write(File.join(dir, 'a.go'), "package p\n\nfunc F() int { return G() }\n")
        File.write(File.join(dir, 'b.go'), "package p\n\nfunc G() int { return 1 }\n")
        root = { 'axis' => 'typechecker', 'id' => "control:tamper-#{target}", 'family' => 'TestCheck',
                 'input_files' => %w[a.go b.go], 'build_constraints' => { 'a.go' => [], 'b.go' => [] },
                 'column_tolerance' => 0, 'runner' => 'src/go/types/check_test.go',
                 'runner_sha256' => Corpus.digest(File.join(SOURCE_ROOT, 'src/go/types/check_test.go')) }
        result = execute(root, "tamper-#{target}", source_root: dir)
        mode = result.fetch('modes').fetch('interpreted')
        directory = File.dirname(mode.dig('stage', 'cwd'))
        # Rewrite the retained copy of this file and re-adjudicate the same request.
        File.binwrite(File.join(mode.dig('stage', 'cwd'), target), "package p\n")
        request = JSON.parse(File.read(mode.dig('match', 'request', 'path')))
        assert_equal %w[a.go b.go], request.fetch('sources').map { |src| src.fetch('short') }
        tampered = GoFullTypechecker.adjudicate(@matcher, request, File.join(directory, 'retry-' + target), 120)
        assert_equal 'FAIL', tampered.dig('response', 'verdict'), "tampering with #{target} must not adjudicate"
        assert_match(/checksum mismatch/, tampered.dig('response', 'reason'))
      end
    end
  end
end
