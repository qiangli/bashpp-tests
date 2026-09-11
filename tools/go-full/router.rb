# frozen_string_literal: true
# Sprint: #148; Packet: 148.6; Story-ID: 2070d075d95e

require 'digest'
require 'json'
require ENV.fetch('GO_FULL_CORPUS_LIB', File.expand_path('../corpus/executor.rb', __dir__))
require_relative '../corpus/validate'
require_relative 'native'
require_relative 'stage_resolver'

# Deterministic multi-predicate recipe router.
#
# A root is localized into one fact per routing axis and then matched against
# a table of declarative routes. Every route must state a predicate for every
# axis; nothing is inferred from registration order and nothing is resolved by
# priority. Zero matching routes reject and more than one matching route
# rejects, so a route can never be acquired by being listed first.
#
# The router selects a plan; it never executes it and never credits anything.
# Applicability is delegated to the packet 148.5 resolver so a native terminal
# still forces execution and only a retained native skip can skip.
module GoFullRecipeRouter
  SCHEMA = 'go-full-recipe-route/v1'
  CLAIM_SCOPE = 'route selection for the exact root only; no execution or corpus credit'
  AXES = %w[axis action effective_action flags files graph env output mode phases].freeze
  ANY = '*'
  MODES = Corpus::MODES
  EDGE_KINDS = %w[sdk-dependency tested-source-package foreign-code-bridge].freeze
  GRAPH_FACTS = %w[no-edges sdk-only tested-package-edges foreign-bridge].freeze
  OUTPUT_FACTS = %w[not-consumed sidecar-absent sidecar-present].freeze
  EXPECTED_OUTPUT_KEYS = %w[bytes path present sha256].freeze
  FILE_SHAPES = %w[root-only root+go-file-inputs root+program-args root+go-file-inputs+program-args
                   interleaved-go-args directory program-directory-inputs generated-program nested-process].freeze
  GO_SOURCE = /\.go\z/.freeze
  BARE_GO_FILE = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\.go\z/.freeze
  PHASE_SEPARATOR = ' > '
  ACTION_CATALOG = File.expand_path('../../docs/go-full/action-catalog.json', __dir__)
  RUN_PHASES = %w[compile-or-build link-if-needed run match-output].freeze
  PACKET_ROOT_ID = 'testdir:cmplxdivide.go'
  PACKET_ROOT_SHA256 = '3c9e41483acc225411e06f0726d0f177a7af1d6f9d332dfd4d03372ec81a540b'
  ROUTER_NATIVE_OBSERVATION_KEYS = %w[event evidence_kind status].freeze
  # Upstream `run` with arguments delegates to `go run <gcflags> <flags> root.go
  # <args...>`. `go run` takes the leading `.go` arguments as package files of
  # the tested program; only what follows the first non-`.go` argument reaches
  # the program's argv (src/cmd/internal/testdir/testdir_test.go, case "run").
  RUN_GO_FILE_INPUTS_ROUTE = 'testdir-run-go-file-compile-inputs'

  class Route
    attr_reader :name, :predicates

    def initialize(name:, predicates:, planner:)
      raise Corpus::ContractError, 'route name must be a nonempty String' unless name.is_a?(String) && !name.empty?
      raise Corpus::ContractError, "route #{name} must state every routing axis exactly once" unless
        predicates.is_a?(Hash) && predicates.keys.sort == AXES.sort
      predicates.each do |axis, predicate|
        unless predicate == ANY || nonempty_string?(predicate) ||
               (predicate.is_a?(Array) && !predicate.empty? && predicate.all? { |value| nonempty_string?(value) } &&
                predicate.uniq == predicate)
          raise Corpus::ContractError, "route #{name} has an invalid #{axis} predicate"
        end
      end
      raise Corpus::ContractError, "route #{name} planner must respond to call" unless planner.respond_to?(:call)
      @name = name.dup.freeze
      @predicates = deep_freeze(Corpus.sort(predicates))
      @planner = planner
    end

    def match?(facts)
      AXES.all? { |axis| predicate_match?(@predicates.fetch(axis), facts.fetch(axis)) }
    end

    def plan(root, facts)
      @planner.call(root, facts)
    end

    private

    def nonempty_string?(value)
      value.is_a?(String) && !value.empty?
    end

    def predicate_match?(predicate, fact)
      case predicate
      when ANY then true
      when String then predicate == fact
      when Array then predicate.include?(fact)
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |item| deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end

  class Table
    def initialize
      @routes = {}
    end

    def register(name:, predicates:, planner:)
      route = Route.new(name: name, predicates: predicates, planner: planner)
      raise Corpus::ContractError, "duplicate route registration: #{name}" if @routes.key?(route.name)
      @routes[route.name] = route
      route
    end

    def names
      @routes.keys.sort.freeze
    end

    # Every route is evaluated; there is no first-match shortcut and the
    # answer is independent of registration order.
    def resolve(facts)
      resolve_with_candidates(facts).first
    end

    def resolve_with_candidates(facts)
      matches = @routes.values.select { |route| route.match?(facts) }.sort_by(&:name)
      raise Corpus::ContractError, "no route matches facts #{Corpus.canonical(facts)}" if matches.empty?
      if matches.length > 1
        raise Corpus::ContractError,
              "ambiguous route: #{matches.map(&:name).join(', ')} all match facts #{Corpus.canonical(facts)}"
      end
      [matches.first, matches.map(&:name).freeze]
    end
  end

  module_function

  def facts(root:, mode:, phases:, graph:)
    raise Corpus::ContractError, 'root must be an object' unless root.is_a?(Hash)
    recipe = root.fetch('recipe')
    raise Corpus::ContractError, 'root recipe must be an object' unless recipe.is_a?(Hash)
    facts = {
      'axis' => nonempty!(root.fetch('axis'), 'axis'),
      'action' => nonempty!(recipe.fetch('action'), 'action'),
      'effective_action' => nonempty!(recipe.fetch('effective_action'), 'effective action'),
      'flags' => flags_fact(recipe),
      'files' => files_fact(root, recipe),
      'graph' => graph_fact(graph),
      'env' => env_fact(recipe),
      'output' => output_fact(root),
      'mode' => nonempty!(mode, 'mode'),
      'phases' => phases_fact(phases)
    }
    Corpus.sort(facts).freeze
  rescue KeyError, TypeError => error
    raise Corpus::ContractError, "incomplete routing inputs: #{error.message}"
  end

  def nonempty!(value, label)
    raise Corpus::ContractError, "#{label} must be a nonempty String" unless value.is_a?(String) && !value.empty?
    value
  end

  def string_list!(value, label)
    raise Corpus::ContractError, "#{label} must be a list of Strings" unless
      value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
    value
  end

  def flags_fact(recipe)
    flags = string_list!(recipe.fetch('flags'), 'recipe flags')
    effective = string_list!(recipe.fetch('effective_flags'), 'recipe effective flags')
    return 'none' if flags.empty? && effective.empty?
    Corpus.canonical('flags' => flags, 'effective_flags' => effective)
  end

  def env_fact(recipe)
    append = string_list!(recipe.fetch('environment_append'), 'recipe environment append')
    append.empty? ? 'none' : Corpus.canonical(append)
  end

  # Split `run` style arguments exactly as `go run` does: the leading `.go`
  # arguments are compile inputs, everything after the first non-`.go`
  # argument is program argv. A `.go` name appearing after argv began is an
  # interleaving this router refuses to guess about.
  def split_arguments(args)
    args = string_list!(args, 'recipe args')
    compile = args.take_while { |arg| arg.match?(GO_SOURCE) }
    program = args.drop(compile.length)
    compile.each do |arg|
      raise Corpus::ContractError, "go source argument is not a bare file name: #{arg.inspect}" unless arg.match?(BARE_GO_FILE)
    end
    raise Corpus::ContractError, 'duplicate go source arguments' unless compile.uniq == compile
    { 'compile' => compile, 'program' => program, 'interleaved' => program.any? { |arg| arg.match?(GO_SOURCE) } }
  end

  def files_fact(root, recipe)
    special = {
      'directory' => 'directory', 'program_directory_inputs' => 'program-directory-inputs',
      'generated_program' => 'generated-program', 'nested_process_obligation' => 'nested-process'
    }.select { |key, _value| root.key?(key) }
    raise Corpus::ContractError, 'root declares contradictory file shapes' if special.length > 1
    return special.values.first unless special.empty?
    path = nonempty!(root.fetch('path'), 'root path')
    Corpus.safe_path('/unused', path)
    split = split_arguments(recipe.fetch('args'))
    return 'interleaved-go-args' if split.fetch('interleaved')
    if split.fetch('compile').include?(File.basename(path))
      raise Corpus::ContractError, 'go source argument repeats the root file'
    end
    case [split.fetch('compile').empty?, split.fetch('program').empty?]
    when [true, true] then 'root-only'
    when [false, true] then 'root+go-file-inputs'
    when [true, false] then 'root+program-args'
    else 'root+go-file-inputs+program-args'
    end
  end

  def graph_fact(graph)
    raise Corpus::ContractError, 'graph must be a list of import edges' unless graph.is_a?(Array)
    kinds = graph.map do |edge|
      raise Corpus::ContractError, 'import edge must be an object' unless edge.is_a?(Hash)
      kind = edge.fetch('kind')
      raise Corpus::ContractError, "unknown import edge kind #{kind.inspect}" unless EDGE_KINDS.include?(kind)
      kind
    end
    return 'no-edges' if kinds.empty?
    return 'foreign-bridge' if kinds.include?('foreign-code-bridge')
    return 'tested-package-edges' if kinds.include?('tested-source-package')
    'sdk-only'
  end

  def output_fact(root)
    return 'not-consumed' unless root.key?('expected_output')
    expected = root.fetch('expected_output')
    unless expected.is_a?(Hash) && expected.keys.sort == EXPECTED_OUTPUT_KEYS
      raise Corpus::ContractError, 'expected output record has extra or missing fields'
    end
    case expected.fetch('present')
    when true
      unless expected['sha256'].is_a?(String) && expected['sha256'].match?(/\A[0-9a-f]{64}\z/) && expected['bytes'].is_a?(Integer)
        raise Corpus::ContractError, 'present expected output lacks a digest'
      end
      'sidecar-present'
    when false
      raise Corpus::ContractError, 'absent expected output carries a digest' unless expected['sha256'].nil? && expected['bytes'] == 0
      'sidecar-absent'
    else
      raise Corpus::ContractError, 'expected output presence is not boolean'
    end
  end

  def phases_fact(phases)
    raise Corpus::ContractError, 'phases must be a nonempty list of Strings' unless
      phases.is_a?(Array) && !phases.empty? && phases.all? { |phase| phase.is_a?(String) && !phase.empty? }
    raise Corpus::ContractError, 'phases repeat' unless phases.uniq == phases
    raise Corpus::ContractError, 'phase names may not contain the separator' if phases.any? { |phase| phase.include?(PHASE_SEPARATOR) }
    phases.join(PHASE_SEPARATOR)
  end

  # The phase contract for an action is read from the reviewed action
  # catalog, never guessed from the action name.
  def phase_contract(action, catalog_path: ACTION_CATALOG)
    catalog = JSON.parse(File.binread(catalog_path))
    rows = catalog.select { |row| row.is_a?(Hash) && row['action'] == action }
    raise Corpus::ContractError, "action catalog lists #{action.inspect} #{rows.length} times" unless rows.length == 1
    phases = rows.first.fetch('phase_contract')
    phases_fact(phases)
    phases
  rescue Errno::ENOENT, JSON::ParserError, KeyError => error
    raise Corpus::ContractError, "invalid action catalog: #{error.message}"
  end

  def applicability(native_observation)
    native_observation = resolver_native_observation(native_observation)
    decision = case native_observation.fetch('status')
               when 'pass', 'fail' then 'execute'
               when 'skip', 'ancestor-skip' then 'upstream-skip'
               else 'execute'
               end
    resolved = GoFullStageResolver.applicability!(native_observation: native_observation, decision: decision)
    resolved.merge('decision' => decision)
  end

  def resolver_native_observation(native_observation)
    raise Corpus::ContractError, 'native observation must be an object' unless native_observation.is_a?(Hash)
    keys = native_observation.keys.sort
    unless keys == GoFullStageResolver::NATIVE_OBSERVATION_KEYS || keys == ROUTER_NATIVE_OBSERVATION_KEYS
      raise Corpus::ContractError, 'router native observation has extra or missing fields'
    end
    validate_native_event!(native_observation) if native_observation.key?('event')
    GoFullStageResolver::NATIVE_OBSERVATION_KEYS.to_h { |key| [key, native_observation.fetch(key)] }
  end

  def validate_native_event!(native_observation)
    event = native_observation.fetch('event')
    raise Corpus::ContractError, 'native observation event must be an object' unless event.is_a?(Hash)
    action = event.fetch('Action')
    package = event.fetch('Package')
    raise Corpus::ContractError, 'native observation event package must be a String' unless package.is_a?(String) && !package.empty?
    raise Corpus::ContractError, 'native observation event action must be terminal' unless GoFull::NativeEvents::TERMINAL.include?(action)
    expected_action = native_observation.fetch('status') == 'ancestor-skip' ? 'skip' : native_observation.fetch('status')
    unless action == expected_action
      raise Corpus::ContractError, 'native observation event action contradicts status'
    end
    test = event['Test']
    raise Corpus::ContractError, 'native observation event test must be a String when present' unless test.nil? || test.is_a?(String)
  rescue KeyError => error
    raise Corpus::ContractError, "incomplete native observation event: #{error.message}"
  end

  def run_go_file_inputs_plan(root, facts)
    raise Corpus::ContractError, 'planner received a foreign file shape' unless facts.fetch('files') == 'root+go-file-inputs'
    path = root.fetch('path')
    split = split_arguments(root.fetch('recipe').fetch('args'))
    compile_inputs = [path, *split.fetch('compile').map { |name| File.join(File.dirname(path), name) }]
    raise Corpus::ContractError, 'compile inputs collide' unless compile_inputs.uniq == compile_inputs
    { 'executor_phase' => 'run', 'compile_inputs' => compile_inputs, 'argv' => split.fetch('program'),
      'package_input_required' => compile_inputs.length > 1,
      'upstream_argument_rule' => 'leading .go arguments are `go run` package files, not program argv' }
  end

  def authenticate_packet_root!(root)
    unless root.fetch('id') == PACKET_ROOT_ID &&
           Digest::SHA256.hexdigest(Corpus.canonical(root)) == PACKET_ROOT_SHA256
      raise Corpus::ContractError, 'route input differs from the exact packet 148.6 root record'
    end
    root
  end

  def default_table
    table = Table.new
    table.register(name: RUN_GO_FILE_INPUTS_ROUTE, predicates: {
      'axis' => 'testdir', 'action' => 'run', 'effective_action' => 'run', 'flags' => 'none',
      'files' => 'root+go-file-inputs', 'graph' => %w[no-edges sdk-only], 'env' => 'none',
      'output' => %w[sidecar-absent sidecar-present], 'mode' => MODES.dup,
      'phases' => RUN_PHASES.join(PHASE_SEPARATOR)
    }, planner: method(:run_go_file_inputs_plan))
    table
  end

  def localize_plan!(plan, root, source_root)
    inputs = plan.fetch('compile_inputs').to_h do |relative|
      [relative, Corpus.file_record(Corpus.safe_path(File.realpath(source_root), relative))]
    end
    declared = root['input_files']
    if declared.is_a?(Array) && !(declared - plan.fetch('compile_inputs')).empty?
      raise Corpus::ContractError, 'declared input files are not all compile inputs of the selected route'
    end
    plan.merge('inputs' => inputs)
  rescue SystemCallError => error
    raise Corpus::ContractError, "compile input is not available under the source root: #{error.message}"
  end

  # Select exactly one route for one root. The returned resolution is
  # canonical and self-digested; it carries no verdict and no credit.
  def route!(root:, mode:, phases:, graph:, native_observation:, table: default_table, source_root: nil)
    facts = facts(root: root, mode: mode, phases: phases, graph: graph)
    route, candidate_routes = table.resolve_with_candidates(facts)
    authenticate_packet_root!(root)
    applicability = applicability(native_observation)
    plan = route.plan(root, facts)
    raise Corpus::ContractError, 'route planner returned no plan' unless plan.is_a?(Hash) && plan.key?('compile_inputs')
    plan = localize_plan!(plan, root, source_root) if source_root
    resolution = {
      'schema' => SCHEMA, 'claim_scope' => CLAIM_SCOPE, 'root_id' => nonempty!(root.fetch('id'), 'root id'),
      'route' => route.name, 'predicates' => route.predicates, 'facts' => facts,
      'candidate_routes' => candidate_routes, 'applicability' => applicability, 'plan' => Corpus.sort(plan),
      'execution_credited' => false, 'corpus_credit' => false
    }
    resolution.merge('route_sha256' => Digest::SHA256.hexdigest(Corpus.canonical(resolution)))
  rescue KeyError, TypeError => error
    raise Corpus::ContractError, "incomplete routing inputs: #{error.message}"
  end
end
