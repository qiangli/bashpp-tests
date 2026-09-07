#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
# The P0 entrypoint is structural. Compiled BASHSHARP33 parity is an explicit,
# separate attempt because no compiler parity can be established yet.
ROOT = File.expand_path('../..', __dir__)
parity = ARGV.delete('--parity')
self_test = ARGV.delete('--self-test')
abort 'usage: ruby tools/lowering/validate.rb [--self-test | --parity]' unless ARGV.empty? || (self_test && !parity)

commands = [
  [File.join(ROOT, 'tools/lowering/identity_manifest.rb')],
  [File.join(ROOT, 'tests/lowering/identity_manifest_test.rb')],
  [File.join(ROOT, 'tests/lowering/differential_contract_test.rb')]
]
commands.each do |command|
  system(*command) || exit(1)
end
unless parity
  puts 'Sprint 117 lowering P0 structural contract PASS'
  exit(0)
end

system(File.join(ROOT, 'tools/lowering/differential.rb')) || exit(1)
puts 'Sprint 117 BASHSHARP33 parity PASS: compiled compiler/corpus parity remains separate'
