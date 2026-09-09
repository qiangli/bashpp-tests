# frozen_string_literal: true
# These tests audit an explicitly selected real retained compile record. They
# never execute an original body, mutate its evidence, or create corpus credit.
require 'minitest/autorun'
require 'json'
require 'digest'
require_relative '../../tools/corpus/validate'
require_relative '../../tools/go-full/resume'

class CompileAdapterRetainedContextTest < Minitest::Test
  def setup
    path = ENV.fetch('GO_FULL_RETAINED_COMPILE_RECORD')
    expected_sha = ENV.fetch('GO_FULL_RETAINED_COMPILE_SHA256')
    assert_equal expected_sha, Digest::SHA256.file(path).hexdigest, 'explicit retained proof changed'
    @record = JSON.parse(File.read(path))
    @provenance = @record.fetch('provenance')
    @expected = { @record.fetch('id') => %w[phase sources assets inputs args module_files package_input runtime_environment].to_h { |key| [key, @record.fetch(key)] } }
    assert_equal 'compile', @record.fetch('phase')
    assert_empty @record.fetch('module_files')
    input = @record.fetch('sources').fetch(0)
    @source_root = @record.fetch('inputs').fetch(input).fetch('path').delete_suffix('/' + input)
    @root = { 'id' => @record.fetch('id'), 'path' => input, 'recipe' => { 'action' => 'compile', 'args' => @record.fetch('args') } }
    @environment = @record.dig('modes', 'baseline', 'import_configuration', 'context', 'environment')
  end

  def validate(record)
    Corpus::Validation.validate!([record], expected: @expected, provenance: @provenance)
  end

  def resume(record)
    GoFullResume.execution!(record, root: @root, source_root: @source_root, provenance: @provenance, modules: {}, environment: @environment)
  end

  def test_original_retained_record_remains_valid
    assert validate(@record)
    configuration = @record.dig('modes', 'baseline', 'import_configuration')
    assert Corpus.authenticate_import_configuration!(configuration, tool: @provenance.dig('sdk', 'binary'),
      context: Corpus.importcfg_provenance_context!(configuration, @provenance))
  end

  def test_self_consistent_preparation_environment_cannot_escape_the_cache_identity
    forged = JSON.parse(JSON.generate(@record))
    %w[baseline compiled].each do |mode|
      configuration = forged.fetch('modes').fetch(mode).fetch('import_configuration')
      configuration['context']['environment']['GOFLAGS'] = '-mod=mod -tags=forged'
      configuration['preparation']['environment'] = Corpus.importcfg_environment(configuration.fetch('context'))
    end
    assert_equal @provenance, forged.fetch('provenance'), 'the independently bound provenance was not changed'
    %w[baseline compiled].each do |mode|
      assert_equal @record.dig('modes', mode, 'stages'), forged.dig('modes', mode, 'stages'), 'actual compile capture remains unchanged'
    end
    [method(:validate), method(:resume)].each do |audit|
      error = assert_raises(Corpus::ContractError) { audit.call(forged) }
      assert_match(/build environment differs from the provenance cache key/, error.message)
    end
  end

  def test_rewriting_the_compile_stage_too_does_not_escape
    forged = JSON.parse(JSON.generate(@record))
    %w[baseline compiled].each do |mode|
      configuration = forged.fetch('modes').fetch(mode).fetch('import_configuration')
      configuration['context']['environment']['GOFLAGS'] = '-mod=mod'
      configuration['preparation']['environment'] = Corpus.importcfg_environment(configuration.fetch('context'))
      forged.fetch('modes').fetch(mode).fetch('stages').each { |stage| stage['environment']['GOFLAGS'] = '-mod=mod' }
    end
    assert_raises(Corpus::ContractError) { validate(forged) }
    assert_raises(Corpus::ContractError) { resume(forged) }
  end
end
