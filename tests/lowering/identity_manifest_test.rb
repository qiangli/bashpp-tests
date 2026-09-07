#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
VALIDATOR = File.join(ROOT, 'tools/lowering/identity_manifest.rb')
MANIFEST = File.join(ROOT, 'docs/lowering/identities.tsv')
AST_API = File.join(ROOT, 'docs/lowering/ast_api.tsv')

def reject!(label, option, path)
  _out, _err, status = Open3.capture3(VALIDATOR, option, path)
  abort "identity tamper test accepted #{label}" if status.success?
end

out, err, status = Open3.capture3(VALIDATOR)
abort "identity manifest baseline failed:\n#{out}#{err}" unless status.success?

rejected = 0
Dir.mktmpdir('s117-lowering-manifest-') do |dir|
  baseline = File.binread(MANIFEST)
  mutations = {
    'count mutation' => baseline.sub("\t13\t369d", "\t12\t369d"),
    'digest mutation' => baseline.sub(/a8bfbba9/, '00000000'),
    'deferred state' => baseline.sub('agentic-boundary', 'planned'),
    'unapproved source' => baseline.sub('tests/agentic/cases.tsv', 'private/umbrella.tsv'),
    'dropped group' => baseline.lines.reject { |line| line.start_with?("public-go-tour\t") }.join,
    'public AST count mutation' => baseline.sub(/(public-ast-api\tdocs\/lowering\/ast_api.tsv\tast-api\t)(\d+)/) { "#{$1}#{$2.to_i - 1}" },
    'runtime obligation digest mutation' => baseline.sub(/e53f1080/, '00000000')
  }
  mutations.each do |label, contents|
    abort "no-op mutation: #{label}" if contents == baseline
    path = File.join(dir, label.gsub(' ', '-') + '.tsv')
    File.binwrite(path, contents)
    reject!(label, '--manifest', path)
    rejected += 1
  end

  ast_baseline = File.binread(AST_API)
  # These are independent omissions: the same call node serving an expression
  # must not be counted as a new node, and Return.Call is a field edge, not a
  # second expression variant or a claim that every AST field is inventoried.
  identity_drops = %w[
    node:BashPPFuncType
    variant:BashPPTypeExpr:BashPPFuncType
    variant:BashPPExpr:BashPPCall
    edge:BashPPReturn:Call
    edge:BashPPReturn:Expr
    edge:BashPPCall:ArgExprs
  ]
  ast_mutations = identity_drops.to_h do |identity|
    ["drop #{identity}", ast_baseline.lines.reject { |line| line.start_with?(identity + "\t") }.join]
  end
  ast_mutations['duplicate typed argument edge'] = ast_baseline + "edge:BashPPCall:ArgExprs\tfield-edge\tsyntax/bashpp_nodes.go\n"
  ast_mutations['misclassify typed argument edge'] = ast_baseline.sub("edge:BashPPCall:ArgExprs\tfield-edge\t", "edge:BashPPCall:ArgExprs\texpr-variant\t")
  ast_mutations['misattribute typed argument edge'] = ast_baseline.sub("edge:BashPPCall:ArgExprs\tfield-edge\tsyntax/bashpp_nodes.go", "edge:BashPPCall:ArgExprs\tfield-edge\tsyntax/nodes.go")
  ast_mutations['duplicate scalar return edge'] = ast_baseline + "edge:BashPPReturn:Expr\tfield-edge\tsyntax/bashpp_nodes.go\n"
  ast_mutations['misclassify scalar return edge'] = ast_baseline.sub("edge:BashPPReturn:Expr\tfield-edge\t", "edge:BashPPReturn:Expr\texpr-variant\t")
  ast_mutations['duplicate returned call edge'] = ast_baseline + "edge:BashPPReturn:Call\tfield-edge\tsyntax/bashpp_nodes.go\n"
  ast_mutations['misclassify concrete signature'] = ast_baseline.sub("node:BashPPFuncType\tnode\t", "node:BashPPFuncType\ttype-variant\t")
  ast_mutations['misattribute returned call edge'] = ast_baseline.sub("edge:BashPPReturn:Call\tfield-edge\tsyntax/bashpp_nodes.go", "edge:BashPPReturn:Call\tfield-edge\tsyntax/nodes.go")
  ast_mutations.each_with_index do |(label, contents), index|
    abort "no-op AST mutation: #{label}" if contents == ast_baseline
    path = File.join(dir, "ast-mutation-#{index}.tsv")
    File.binwrite(path, contents)
    reject!(label, '--ast-api', path)
    rejected += 1
  end
end
puts "identity manifest tamper tests PASS: baseline plus #{rejected} rejected mutations"
