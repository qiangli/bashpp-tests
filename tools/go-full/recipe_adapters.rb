# frozen_string_literal: true
# Sprint: #142; Story: #25; Story-ID: f3d6a18d5039

require_relative '../corpus/validate'

# Extension point for exact product recipe adapters. Adapter files named
# recipe_*.rb are loaded in lexical order and register one lane/action pair.
module GoFullRecipeAdapters
  class Registry
    TERMINAL_STATES = %w[exited deadline process_leak launch_failure].freeze
    PROTECTED_ROW_KEYS = %w[schema id axis native_observation retained_inputs retained_record
                            context_sha256 root_sha256 provenance attempt_state].freeze

    def initialize
      @entries = {}
    end

    def register(lane:, action:, name:, adapter:)
      key = registration_key(lane, action)
      raise Corpus::ContractError, "duplicate recipe adapter registration: #{key.join('/')}" if @entries.key?(key)
      raise Corpus::ContractError, 'recipe adapter name must be a nonempty String' unless name.is_a?(String) && !name.empty?
      unless adapter.respond_to?(:eligible?) && adapter.respond_to?(:execute)
        raise Corpus::ContractError, 'recipe adapter must implement eligible?(root) and execute(root:, context:)'
      end

      @entries[key] = { 'lane' => key[0], 'action' => key[1], 'name' => name.dup.freeze, adapter: adapter }
      adapter
    end

    def registrations
      @entries.values.sort_by { |entry| entry.values_at('lane', 'action', 'name') }
              .map { |entry| entry.slice('lane', 'action', 'name').freeze }.freeze
    end

    def registered?(lane:, action:)
      valid_coordinate?(lane, action) && @entries.key?([lane, action])
    end

    def eligible?(root)
      lane = root.fetch('axis')
      action = root.fetch('recipe').fetch('action')
      return false unless valid_coordinate?(lane, action)
      entry = @entries[[lane, action]]
      entry ? entry.fetch(:adapter).eligible?(root) == true : false
    end

    def dispatch(root:, context:)
      key = registration_key(root.fetch('axis'), root.fetch('recipe').fetch('action'))
      entry = @entries[key]
      raise Corpus::ContractError, "unregistered recipe adapter: #{key.join('/')}" unless entry
      raise Corpus::ContractError, "recipe adapter rejected root: #{root.fetch('id')}" unless entry.fetch(:adapter).eligible?(root) == true

      result = entry.fetch(:adapter).execute(root: root, context: context)
      validate_result!(result, root, context)
      row = result.fetch('row', {})
      collisions = row.keys & PROTECTED_ROW_KEYS
      raise Corpus::ContractError, "recipe adapter tried to replace protected row fields: #{collisions.sort.join(', ')}" unless collisions.empty?

      row.merge('product_verdict' => result.fetch('product_verdict'),
                'adapter_evidence' => { 'adapter' => entry.slice('lane', 'action', 'name'),
                                        'attempts' => result.fetch('attempt_evidence') })
    rescue KeyError, TypeError, NoMethodError => error
      raise Corpus::ContractError, "malformed recipe adapter result: #{error.message}"
    end

    private

    def registration_key(lane, action)
      unless valid_coordinate?(lane, action)
        raise Corpus::ContractError, 'recipe adapter lane/action must be nonempty Strings'
      end
      [lane.dup.freeze, action.dup.freeze].freeze
    end

    def valid_coordinate?(lane, action)
      lane.is_a?(String) && !lane.empty? && action.is_a?(String) && !action.empty?
    end

    def validate_result!(result, root, context)
      raise Corpus::ContractError, 'recipe adapter result must be a Hash' unless result.is_a?(Hash)
      raise Corpus::ContractError, 'recipe adapter claimed a different root' unless result.fetch('root_id') == root.fetch('id')
      raise Corpus::ContractError, 'recipe adapter returned an unknown verdict' unless %w[PASS FAIL].include?(result.fetch('product_verdict'))
      if result.fetch('product_verdict') == 'PASS' && context.dig(:native_observation, 'status') != 'pass'
        raise Corpus::ContractError, 'recipe adapter cannot claim PASS without a passing native observation'
      end
      raise Corpus::ContractError, 'recipe adapter row must be a Hash' unless result.fetch('row', {}).is_a?(Hash)

      evidence = result.fetch('attempt_evidence')
      raise Corpus::ContractError, 'recipe adapter produced no attempt evidence' unless evidence.is_a?(Array) && !evidence.empty?
      evidence.each { |attempt| authenticate_attempt!(attempt, root, context) }
    end

    def authenticate_attempt!(attempt, root, context)
      raise Corpus::ContractError, 'recipe adapter attempt must be a Hash' unless attempt.is_a?(Hash)
      source_root = File.realpath(context.fetch(:source_root))
      expected_inputs = (root['input_files'] || root.fetch('source_files')).to_h do |relative|
        [relative, Corpus.file_record(Corpus.safe_path(source_root, relative))]
      end
      raise Corpus::ContractError, 'recipe adapter attempt inputs differ' unless attempt.fetch('inputs') == expected_inputs

      stage = attempt.fetch('stage')
      argv = stage.fetch('argv')
      raise Corpus::ContractError, 'recipe adapter attempt command is invalid' unless argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) }
      executable = attempt.fetch('executable')
      Corpus::Validation.file!(executable)
      raise Corpus::ContractError, 'recipe adapter attempt executable differs' unless File.realpath(argv.first) == File.realpath(executable.fetch('path'))
      state = stage.fetch('state')
      raise Corpus::ContractError, 'recipe adapter attempt terminal is incomplete' unless
        TERMINAL_STATES.include?(state) && [true, false].include?(stage.fetch('spawned')) &&
        stage.key?('exit') && stage.key?('signal') && stage.fetch('duration_seconds').is_a?(Numeric) &&
        stage.fetch('duration_seconds').finite?
      if state == 'launch_failure'
        raise Corpus::ContractError, 'recipe adapter launch failure incorrectly claims a spawned process' if stage.fetch('spawned')
        raise Corpus::ContractError, 'recipe adapter launch failure has a process result' unless stage['exit'].nil? && stage['signal'].nil?
      else
        raise Corpus::ContractError, 'recipe adapter terminal attempt lacks a spawned process' unless stage.fetch('spawned')
        raise Corpus::ContractError, 'recipe adapter terminal attempt lacks a process result' unless stage['exit'].is_a?(Integer) || stage['signal'].is_a?(Integer)
      end
      %w[stdout stderr].each { |stream| Corpus::Validation.file!(stage.fetch(stream)) }
      if File.realpath(stage.fetch('stdout').fetch('path')) == File.realpath(stage.fetch('stderr').fetch('path'))
        raise Corpus::ContractError, 'recipe adapter attempt reused a capture stream'
      end
      true
    rescue SystemCallError => error
      raise Corpus::ContractError, "recipe adapter attempt authentication failed: #{error.message}"
    end
  end

  module_function

  def registry
    @registry ||= Registry.new
  end

  def register(**arguments)
    registry.register(**arguments)
  end

  def registrations
    registry.registrations
  end

  def eligible?(root)
    registry.eligible?(root)
  end

  def dispatch(**arguments)
    registry.dispatch(**arguments)
  end

  def load_directory(directory)
    adapter_paths(directory).each { |path| require path }
  end

  # A subset runner must bind every source file that can change adapter
  # registration or dispatch. This is separate from loading so the product can
  # authenticate the exact extension set before it selects roots.
  def runner_paths(directory)
    [File.realpath(__FILE__), *adapter_paths(directory)]
  end

  def adapter_paths(directory)
    own_file = File.realpath(__FILE__)
    Dir[File.join(directory, 'recipe_*.rb')].map { |path| File.realpath(path) }.reject { |path| path == own_file }.sort
  end
end
