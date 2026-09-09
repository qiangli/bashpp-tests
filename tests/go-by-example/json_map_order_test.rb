# frozen_string_literal: true

# Sprint: #118; Story: #18; Story-ID: 2ab04e37d660
# Corpus-governance tests for the reviewed JSON map-order reclassification.
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/go-by-example/normalizer'

class JsonMapOrderTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  VALIDATOR = File.join(ROOT, 'tools/go-by-example/validate.sh')
  CLASSIFICATION = File.join(ROOT, 'docs/go-by-example/classification.tsv')

  def json_output(first:, second:)
    <<~OUTPUT
      true
      1
      2.34
      "gopher"
      ["apple","peach","pear"]
      #{first}
      {"Page":1,"Fruits":["apple","peach","pear"]}
      {"page":1,"fruits":["apple","peach","pear"]}
      map[num:6.13 strs:[a b]]
      6.13
      a
      {1 [apple peach]}
      apple
      #{second}
      {1 [apple peach]}
    OUTPUT
  end

  def normalize(text)
    GoByExampleNormalizer.normalize(text, ['map_order'], :stdout)
  end

  def test_reviewed_json_row_is_admitted_by_the_schema
    row = File.readlines(CLASSIFICATION, chomp: true).find { |line| line.start_with?("examples/json/json.go\t") }
    assert_equal "examples/json/json.go\tprogram\tmap_iteration\tmap_order\tnone\tnone", row
    _out, err, status = Open3.capture3('bash', VALIDATOR)
    assert status.success?, err
  end

  def test_map_order_canonicalizes_only_the_two_json_map_regions
    apple_first = json_output(first: '{"apple":5,"lettuce":7}', second: '{"apple":5,"lettuce":7}')
    lettuce_first = json_output(first: '{"lettuce":7,"apple":5}', second: '{"lettuce":7,"apple":5}')
    assert_equal normalize(apple_first), normalize(lettuce_first)
    assert_equal apple_first, normalize(apple_first)
  end

  def test_json_map_order_rejects_changed_members_and_deterministic_output
    good = json_output(first: '{"apple":5,"lettuce":7}', second: '{"lettuce":7,"apple":5}')
    assert_raises(RuntimeError) { normalize(good.sub('"lettuce":7', '"lettuce":8')) }
    refute_equal normalize(good), normalize(good.sub("2.34\n", "9.99\n"))
    assert_raises(RuntimeError) { normalize(good + "unexpected\n") }
  end

  def test_schema_rejects_a_json_normalization_not_licensed_by_map_iteration
    Dir.mktmpdir('gbe-json-schema-') do |dir|
      altered = File.read(CLASSIFICATION).sub(
        "examples/json/json.go\tprogram\tmap_iteration\tmap_order\tnone\tnone",
        "examples/json/json.go\tprogram\tmap_iteration\twallclock\tnone\tnone"
      )
      path = File.join(dir, 'classification.tsv')
      File.write(path, altered)
      out, status = Open3.capture2e({'GBE_CLASSIFICATION' => path}, 'bash', VALIDATOR)
      refute status.success?
      assert_includes out, 'normalization wallclock is not licensed by any declared behavior'
    end
  end
end
