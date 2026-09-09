# frozen_string_literal: true
# Sprint: #118; Story: #11; Story-ID: e29305614139
require_relative 'executor'

module Corpus
  # Verifies retained observations against a separately supplied expected set.
  # This is a structural/integrity gate, not cryptographic proof of execution;
  # independent product replay is still required for certification.
  module Validation
    module_function

    def file!(record)
      raise ContractError, 'missing file record' unless record.is_a?(Hash)
      path = record.fetch('path')
      raise ContractError, "file changed: #{path}" unless Corpus.digest(path) == record.fetch('sha256') && File.size(path) == record.fetch('bytes')
    end

    def validate!(records, expected:, provenance:)
      ids = records.map { |r| r.fetch('id') }
      raise ContractError, 'duplicate or missing cases' unless ids.uniq == ids && ids.sort == expected.keys.sort
      seen_stream_paths = {}
      [provenance.dig('candidate', 'launcher'), provenance.dig('candidate', 'payload'), provenance.dig('sdk', 'binary')].each { |f| file!(f) }
      records.each do |record|
        raise ContractError, 'wrong schema/provenance' unless record['schema'] == SCHEMA && record['provenance'] == provenance
        obligation = expected.fetch(record.fetch('id'))
        %w[phase sources assets inputs args module_files package_input runtime_environment].each do |field|
          raise ContractError, "#{record['id']}: obligation #{field} differs" unless record[field] == obligation.fetch(field)
        end
        (record.fetch('sources') + record.fetch('assets') + record.fetch('module_files').keys).each { |path| Corpus.safe_path('/unused', path) }
        Corpus.package_argument(record['package_input'])
        record.fetch('inputs').each_value { |f| file!(f) }
        modes = record.fetch('modes')
        raise ContractError, 'missing or extra modes' unless modes.keys.sort == MODES.sort
        observations = []
        modes.each do |mode, result|
          raise ContractError, 'incomplete/failed mode' unless result['state'] == 'complete' && result['input_integrity'] == true && result['mode'] == mode && result['phase'] == record['phase']
          producer = record['phase'] == 'compile' ? 'compile' : 'build'
          wanted = case mode
                   when 'baseline' then [producer]
                   when 'interpreted' then [%w[build compile].include?(record['phase']) ? 'check' : 'run']
                   when 'compiled' then ['transpile', producer]
                   end
          wanted += ['run'] if record['phase'] == 'run' && mode != 'interpreted'
          checks = result.fetch('input_checks')
          expected_checks = (mode == 'interpreted' ? wanted : wanted.reject { |stage| stage == 'run' }).flat_map { |stage| ['before-' + stage, 'after-' + stage] }
          raise ContractError, 'missing/failed input boundary check' unless checks.map { |check| check['phase'] } == expected_checks && checks.all? { |check| check['valid'] == true }
          stages = result.fetch('stages')
          raise ContractError, 'missing/extra/wrong stages' unless stages.map { |s| s['stage'] } == wanted
          stages.each do |stage|
            raise ContractError, 'failed stage' unless stage['spawned'] == true && stage['state'] == 'exited' && stage['signal'].nil? && (stage['stage'] == 'run' || stage['exit'] == 0)
            %w[stdout stderr].each do |stream|
              observation = stage.fetch(stream)
              file!(observation)
              resolved = File.realpath(observation.fetch('path'))
              raise ContractError, 'duplicated stream file' if seen_stream_paths[resolved]
              seen_stream_paths[resolved] = true
            end
            argv = stage.fetch('argv')
            if stage['stage'] == 'run'
              raise ContractError, 'runtime cwd differs' unless stage['cwd'] == result.fetch('runtime_directory')
              record.fetch('runtime_environment').each do |key, value|
                raise ContractError, 'runtime environment differs' unless stage.fetch('environment')[key] == value
              end
            end
            expected_cache = record.fetch('runtime_environment').fetch('GOCACHE', provenance.dig('cache', 'path')) if stage['stage'] == 'run'
            expected_cache = provenance.dig('cache', 'path') unless stage['stage'] == 'run'
            raise ContractError, 'cache configuration differs' unless stage.fetch('environment')['GOCACHE'] == expected_cache
            raise ContractError, 'empty command/cwd/environment' unless argv.is_a?(Array) && !argv.empty? && stage['cwd'].is_a?(String) && stage['environment'].is_a?(Hash)
            expected_tool = case stage['stage']
                            when 'build', 'compile' then provenance.dig('sdk', 'binary', 'path')
                            when 'transpile', 'check' then provenance.dig('candidate', 'launcher', 'path')
                            when 'run' then mode == 'interpreted' ? provenance.dig('candidate', 'launcher', 'path') : result.dig('artifacts', 'native', 'path')
                            end
            raise ContractError, 'command tool differs' unless File.realpath(argv.first) == expected_tool
            input = Corpus.package_argument(record['package_input']) || record.fetch('sources').fetch(0)
            absolute_input = File.expand_path(input, result.fetch('source_directory'))
            exact = case stage['stage']
                    when 'check' then [argv.first, '--bashpp', '--source=go', '--check', absolute_input, *record.fetch('args')]
                    when 'transpile' then [argv.first, 'transpile', '--bashpp', '--source=go', input, '-o', result.dig('artifacts', 'generated', 'path'), '--map', result.dig('artifacts', 'source_map', 'path')]
                    when 'build' then [argv.first, 'build', '-o', result.dig('artifacts', 'native', 'path'), mode == 'baseline' ? input : result.dig('artifacts', 'generated', 'path')]
                    when 'compile' then [argv.first, 'tool', 'compile', '-e', '-p=p', '-importcfg=' + result.fetch('import_configuration').fetch('path'),
                                         '-o', result.dig('artifacts', 'object', 'path'), mode == 'baseline' ? input : result.dig('artifacts', 'generated', 'path')]
                    when 'run' then mode == 'interpreted' ? [argv.first, '--bashpp', '--source=go', absolute_input, *record.fetch('args')] : [argv.first, *record.fetch('args')]
                    end
            # Name the substitution before the generic mismatch: a linking `go build`
            # standing in for `go tool compile` is the failure mode worth reporting.
            raise ContractError, 'a link-required build cannot substitute for compile' if stage['stage'] == 'compile' && argv[1, 2] != %w[tool compile]
            raise ContractError, 'go run cannot substitute for build' if stage['stage'] == 'build' && (argv[1] != 'build' || !argv.include?('-o'))
            raise ContractError, 'argv differs from required recipe' unless argv == exact
            if %w[transpile check].include?(stage['stage']) || mode == 'interpreted'
              raise ContractError, 'missing Go-source mode flags' unless argv.include?('--bashpp') && argv.include?('--source=go')
            end
            raise ContractError, 'semantic check absent' if stage['stage'] == 'check' && !argv.include?('--check')
            raise ContractError, 'unexpected check during run' if stage['stage'] == 'run' && argv.include?('--check')
          end
          result.fetch('artifacts').each_value { |f| file!(f) }
          if mode == 'compiled'
            generated = result.fetch('artifacts').fetch('generated')
            map = JSON.parse(File.read(result.fetch('artifacts').fetch('source_map').fetch('path')))
            raise ContractError, 'source map digest mismatch' unless Corpus.valid_source_map?(map, generated, record.fetch('inputs').slice(*record.fetch('sources')))
          end
          publishes_archives = mode != 'interpreted' && record['phase'] == 'compile'
          raise ContractError, 'import configuration retained outside a compile obligation' if result.key?('import_configuration') && !publishes_archives
          if publishes_archives
            # The retained import configuration must still authenticate: same SDK,
            # same bounded captured recipe, same bytes, same archive contents. A
            # digest over the config file alone would let a substituted cache or a
            # changed stdlib archive certify.
            Corpus.authenticate_import_configuration!(result.fetch('import_configuration'), tool: provenance.dig('sdk', 'binary'))
            # Compile-only evidence is an object archive; a linked program would
            # mean the obligation was replaced by a stricter, different recipe.
            object = result.fetch('artifacts').fetch('object')
            raise ContractError, 'empty compile artifact' unless object.fetch('bytes').positive?
            raise ContractError, 'compile artifact is not a Go object archive' unless Corpus.go_object_archive?(object.fetch('path'))
            raise ContractError, 'compile phase must not retain a linked program' if result.fetch('artifacts').key?('native')
          elsif mode != 'interpreted'
            native = result.fetch('artifacts').fetch('native')
            raise ContractError, 'empty native artifact' unless native.fetch('bytes').positive?
            raise ContractError, 'native not executable' if record['phase'] == 'run' && !Corpus.native_binary?(native.fetch('path'))
            raise ContractError, 'build artifact is neither a program nor a Go archive' unless Corpus.native_binary?(native.fetch('path')) || Corpus.go_object_archive?(native.fetch('path'))
          end
          if record['phase'] == 'run'
            run = stages.last
            observations << [run['exit'], run['signal'], run.dig('stdout', 'sha256'), run.dig('stderr', 'sha256'), result.fetch('effects')]
          end
        end
        raise ContractError, 'differential mismatch' unless observations.empty? || observations.uniq.length == 1
        raise ContractError, 'verdict differs' unless record['verdict'] == 'PASS'
      end
      true
    rescue KeyError, TypeError, JSON::ParserError => e
      raise ContractError, "malformed evidence: #{e.message}"
    end
  end
end
