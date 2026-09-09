# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
require_relative '../corpus/executor'

# Bind a staged source/driver/asset tree before the phase receives it. Build
# tools may add go.sum, but may never alter an already-bound input.
class GoByExampleInputs
  attr_reader :root
  def initialize(root, allow_additions: false)
    @root, @allow_additions = root, allow_additions
    @before = Corpus.snapshot(root)
  end

  def unchanged?
    after = Corpus.snapshot(@root)
    (@allow_additions || after.keys.sort == @before.keys.sort) && @before.all? { |name, entry| after[name] == entry }
  rescue StandardError
    false
  end

  def self.enforce(result, bindings)
    unless bindings.all?(&:unchanged?)
      result['state'] = 'input_mutation'
      result['detail'] = 'staged original source, generated driver, or declared asset changed during phase'
    end
    result
  end
end
