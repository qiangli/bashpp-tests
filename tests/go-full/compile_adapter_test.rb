# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../../tools/corpus/executor'
require_relative '../../tools/go-full/product'

class CompileAdapterTest < Minitest::Test
  SOURCE_ROOT = '/Users/qiangli/.bashy/sprint118/sources/go-full/go'
  SDK_IDENTITY = '/Users/qiangli/.bashy/sprint118/sources/go-full-sdk-identity-relocated.json'
  CANDIDATE = '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-010/candidate.json'
  BASHY = '/private/tmp/s118-runtime-010/bashy/bin/bashy'

  def available?
    [SOURCE_ROOT, SDK_IDENTITY, CANDIDATE, BASHY].all? { |path| File.exist?(path) }
  end

  def test_exact_plain_single_file_compile
    skip 'frozen candidate 010 or pinned SDK is unavailable' unless available?
    
    root = { 'axis' => 'testdir', 'id' => 'testdir:empty.go', 'path' => 'test/empty.go',
             'input_files' => ['test/empty.go'], 'recipe' => { 'action' => 'compile', 'flags' => [], 'args' => [], 'environment_append' => [] },
             'expected_failure_sets' => [] }
    
    Dir.mktmpdir('tc-compile-') do |dir|
      options = { bashy: BASHY, timeout: 60, native: dir, evidence: dir, inventory: dir, source_root: SOURCE_ROOT, candidate: CANDIDATE, sdk_identity: SDK_IDENTITY }
      sdk_identity = JSON.parse(File.read(SDK_IDENTITY))
      candidate = JSON.parse(File.read(CANDIDATE))
      setup = GoFullProduct.execution_setup(options.merge(module_context: '/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-010/context.json', module_context_sha256: 'wait_need_to_skip_or_mock'), dir, candidate, sdk_identity) rescue nil

      sdk = { 'sha256' => sdk_identity.fetch('go').fetch('sha256'),
              'identity' => "go version #{sdk_identity.fetch('release')} #{sdk_identity.fetch('goos')}/#{sdk_identity.fetch('goarch')}" }
      executor = Corpus::Executor.new(bashy: BASHY, go: File.join(sdk_identity.fetch('root'), 'bin/go'), evidence_root: dir, candidate: candidate, sdk: sdk, env: {'GOTOOLCHAIN'=>'local'})
      
      record = executor.execute(id: root.fetch('id'), source_root: SOURCE_ROOT, sources: [root.fetch('path')], phase: 'compile')
      puts JSON.pretty_generate(record) if record.fetch("verdict") != "PASS"
      assert_equal 'PASS', record.fetch('verdict')
      assert_equal %w[baseline interpreted compiled], record.fetch('modes').keys
      
      # verify modes
      record.fetch('modes').each do |mode, result|
        assert_equal 'complete', result.fetch('state')
        assert result.fetch('input_integrity')
        if mode == 'baseline'
          assert result.dig('artifacts', 'native')
        elsif mode == 'compiled'
          assert result.dig('artifacts', 'native')
          assert result.dig('artifacts', 'generated')
        end
      end
    end
  end

  def test_compile_error_fails
    skip 'frozen candidate 010 or pinned SDK is unavailable' unless available?
    
    root = { 'axis' => 'testdir', 'id' => 'testdir:bad.go', 'path' => 'test/bad.go',
             'input_files' => ['test/bad.go'], 'recipe' => { 'action' => 'compile', 'flags' => [], 'args' => [], 'environment_append' => [] },
             'expected_failure_sets' => [] }
    
    Dir.mktmpdir('tc-compile-bad-') do |dir|
      sdk_identity = JSON.parse(File.read(SDK_IDENTITY))
      candidate = JSON.parse(File.read(CANDIDATE))
      
      # Make a bad file
      bad_source = File.join(dir, 'test/bad.go')
      FileUtils.mkdir_p(File.dirname(bad_source))
      File.write(bad_source, "package p\nfunc bad() { x }")
      
      sdk = { 'sha256' => sdk_identity.fetch('go').fetch('sha256'),
              'identity' => "go version #{sdk_identity.fetch('release')} #{sdk_identity.fetch('goos')}/#{sdk_identity.fetch('goarch')}" }
      executor = Corpus::Executor.new(bashy: BASHY, go: File.join(sdk_identity.fetch('root'), 'bin/go'), evidence_root: dir, candidate: candidate, sdk: sdk, env: {'GOTOOLCHAIN'=>'local'})
      
      record = executor.execute(id: root.fetch('id'), source_root: dir, sources: [root.fetch('path')], phase: 'compile')
      assert_equal 'FAIL', record.fetch('verdict')
      record.fetch('modes').each do |mode, result|
        assert_equal 'stage_failure', result.fetch('state')
      end
    end
end

  def test_tamper_fails
    skip 'frozen candidate 010 or pinned SDK is unavailable' unless available?
    
    root = { 'axis' => 'testdir', 'id' => 'testdir:empty.go', 'path' => 'test/empty.go',
             'input_files' => ['test/empty.go'], 'recipe' => { 'action' => 'compile', 'flags' => [], 'args' => [], 'environment_append' => [] },
             'expected_failure_sets' => [] }
             
    Dir.mktmpdir('tc-compile-tamper-') do |dir|
      sdk_identity = JSON.parse(File.read(SDK_IDENTITY))
      candidate = JSON.parse(File.read(CANDIDATE))
      
      sdk = { 'sha256' => sdk_identity.fetch('go').fetch('sha256'),
              'identity' => "go version #{sdk_identity.fetch('release')} #{sdk_identity.fetch('goos')}/#{sdk_identity.fetch('goarch')}" }
      executor = Corpus::Executor.new(bashy: BASHY, go: File.join(sdk_identity.fetch('root'), 'bin/go'), evidence_root: dir, candidate: candidate, sdk: sdk, env: {'GOTOOLCHAIN'=>'local'})
      
      # Since we mock tampering, we can mock Corpus.file_record to return a mismatch
      original_file_record = Corpus.method(:file_record)
      Corpus.stub :file_record, ->(p) { p.include?('empty.go') ? { 'path' => p, 'bytes' => 10, 'sha256' => 'tampered_sha256' } : original_file_record.call(p) } do
        assert_raises(Corpus::ContractError) do
          executor.execute(id: root.fetch('id'), source_root: SOURCE_ROOT, sources: [root.fetch('path')], phase: 'compile')
        end
      end
    end
  end

  def test_unimplemented_flags_fail_closed
    root = { 'axis' => 'testdir', 'id' => 'testdir:empty.go', 'path' => 'test/empty.go',
             'input_files' => ['test/empty.go'], 'recipe' => { 'action' => 'compile', 'flags' => ['-tags=magic'], 'args' => [], 'environment_append' => [] },
             'expected_failure_sets' => [] }
    refute GoFullProduct.simple_recipe?(root)
  end
end
