# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
require_relative '../corpus/executor'

module GoByExampleRuntimeConfig
  module_function

  def configure(go, root, env, deadline:, log_prefix:)
    stages = []
    [[go, 'telemetry', 'off'], [go, 'env', '-json', 'GOTELEMETRY', 'GOTELEMETRYDIR']].each_with_index do |argv, index|
      budget = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Corpus::ContractError, 'runtime configuration deadline expired' unless budget.positive?
      stage = Corpus.capture(argv, cwd: root, env: env, timeout: [budget, 20].min,
                             stdin: File::NULL, log_prefix: log_prefix + "/#{index}")
      stages << stage
      raise Corpus::ContractError, 'SDK telemetry configuration failed' unless Corpus.success?(stage)
    end
    config = JSON.parse(File.binread(stages.last.fetch('stdout').fetch('path')))
    raise Corpus::ContractError, 'Go telemetry did not report off' unless config['GOTELEMETRY'] == 'off'
    mode = File.join(config.fetch('GOTELEMETRYDIR'), 'mode')
    raise Corpus::ContractError, 'telemetry configuration escaped isolated HOME' unless File.realpath(mode).start_with?(File.realpath(root) + '/')
    {'state' => 'complete', 'environment' => {'OTEL_TRACES_EXPORTER' => env.fetch('OTEL_TRACES_EXPORTER')},
     'go_mode' => 'off', 'mode_file' => Corpus.file_record(mode), 'stages' => stages}
  rescue StandardError => error
    {'state' => 'configuration_failure', 'detail' => error.message, 'stages' => stages}
  end
end
