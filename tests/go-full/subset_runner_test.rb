# frozen_string_literal: true
# Sprint: #142; Story: #24; Story-ID: 605c7c4f2cad

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/go-full/product'

class GoFullSubsetRunnerTest < Minitest::Test
  RETAINED = File.expand_path('~/.bashy/sprint118/evidence/go-full/product-all-008')
  RETAINED_ROOTS_SHA256 = '47d938ae72720293753cf4a4da80dfe6ec491c9421c2a182015f159c885305f2'
  RETAINED_SUMMARY_SHA256 = '62834ef509a03cd43b5d45ddf86acbb4a95787713f8c4eae8ce8be4caaab9aef'

  def setup
    @tmp = Dir.mktmpdir('go-full-subset-')
    @candidate = File.join(@tmp, 'candidate.json')
    @runner = File.join(@tmp, 'runner.rb')
    @selector = File.join(@tmp, 'subset.rb')
    File.write(@candidate, "candidate\n")
    File.write(@runner, "runner\n")
    File.write(@selector, "selector\n")
    @inventory = { 'action-catalog.json' => { 'sha256' => 'a' * 64 }, 'testdir-roots.jsonl' => { 'sha256' => 'b' * 64 } }
    @roots = Array.new(GoFullSubset::OFFICIAL_ROOTS) { |index| { 'id' => format('root:%04d', index), 'axis' => 'testdir' } }
    @ids = %w[root:0007 root:0102 root:3494]
    @evidence = File.join(@tmp, 'subsets', 'feedback-008')
    @manifest = File.join(@tmp, 'feedback-008.json')
    write_manifest
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def manifest(overrides = {})
    ids = overrides.fetch('root_ids', @ids)
    { 'schema' => GoFullSubset::SCHEMA, 'name' => 'feedback-008', 'claim_scope' => GoFullSubset::CLAIM_SCOPE,
      'expected_count' => ids.length, 'root_ids' => ids, 'root_ids_sha256' => GoFullSubset.sha(ids),
      'inventory_sha256' => GoFullSubset.inventory_binding(@inventory), 'runner_sha256' => GoFullSubset.runner_binding([@runner, @selector]),
      'candidate_sha256' => Corpus.digest(@candidate) }.merge(overrides)
  end

  def write_manifest(overrides = {})
    File.write(@manifest, Corpus.canonical(manifest(overrides)) + "\n")
  end

  def load_selection(**overrides)
    GoFullSubset.load(path: @manifest, expected_sha256: Corpus.digest(@manifest), roots: @roots,
      inventory: @inventory, candidate_path: @candidate, runner_paths: [@runner, @selector], evidence: @evidence,
      protected_roots: [], **overrides)
  end

  def test_exact_hash_bound_arbitrary_ids_are_selected_in_manifest_order
    selected = load_selection
    assert_equal @ids, selected.fetch('roots').map { |root| root.fetch('id') }
    assert_equal 3, selected.fetch('expected_count')
    assert_equal Corpus.digest(@manifest), selected.dig('manifest', 'sha256')
    assert_equal [Corpus.digest(@runner), Corpus.digest(@selector)], selected.fetch('runner').map { |record| record.fetch('sha256') }
    assert_equal Corpus.digest(@candidate), selected.dig('candidate', 'sha256')
  end

  def test_forged_count_duplicate_unknown_and_missing_ids_fail_closed
    mutations = [
      { 'expected_count' => @ids.length + 1 },
      { 'root_ids' => [@ids.first, @ids.first], 'expected_count' => 2, 'root_ids_sha256' => GoFullSubset.sha([@ids.first, @ids.first]) },
      { 'root_ids' => ['root:9999'], 'expected_count' => 1, 'root_ids_sha256' => GoFullSubset.sha(['root:9999']) },
      { 'root_ids' => @ids.drop(1), 'expected_count' => @ids.length }
    ]
    mutations.each do |change|
      write_manifest(change)
      assert_raises(Corpus::ContractError) { load_selection }
    end
  end

  def test_changed_manifest_inventory_runner_and_candidate_fail_closed
    original_hash = Corpus.digest(@manifest)
    File.open(@manifest, 'a') { |stream| stream.write(" \n") }
    assert_raises(Corpus::ContractError) { load_selection(expected_sha256: original_hash) }
    write_manifest('inventory_sha256' => 'c' * 64)
    assert_raises(Corpus::ContractError) { load_selection }
    write_manifest('runner_sha256' => 'd' * 64)
    assert_raises(Corpus::ContractError) { load_selection }
    write_manifest('candidate_sha256' => 'e' * 64)
    assert_raises(Corpus::ContractError) { load_selection }
  end

  def test_full_denominator_claim_and_protected_output_paths_fail_closed
    all_ids = @roots.map { |root| root.fetch('id') }
    write_manifest('root_ids' => all_ids, 'expected_count' => all_ids.length, 'root_ids_sha256' => GoFullSubset.sha(all_ids))
    assert_raises(Corpus::ContractError) { load_selection }

    write_manifest
    protected = File.join(@tmp, 'subsets')
    assert_raises(Corpus::ContractError) { load_selection(protected_roots: [protected]) }
    assert_raises(Corpus::ContractError) { load_selection(evidence: File.join(@tmp, 'product-all-009')) }
  end

  def test_subset_summary_has_only_subset_scope_and_exact_per_root_verdicts
    selected = load_selection
    rows = selected.fetch('roots').map.with_index do |root, index|
      root.merge('product_verdict' => index == 1 ? 'PASS' : 'FAIL')
    end
    summary = GoFullSubset.summary(selected, rows, 'source_integrity_after' => true)
    assert_equal 'go-full-product-subset/v1', summary.fetch('schema')
    assert_equal 'subset-only', summary.fetch('scope')
    assert_equal Hash[@ids.zip(%w[FAIL PASS FAIL])], summary.fetch('per_root_verdicts')
    %w[verdict roots selected_root_denominator full_manifest_denominators all_runtime_tests_covered].each do |forbidden|
      refute summary.key?(forbidden), "subset summary emitted forbidden corpus field #{forbidden}"
    end
    assert_raises(Corpus::ContractError) { GoFullSubset.summary(selected, rows, 'full_manifest_denominators' => { 'testdir' => 2726 }) }
    assert_raises(Corpus::ContractError) { GoFullSubset.summary(selected, rows, 'verdict' => 'PASS') }
    File.write(@runner, "changed runner\n")
    assert_raises(Corpus::ContractError) { GoFullSubset.summary(selected, rows, {}) }
  end

  def test_retained_product_all_008_control_reproduces_exact_selected_verdicts
    roots_path = File.join(RETAINED, 'roots.jsonl')
    summary_path = File.join(RETAINED, 'summary.json')
    skip 'authenticated product-all-008 evidence is not installed on this host' unless File.file?(roots_path) && File.file?(summary_path)
    assert_equal RETAINED_ROOTS_SHA256, Corpus.digest(roots_path)
    assert_equal RETAINED_SUMMARY_SHA256, Corpus.digest(summary_path)

    expected = { 'package:internal/types/errors' => 'FAIL', 'testdir:64bit.go' => 'FAIL',
                 'testdir:abi/defer_aggregate.go' => 'PASS' }
    full_summary = JSON.parse(File.read(summary_path))
    Corpus::Validation.file!(full_summary.fetch('native_summary'))
    native_summary = JSON.parse(File.read(full_summary.dig('native_summary', 'path')))
    inventory_dir = File.expand_path('../../docs/go-full', __dir__)
    @roots = %w[testdir typechecker package].flat_map do |axis|
      GoFullProduct.read_rows(File.join(inventory_dir, axis + '-roots.jsonl')).map { |root| root.merge('axis' => axis) }
    end
    @inventory = native_summary.fetch('inventory')
    @ids = expected.keys.sort
    write_manifest
    selection = load_selection

    retained = GoFullProduct.unique_rows(roots_path)
    selected = selection.fetch('roots').map { |root| retained.fetch(root.fetch('id')) }
    assert_equal expected.sort.to_h, selected.to_h { |row| [row.fetch('id'), row.fetch('product_verdict')] }
    assert_equal @ids, selected.map { |row| row.fetch('id') }
  end
end
