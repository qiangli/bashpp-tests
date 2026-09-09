# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../../tools/go-full/product'

class GoFullPhaseSelectionTest < Minitest::Test
  def roots
    directory = File.expand_path('../../docs/go-full', __dir__)
    %w[testdir typechecker package].flat_map do |axis|
      GoFullProduct.read_rows(File.join(directory, axis + '-roots.jsonl')).map { |r| r.merge('axis' => axis) }
    end
  end

  def test_complete_typechecker_axis_is_selected_without_filtering_recipe_options
    original = roots
    before = Corpus.canonical(original)
    selected = GoFullProduct.phase_roots(original, 'typechecker')
    expected = original.select { |r| r['axis'] == 'typechecker' }
    assert_equal 3495, original.length
    assert_equal 743, selected.length
    assert_equal expected, selected
    assert_equal before, Corpus.canonical(original)
    assert_same original, GoFullProduct.phase_roots(original, nil)
    assert_equal 521, GoFullProduct.phase_roots(original, 'negative').length
  end

  def test_missing_duplicate_and_extra_members_are_rejected
    selected = roots.select { |r| r['axis'] == 'typechecker' }
    [selected.drop(1), selected + [selected.first], selected.drop(1) + [selected.last]].each do |tampered|
      assert_raises(Corpus::ContractError) { GoFullProduct.phase_roots(tampered, 'typechecker') }
    end
  end

  def test_unknown_selector_cannot_fall_back_to_a_smaller_or_default_run
    ['', 'typecheck', 'typechecker:100', 'all'].each do |selection|
      assert_raises(Corpus::ContractError) { GoFullProduct.phase_roots(roots, selection) }
    end
  end
end
