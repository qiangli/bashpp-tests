# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
require_relative '../corpus/executor'

# Bind a staged source/driver/asset tree before the phase receives it. Build
# tools may add go.sum, but may never alter an already-bound input.
#
# A binding also declares WHOSE input it is. The pinned corpus directory and the
# shared binary directory are :shared -- every mode reads them, so a change
# there invalidates every mode. A staging tree that only one mode is ever given
# (src/oracle, src/interpreted, src/compiled, compiled/transpile,
# compiled/build) belongs to that mode alone. Scope changes nothing about how
# strictly a tree is compared; it only decides which phases that tree is an
# input to, so that a mutation is charged to the mode that caused it instead of
# silently suppressing an unrelated mode that was never handed the tree.
class GoByExampleInputs
  SCOPES = %i[shared oracle interpreted compiled].freeze

  attr_reader :root, :scope

  def initialize(root, allow_additions: false, scope: :shared)
    raise ArgumentError, "unknown binding scope: #{scope}" unless SCOPES.include?(scope)
    @root, @allow_additions, @scope = root, allow_additions, scope
    @before = Corpus.snapshot(root)
  end

  # Every entry bound before the phase must still be byte-identical afterwards,
  # and unless additions were declared the entry set may not grow either. A
  # removed or replaced entry is caught by the first test (its `after` value is
  # nil or different), so declaring additions never permits a bound byte to move.
  def changes
    after = Corpus.snapshot(@root)
    altered = @before.reject { |name, entry| after[name] == entry }.keys.sort.map { |name| "!#{name}" }
    added = @allow_additions ? [] : (after.keys - @before.keys).sort.map { |name| "+#{name}" }
    altered + added
  rescue StandardError => e
    ["!#{e.class}"]
  end

  def unchanged?
    changes.empty?
  end

  # Bindings the given phase actually consumes: the shared ones plus, when the
  # phase belongs to a mode, that mode's own staging trees.
  def self.for_scopes(bindings, scopes)
    wanted = Array(scopes).map(&:to_sym)
    bindings.select { |binding| wanted.include?(binding.scope) }
  end

  def self.intact?(bindings, scopes)
    for_scopes(bindings, scopes).all?(&:unchanged?)
  end

  def self.enforce(result, bindings, scopes)
    changed = for_scopes(bindings, scopes).reject(&:unchanged?)
    return result if changed.empty?
    detail = changed.map { |binding| "#{binding.root} (#{binding.changes.join(',')})" }.join('; ')
    result['state'] = 'input_mutation'
    result['detail'] = 'staged original source, generated driver, or declared asset changed during phase: ' + detail
    result
  end
end
