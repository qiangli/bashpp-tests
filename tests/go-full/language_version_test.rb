# frozen_string_literal: true
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/corpus/executor'
require_relative '../../tools/go-full/typechecker'

class TypecheckerLanguageVersionTest < Minitest::Test
  def test_exact_joined_and_separated_flags_route_to_both_product_modes
    ['// -lang=go1.12', '// -lang go1.12'].each do |header|
      config = GoFullTypechecker.checker_flags(header + "\npackage p\n")
      assert_equal 'go1.12', config.fetch('go_version')
      assert_empty config.fetch('unsupported')
      %w[interpreted compiled].each do |mode|
        argv = GoFullTypechecker.checking_argv('/candidate/bashy', mode, 'original.go', '/fresh/generated.go', config.fetch('go_version'))
        assert_equal 1, argv.count('--go-version=go1.12')
        assert_operator argv.index('--go-version=go1.12'), :<, argv.index('original.go')
      end
    end
  end

  def test_native_last_value_semantics_and_unsupported_flags
    config = GoFullTypechecker.checker_flags("// -lang=go1.12 -lang go1.13\npackage p\n")
    assert_equal 'go1.13', config.fetch('go_version')
    assert_empty config.fetch('unsupported')
    %w[-lang -lang= -lang=invalid -lang=go1.12junk].each do |flag|
      refute_empty GoFullTypechecker.checker_flags("// #{flag}\npackage p\n").fetch('unsupported'), flag
    end
    config = GoFullTypechecker.checker_flags("// -lang=go1.12 -fakeImportC -goexperiment=unknown\npackage p\n")
    assert_equal %w[harness-flag:-fakeImportC harness-flag:-goexperiment], config.fetch('unsupported')
  end

  def test_language_support_never_waives_other_recipe_obligations
    Dir.mktmpdir('tc-lang-') do |dir|
      File.write(File.join(dir, 'original.go'), "// -lang=go1.12\n//go:build ignore\npackage p\n")
      File.write(File.join(dir, 'other.go'), "package p\n")
      root = { 'axis' => 'typechecker', 'input_files' => %w[original.go other.go], 'build_constraints' => { 'original.go' => ['//go:build ignore'] } }
      assert_equal ['build-tag-applicability:original.go', 'joint-multi-file-package-check'], GoFullTypechecker.unsupported_options(root, dir)
      refute GoFullTypechecker.adaptable?(root, dir)
    end
  end
end
