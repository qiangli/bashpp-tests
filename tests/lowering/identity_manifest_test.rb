#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
VALIDATOR = File.join(ROOT, 'tools/lowering/identity_manifest.rb')
MANIFEST = File.join(ROOT, 'docs/lowering/identities.tsv')

def reject!(label, path)
  _out, _err, status = Open3.capture3(VALIDATOR, '--manifest', path)
  abort "identity tamper test accepted #{label}" if status.success?
end

out, err, status = Open3.capture3(VALIDATOR)
abort "identity manifest baseline failed:\n#{out}#{err}" unless status.success?

Dir.mktmpdir('s117-lowering-manifest-') do |dir|
  baseline = File.binread(MANIFEST)
  mutations = {
    'count mutation' => baseline.sub("\t13\t369d", "\t12\t369d"),
    'digest mutation' => baseline.sub(/a8bfbba9/, '00000000'),
    'deferred state' => baseline.sub('agentic-boundary', 'planned'),
    'unapproved source' => baseline.sub('tests/agentic/cases.tsv', 'private/umbrella.tsv'),
    'dropped group' => baseline.lines.reject { |line| line.start_with?("public-go-tour\t") }.join
  }
  mutations.each do |label, contents|
    path = File.join(dir, label.gsub(' ', '-') + '.tsv')
    File.binwrite(path, contents)
    reject!(label, path)
  end
end
puts 'identity manifest tamper tests PASS: baseline plus 5 rejected mutations'
