#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
# Independent, fail-closed identity inventory. It does not call source validators.
require 'digest'
require 'optparse'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
SOURCES = {
  'tests/agentic/cases.tsv' => :first_column,
  'tests/bashsharp/matrix.tsv' => :bashsharp_families,
  'tools/startsites/baseline.tsv' => :first_column,
  'tests/manifest.tsv' => :first_column,
  'docs/go-corpus/inventory.tsv' => :first_column,
  'docs/go-by-example/inventory.tsv' => :first_column,
  'tests/tour/inventory.tsv' => :first_column
}.freeze
KINDS = %w[agentic-boundary bashsharp-family bashsharp-runtime certified-node public-profile public-corpus].freeze
REQUIRED_GROUPS = {
  'agentic-boundaries' => ['tests/agentic/cases.tsv', 'agentic-boundary'],
  'bashsharp-families' => ['tests/bashsharp/matrix.tsv', 'bashsharp-family'],
  'bashsharp-lowering' => ['tests/bashsharp/matrix.tsv', 'bashsharp-runtime'],
  'certified-startsites' => ['tools/startsites/baseline.tsv', 'certified-node'],
  'go-profile-fixtures' => ['tests/manifest.tsv', 'public-profile'],
  'official-go-corpus' => ['docs/go-corpus/inventory.tsv', 'public-corpus'],
  'public-go-by-example' => ['docs/go-by-example/inventory.tsv', 'public-corpus'],
  'public-go-tour' => ['tests/tour/inventory.tsv', 'public-corpus']
}.freeze

def fail!(message)
  warn "lowering identity manifest: FAIL: #{message}"
  exit 2
end

def data_lines(path)
  fail!("missing source #{path}") unless File.file?(path) && !File.symlink?(path)
  File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }
end

def first_column(root, source)
  data_lines(File.join(root, source)).map do |line|
    identity = line.split("\t", -1).first
    fail!("empty identity in #{source}") if identity.nil? || identity.empty?
    identity
  end
end

def bashsharp_lowering(root)
  identities = []
  data_lines(File.join(root, 'tests/bashsharp/matrix.tsv')).each do |matrix_line|
    fields = matrix_line.split("\t", -1)
    fail!("malformed Bash# matrix row #{matrix_line}") unless fields.length == 5
    family, ledger = fields[0], fields[4]
    fail!("unsafe lowering ledger #{ledger}") unless ledger.match?(%r{\A[a-z-]+/lowering\.tsv\z})
    data_lines(File.join(root, 'tests/bashsharp', ledger)).each do |line|
      case_id = line.split("\t", -1).first
      fail!("empty lowering identity in #{ledger}") if case_id.nil? || case_id.empty?
      identities << "#{family}/#{case_id}"
    end
  end
  identities
end

options = { manifest: File.join(ROOT, 'docs/lowering/identities.tsv') }
OptionParser.new { |parser| parser.on('--manifest PATH', 'test-only alternate manifest') { |path| options[:manifest] = path } }.parse!
manifest = File.expand_path(options[:manifest])
default_manifest = File.join(ROOT, 'docs/lowering/identities.tsv')
fail!('manifest must be the checked-in file or a /tmp tamper copy') unless manifest == default_manifest || manifest.start_with?(File.join(Dir.tmpdir, ''))

seen_ids = {}
rows = data_lines(manifest).map.with_index(1) do |line, number|
  fields = line.split("\t", -1)
  fail!("manifest row #{number} has #{fields.length} fields, expected 5") unless fields.length == 5
  id, source, kind, count, digest = fields
  fail!("manifest id #{id.inspect} is unsafe") unless id.match?(%r{\A[a-z][a-z0-9-]*\z})
  fail!("duplicate manifest id #{id}") if seen_ids[id]
  seen_ids[id] = true
  fail!("manifest source #{source} is not approved") unless SOURCES.key?(source)
  fail!("manifest kind #{kind} is invalid") unless KINDS.include?(kind)
  fail!("manifest row #{id} has a deferred state") if line.match?(/planned|skip|n\/a/i)
  fail!("manifest count for #{id} is not positive") unless count.match?(/\A[1-9][0-9]*\z/)
  fail!("manifest digest for #{id} is not sha256") unless digest.match?(/\A[0-9a-f]{64}\z/)
  [id, source, kind, count.to_i, digest]
end
fail!('manifest has zero rows') if rows.empty?
fail!('manifest ids must be strictly sorted') unless rows.map(&:first) == rows.map(&:first).sort
fail!('manifest groups differ from the complete public boundary') unless rows.to_h { |id, source, kind, *_| [id, [source, kind]] } == REQUIRED_GROUPS

rows.each do |id, source, kind, expected_count, expected_digest|
  identities = kind == 'bashsharp-runtime' ? bashsharp_lowering(ROOT) : first_column(ROOT, source)
  fail!("#{id} has zero identities") if identities.empty?
  fail!("#{id} identities are duplicated") unless identities.uniq.length == identities.length
  actual_digest = Digest::SHA256.hexdigest(identities.join("\n") + "\n")
  fail!("#{id} count #{identities.length}, expected #{expected_count}") unless identities.length == expected_count
  fail!("#{id} identity digest #{actual_digest}, expected #{expected_digest}") unless actual_digest == expected_digest
  puts "IDENTITY PASS #{id}: #{identities.length} #{actual_digest}"
end
puts "IDENTITY MANIFEST PASS: #{rows.length} groups, #{rows.sum { |row| row[3] }} identities"
