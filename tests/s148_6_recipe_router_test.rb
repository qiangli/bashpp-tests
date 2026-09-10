# frozen_string_literal: true
# Sprint: #148; Packet: 148.6; Story-ID: 2070d075d95e

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative '../tools/go-full/router'

# Packet 148.6 owns exactly one root: testdir:cmplxdivide.go, whose recipe line
# is `run cmplxdivide1.go`. The shared simple-execution seam passed
# cmplxdivide1.go as program argv and compiled only the root file, so the
# native run passed while the product failed. These tests pin the router
# contract on the exact inventory row; nothing here credits execution.
class Sprint148RecipeRouterTest < Minitest::Test
  ROOT_ID = 'testdir:cmplxdivide.go'
  INVENTORY = File.expand_path('../docs/go-full/testdir-roots.jsonl', __dir__)
  LEDGER = File.expand_path('../docs/go-full/sprint118-candidate018-capped-ledger.tsv', __dir__)
  ROOT_SHA256 = 'a0378f2eb4448bffa6925f45b05a69b0ea2bb24c6e290e2991da71f7b975ebe3'
  TABLE_SHA256 = '79e18b095b65e63857d8c522700a1430c8eab1c0c66a043f22b63ef9d6da36a9'
  SDK_EDGES = [
    { 'kind' => 'sdk-dependency', 'from' => "#{ROOT_ID}:package:0", 'source_import' => 'fmt' },
    { 'kind' => 'sdk-dependency', 'from' => "#{ROOT_ID}:package:0", 'source_import' => 'math' }
  ].freeze

  def setup
    rows = File.foreach(INVENTORY).map { |line| JSON.parse(line) }
    matches = rows.select { |row| row['id'] == ROOT_ID }
    assert_equal 1, matches.length, 'exact root must appear once in the official inventory'
    @root = matches.first.merge('axis' => 'testdir')
    @skip_root = rows.find { |row| row['id'] == 'testdir:cmplxdivide1.go' }.merge('axis' => 'testdir')
    @phases = GoFullRecipeRouter.phase_contract('run')
    @native = { 'status' => recorded_native_status, 'evidence_kind' => 'native-go-only' }
  end

  # The recorded Linux/darwin native run for this root passed; the packet
  # brief's "Linux root executes" is read from that retained ledger row, not
  # asserted from memory.
  def recorded_native_status
    header, *rows = File.foreach(LEDGER).map { |line| line.chomp.split("\t", -1) }
    row = rows.find { |fields| fields.first == ROOT_ID }
    refute_nil row, 'exact root must be present in the retained ledger'
    row.fetch(header.index('native_status'))
  end

  def route(root: @root, mode: 'compiled', phases: @phases, graph: SDK_EDGES, native: @native, **options)
    GoFullRecipeRouter.route!(root: root, mode: mode, phases: phases, graph: graph,
                              native_observation: native, **options)
  end

  def mutate(root = @root)
    copy = Marshal.load(Marshal.dump(root))
    yield copy
    copy
  end

  def expected_facts(mode = 'compiled')
    { 'axis' => 'testdir', 'action' => 'run', 'effective_action' => 'run', 'flags' => 'none',
      'files' => 'root+go-file-inputs', 'graph' => 'sdk-only', 'env' => 'none',
      'output' => 'sidecar-absent', 'mode' => mode,
      'phases' => 'compile-or-build > link-if-needed > run > match-output' }
  end

  def test_exact_root_localizes_to_the_inventory_row_and_recorded_native_pass
    assert_equal 'run cmplxdivide1.go', @root.dig('recipe', 'line')
    assert_equal ['cmplxdivide1.go'], @root.dig('recipe', 'args')
    assert_equal ['test/cmplxdivide.go'], @root['input_files']
    assert_equal 'pass', @native['status']
    assert_equal %w[compile-or-build link-if-needed run match-output], @phases
  end

  def test_exactly_one_route_with_go_file_as_compile_input_not_argv
    GoFullRecipeRouter::MODES.each do |mode|
      resolution = route(mode: mode)
      assert_equal GoFullRecipeRouter::SCHEMA, resolution['schema']
      assert_equal ROOT_ID, resolution['root_id']
      assert_equal GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE, resolution['route']
      assert_equal [GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE], resolution['candidate_routes']
      assert_equal expected_facts(mode), resolution['facts']
      plan = resolution.fetch('plan')
      assert_equal ['test/cmplxdivide.go', 'test/cmplxdivide1.go'], plan['compile_inputs']
      assert_equal [], plan['argv']
      assert_equal 'run', plan['executor_phase']
      assert_equal true, plan['package_input_required']
      assert_equal 'execute', resolution.dig('applicability', 'decision')
      assert_equal 'native-terminal-requires-execution', resolution.dig('applicability', 'rule')
      assert_equal false, resolution['execution_credited']
      assert_equal false, resolution['corpus_credit']
      assert_equal GoFullRecipeRouter::CLAIM_SCOPE, resolution['claim_scope']
      digest = resolution.delete('route_sha256')
      assert_equal Digest::SHA256.hexdigest(Corpus.canonical(resolution)), digest
    end
  end

  def test_resolution_is_deterministic_and_independent_of_registration_order
    first = route
    second = route
    assert_equal first, second
    assert_equal first['route_sha256'], second['route_sha256']

    forward = GoFullRecipeRouter::Table.new
    backward = GoFullRecipeRouter::Table.new
    real = GoFullRecipeRouter.default_table
    decoy = { 'axis' => 'testdir', 'action' => 'run', 'effective_action' => 'run', 'flags' => 'none',
              'files' => 'root-only', 'graph' => GoFullRecipeRouter::ANY, 'env' => 'none',
              'output' => GoFullRecipeRouter::ANY, 'mode' => GoFullRecipeRouter::ANY,
              'phases' => GoFullRecipeRouter::ANY }
    real_route = real.resolve(GoFullRecipeRouter.facts(root: @root, mode: 'compiled', phases: @phases, graph: SDK_EDGES))
    planner = GoFullRecipeRouter.method(:run_go_file_inputs_plan)
    forward.register(name: real_route.name, predicates: real_route.predicates, planner: planner)
    forward.register(name: 'zzz-decoy', predicates: decoy, planner: ->(_root, _facts) { raise 'decoy must never plan' })
    backward.register(name: 'zzz-decoy', predicates: decoy, planner: ->(_root, _facts) { raise 'decoy must never plan' })
    backward.register(name: real_route.name, predicates: real_route.predicates, planner: planner)
    assert_equal route(table: forward), route(table: backward)
    assert_equal GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE, route(table: forward)['route']
    assert_equal [GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE], route(table: forward)['candidate_routes']
  end

  def test_zero_matching_routes_reject_including_the_unselected_sibling_root
    error = assert_raises(Corpus::ContractError) do
      route(root: @skip_root, phases: GoFullRecipeRouter.phase_contract('skip'),
            native: { 'status' => 'skip', 'evidence_kind' => 'native-go-only' })
    end
    assert_match(/no route/, error.message)
    error = assert_raises(Corpus::ContractError) { route(table: GoFullRecipeRouter::Table.new) }
    assert_match(/no route/, error.message)
  end

  def test_multiple_matching_routes_reject_instead_of_choosing
    table = GoFullRecipeRouter.default_table
    table.register(name: 'aaa-wildcard', predicates: GoFullRecipeRouter::AXES.to_h { |axis| [axis, GoFullRecipeRouter::ANY] },
                   planner: ->(_root, _facts) { raise 'wildcard must never plan' })
    error = assert_raises(Corpus::ContractError) { route(table: table) }
    assert_match(/ambiguous route: aaa-wildcard, #{GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE}/, error.message)
  end

  def test_every_routing_axis_can_reject_the_root_on_its_own
    mutations = {
      'axis' => [mutate { |root| root['axis'] = 'typechecker' }, {}],
      'action' => [mutate { |root| root['recipe']['action'] = 'build' }, {}],
      'effective_action' => [mutate { |root| root['recipe']['effective_action'] = 'compile' }, {}],
      'flags' => [mutate { |root| root['recipe']['flags'] = ['-race']; root['recipe']['effective_flags'] = ['-race'] }, {}],
      'files' => [mutate { |root| root['recipe']['args'] = ['cmplxdivide1.go', 'argv'] }, {}],
      'graph' => [@root, { graph: SDK_EDGES + [{ 'kind' => 'tested-source-package', 'source_import' => './a' }] }],
      'env' => [mutate { |root| root['recipe']['environment_append'] = ['GODEBUG=x=1'] }, {}],
      'output' => [mutate { |root| root.delete('expected_output') }, {}],
      'mode' => [@root, { mode: 'native' }],
      'phases' => [@root, { phases: GoFullRecipeRouter.phase_contract('buildrun') }]
    }
    assert_equal GoFullRecipeRouter::AXES.sort, mutations.keys.sort
    mutations.each do |axis, (root, options)|
      facts = GoFullRecipeRouter.facts(root: root, mode: options.fetch(:mode, 'compiled'),
                                       phases: options.fetch(:phases, @phases), graph: options.fetch(:graph, SDK_EDGES))
      changed = expected_facts.keys.select { |key| facts[key] != expected_facts[key] }
      assert_equal [axis], changed, "mutation must change exactly the #{axis} fact"
      error = assert_raises(Corpus::ContractError, axis) { route(root: root, **options) }
      assert_match(/no route/, error.message, axis)
    end
  end

  def test_argument_shapes_that_are_not_compile_inputs_do_not_route_here
    root_only = mutate { |root| root['recipe']['args'] = [] }
    assert_equal 'root-only', GoFullRecipeRouter.facts(root: root_only, mode: 'compiled', phases: @phases, graph: SDK_EDGES)['files']
    assert_raises(Corpus::ContractError) { route(root: root_only) }
    interleaved = mutate { |root| root['recipe']['args'] = ['argv', 'cmplxdivide1.go'] }
    assert_equal 'interleaved-go-args', GoFullRecipeRouter.facts(root: interleaved, mode: 'compiled', phases: @phases, graph: SDK_EDGES)['files']
    assert_raises(Corpus::ContractError) { route(root: interleaved) }
    ['../cmplxdivide1.go', 'sub/cmplxdivide1.go', '/tmp/x.go', '.go'].each do |escape|
      assert_raises(Corpus::ContractError, escape) { route(root: mutate { |root| root['recipe']['args'] = [escape] }) }
    end
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root['recipe']['args'] = %w[cmplxdivide1.go cmplxdivide1.go] }) }
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root['recipe']['args'] = ['cmplxdivide.go'] }) }
  end

  def test_matching_foreign_root_and_fact_preserving_anchor_mutation_reject
    foreign = mutate { |root| root['id'] = 'testdir:foreign.go'; root['path'] = 'test/foreign.go'; root['input_files'] = ['test/foreign.go'] }
    assert_equal expected_facts, GoFullRecipeRouter.facts(root: foreign, mode: 'compiled', phases: @phases, graph: SDK_EDGES)
    assert_raises(Corpus::ContractError) { route(root: foreign) }
    assert_raises(Corpus::ContractError) do
      route(root: mutate { |root| root['upstream_subtest'] = 'Test/forged.go' })
    end
  end

  def test_applicability_is_delegated_to_the_stage_resolver
    assert_equal 'execute', route(native: { 'status' => 'fail', 'evidence_kind' => 'native-go-only' }).dig('applicability', 'decision')
    skipped = route(native: { 'status' => 'skip', 'evidence_kind' => 'native-go-only' })
    assert_equal 'upstream-skip', skipped.dig('applicability', 'decision')
    assert_equal 'retained-native-skip', skipped.dig('applicability', 'rule')
    assert_raises(Corpus::ContractError) { route(native: { 'status' => 'missing', 'evidence_kind' => 'native-go-only' }) }
    assert_raises(Corpus::ContractError) { route(native: { 'status' => 'pass', 'evidence_kind' => 'product' }) }
    assert_raises(Corpus::ContractError) { route(native: { 'status' => 'maybe', 'evidence_kind' => 'native-go-only' }) }
    assert_raises(Corpus::ContractError) { route(native: nil) }
  end

  def test_malformed_facts_reject_before_routing
    assert_raises(Corpus::ContractError) { route(graph: [{ 'kind' => 'guess' }]) }
    assert_raises(Corpus::ContractError) { route(graph: nil) }
    assert_raises(Corpus::ContractError) { route(mode: '') }
    assert_raises(Corpus::ContractError) { route(phases: []) }
    assert_raises(Corpus::ContractError) { route(phases: %w[run run]) }
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root['expected_output']['present'] = 'no' }) }
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root['expected_output']['sha256'] = '0' * 64 }) }
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root['expected_output']['extra'] = true }) }
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root['recipe'].delete('effective_flags') }) }
    assert_raises(Corpus::ContractError) { route(root: mutate { |root| root.delete('axis') }) }
    assert_raises(Corpus::ContractError) do
      route(root: mutate { |root| root['directory'] = {}; root['generated_program'] = {} })
    end
    assert_raises(Corpus::ContractError) { GoFullRecipeRouter.phase_contract('not-an-action') }
  end

  def test_route_table_demands_every_axis_unique_names_and_valid_predicates
    table = GoFullRecipeRouter.default_table
    planner = ->(_root, _facts) { {} }
    full = GoFullRecipeRouter::AXES.to_h { |axis| [axis, GoFullRecipeRouter::ANY] }
    assert_raises(Corpus::ContractError) { table.register(name: 'partial', predicates: full.reject { |axis, _| axis == 'graph' }, planner: planner) }
    assert_raises(Corpus::ContractError) { table.register(name: 'extra', predicates: full.merge('priority' => '1'), planner: planner) }
    assert_raises(Corpus::ContractError) { table.register(name: 'empty-set', predicates: full.merge('mode' => []), planner: planner) }
    assert_raises(Corpus::ContractError) { table.register(name: 'repeated-set', predicates: full.merge('mode' => %w[compiled compiled]), planner: planner) }
    assert_raises(Corpus::ContractError) { table.register(name: '', predicates: full, planner: planner) }
    assert_raises(Corpus::ContractError) { table.register(name: 'no-planner', predicates: full, planner: nil) }
    assert_raises(Corpus::ContractError) do
      table.register(name: GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE, predicates: full, planner: planner)
    end
    assert_equal [GoFullRecipeRouter::RUN_GO_FILE_INPUTS_ROUTE], table.names
  end

  def test_localized_plan_binds_both_compile_inputs_under_the_source_root
    Dir.mktmpdir('s148-6-source-') do |tmp|
      tmp = File.realpath(tmp)
      FileUtils.mkdir_p(File.join(tmp, 'test'))
      File.write(File.join(tmp, 'test/cmplxdivide.go'), "package main\n")
      File.write(File.join(tmp, 'test/cmplxdivide1.go'), "package main\n\nvar tests = []int{}\n")
      resolution = route(source_root: tmp)
      inputs = resolution.dig('plan', 'inputs')
      assert_equal ['test/cmplxdivide.go', 'test/cmplxdivide1.go'], inputs.keys
      inputs.each { |relative, record| assert_equal Corpus.file_record(File.join(tmp, relative)), record }
      assert_raises(Corpus::ContractError) do
        route(source_root: tmp, root: mutate { |root| root['input_files'] = ['test/cmplxdivide.go', 'test/other.go'] })
      end
      File.delete(File.join(tmp, 'test/cmplxdivide1.go'))
      assert_raises(Corpus::ContractError) { route(source_root: tmp) }
    end
  end

  # Bounded native control: when the local SDK carries the exact inventory
  # bytes, the selected plan runs and the misrouted plan does not. This is
  # native-only evidence of the routing rule; it credits no product execution.
  def test_native_control_selected_plan_runs_and_misrouted_plan_fails
    go = ENV['GO_FULL_CONTROL_GO'] || `which go 2>/dev/null`.strip
    skip 'native go is not available for the routing control' if go.empty? || !File.executable?(go)
    goroot, _err, status = Open3.capture3({ 'GOTOOLCHAIN' => 'local' }, go, 'env', 'GOROOT')
    skip 'GOROOT is unavailable for the routing control' unless status.success?
    sources = { 'test/cmplxdivide.go' => ROOT_SHA256, 'test/cmplxdivide1.go' => TABLE_SHA256 }
    sources.each do |relative, sha256|
      path = File.join(goroot.strip, relative)
      skip "local SDK does not carry inventory bytes for #{relative}" unless File.file?(path) && Corpus.digest(path) == sha256
    end
    Dir.mktmpdir('s148-6-native-control-') do |tmp|
      FileUtils.mkdir_p(File.join(tmp, 'test'))
      sources.each_key { |relative| FileUtils.cp(File.join(goroot.strip, relative), File.join(tmp, relative)) }
      resolution = route(source_root: tmp)
      plan = resolution.fetch('plan')
      env = { 'GOTOOLCHAIN' => 'local', 'GOFLAGS' => '', 'GOPROXY' => 'off', 'GOSUMDB' => 'off',
              'GOCACHE' => ENV['GOCACHE'] || File.join(tmp, 'gocache'), 'HOME' => tmp, 'GO111MODULE' => 'off' }
      out, err, status = Open3.capture3(env, go, 'run', *plan['compile_inputs'], *plan['argv'], chdir: tmp)
      assert status.success?, "selected plan must execute natively: #{err}"
      assert_equal '', out + err, 'sidecar is absent, so upstream expects empty combined output'
      # The shared seam's misrouting: only the root file is a compile input and
      # cmplxdivide1.go would become program argv. That program never compiles.
      _out, err, status = Open3.capture3(env, go, 'run', 'test/cmplxdivide.go', chdir: tmp)
      refute status.success?, 'the argv misrouting must not compile'
      assert_match(/undefined: tests/, err)
      assert_equal false, resolution['corpus_credit']
      assert_equal false, resolution['execution_credited']
    end
  end
end
