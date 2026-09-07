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
  'tests/tour/inventory.tsv' => :first_column,
  'docs/lowering/ast_api.tsv' => :ast_api,
  'docs/lowering/runtime_obligations.tsv' => :runtime_obligations
}.freeze
KINDS = %w[agentic-boundary ast-api bashsharp-family bashsharp-runtime certified-node public-profile public-corpus runtime-obligation].freeze
REQUIRED_GROUPS = {
  'agentic-boundaries' => ['tests/agentic/cases.tsv', 'agentic-boundary'],
  'bashsharp-families' => ['tests/bashsharp/matrix.tsv', 'bashsharp-family'],
  'bashsharp-lowering' => ['tests/bashsharp/matrix.tsv', 'bashsharp-runtime'],
  'certified-startsites' => ['tools/startsites/baseline.tsv', 'certified-node'],
  'go-profile-fixtures' => ['tests/manifest.tsv', 'public-profile'],
  'official-go-corpus' => ['docs/go-corpus/inventory.tsv', 'public-corpus'],
  'public-ast-api' => ['docs/lowering/ast_api.tsv', 'ast-api'],
  'public-go-by-example' => ['docs/go-by-example/inventory.tsv', 'public-corpus'],
  'public-go-tour' => ['tests/tour/inventory.tsv', 'public-corpus'],
  'runtime-obligations' => ['docs/lowering/runtime_obligations.tsv', 'runtime-obligation']
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

AST_NODES = %w[
  BashPPDecl BashPPConstGroup BashPPConstSpec BashPPAssign BashPPShortDecl
  BashPPBasicLit BashPPIdent BashPPTypeAssertExpr BashPPParenExpr BashPPUnaryExpr
  BashPPAddressExpr BashPPDerefExpr BashPPNewExpr BashPPBinaryExpr BashPPConvertExpr
  BashPPIndexExpr BashPPSliceExpr BashPPSelectorExpr BashPPFuncType BashPPNamedType BashPPTypeParamType
  BashPPUnionType BashPPApproxType BashPPPointerType BashPPCollectionType BashPPStructType
  BashPPInterfaceType BashPPInterfaceElem BashPPMethodSpec BashPPCompositeLit BashPPCompositeElem
  BashPPCall BashPPCommandCall BashPPImport BashPPImportSpec BashPPIf BashPPFor
  BashPPForAssign BashPPIncDec BashPPUpdate BashPPBranch BashPPSwitch BashPPSwitchArm
  BashPPField BashPPTypeParam BashPPTypeArg BashPPFuncDecl BashPPReceiver BashPPFuncLit
  BashPPReturn BashPPDefer BashPPGo BashPPChanType BashPPMakeChan BashPPSend BashPPReceive
  BashPPClose BashPPSelect BashPPSelectCase BashPPRange BashPPAgenticBlock FuncDecl[Agentic]
].freeze
EXPR_VARIANTS = %w[BashPPBasicLit BashPPIdent BashPPParenExpr BashPPUnaryExpr BashPPBinaryExpr BashPPConvertExpr BashPPIndexExpr BashPPSliceExpr BashPPSelectorExpr BashPPCompositeLit BashPPAddressExpr BashPPDerefExpr BashPPNewExpr BashPPTypeAssertExpr BashPPCall].freeze
TYPE_VARIANTS = %w[BashPPFuncType BashPPChanType BashPPNamedType BashPPCollectionType BashPPStructType BashPPPointerType BashPPInterfaceType BashPPTypeParamType BashPPUnionType BashPPApproxType].freeze
START_SITE_VARIANTS = %w[none var const type := call if import func defer return funclit go select agentic].freeze
RUNTIME_OBLIGATIONS = %w[
  status.exit-status types.values-and-zero effects.cwd-env-filesystem
  errors.streams-and-diagnostics cancellation.signal-context-timeout
  concurrency.goroutine-channel-order
].freeze

AST_FIELD_EDGES = %w[edge:BashPPReturn:Call edge:BashPPReturn:Expr edge:BashPPCall:ArgExprs edge:BashPPChanType:Element].freeze

def ast_api(root, source = File.join(root, 'docs/lowering/ast_api.tsv'))
  rows = data_lines(source).map { |line| line.split("\t", -1) }
  fail!('AST API row must have exactly three fields') unless rows.all? { |row| row.length == 3 && row.all? { |field| !field.empty? } }
  node_names = rows.select { |row| row[1] == 'node' }.map { |row| row[0].delete_prefix('node:') }
  fail!('AST API nodes are not the complete 60 Bash++ structs plus agentic block and marked FuncDecl') unless node_names == AST_NODES
  classes = %w[node expr-variant type-variant start-site site-class field-edge]
  fail!('AST API has an unknown identity class') unless rows.all? { |row| classes.include?(row[1]) }
  rows.each do |identity, klass, source_path|
    expected_source = case identity
                      when 'node:BashPPAgenticBlock' then 'syntax/bashpp_agentic.go'
                      when 'node:FuncDecl[Agentic]' then 'syntax/nodes.go'
                      else 'syntax/bashpp_nodes.go'
                      end
    fail!("AST API declaring source differs for #{identity}") unless source_path == expected_source
  end
  variants = rows.reject { |row| %w[node field-edge].include?(row[1]) }.map(&:first)
  expected = EXPR_VARIANTS.map { |name| "variant:BashPPExpr:#{name}" } +
    TYPE_VARIANTS.map { |name| "variant:BashPPTypeExpr:#{name}" } +
    START_SITE_VARIANTS.map { |name| "variant:StartSite:#{name}" } +
    %w[variant:SiteClass:R variant:SiteClass:E]
  fail!('AST API significant variants differ from the declared public variants') unless variants == expected
  variant_classes = EXPR_VARIANTS.map { 'expr-variant' } + TYPE_VARIANTS.map { 'type-variant' } +
    START_SITE_VARIANTS.map { 'start-site' } + %w[site-class site-class]
  actual_classes = rows.reject { |row| %w[node field-edge].include?(row[1]) }.map { |row| row[1] }
  fail!('AST API variant classes differ from the declared public variants') unless actual_classes == variant_classes
  edges = rows.select { |row| row[1] == 'field-edge' }.map(&:first)
  fail!('AST API field edges differ from the declared public edges') unless edges == AST_FIELD_EDGES
  rows.map(&:first)
end

def runtime_obligations(root)
  rows = data_lines(File.join(root, 'docs/lowering/runtime_obligations.tsv')).map { |line| line.split("\t", -1) }
  fail!('runtime obligation row must have exactly five populated fields') unless rows.all? { |row| row.length == 5 && row.all? { |field| !field.empty? } }
  identities = rows.map(&:first)
  fail!('runtime obligation identities differ from the contract') unless identities == RUNTIME_OBLIGATIONS
  identities
end

options = { manifest: File.join(ROOT, 'docs/lowering/identities.tsv'), ast_api: File.join(ROOT, 'docs/lowering/ast_api.tsv') }
OptionParser.new do |parser|
  parser.on('--manifest PATH', 'test-only alternate manifest') { |path| options[:manifest] = path }
  parser.on('--ast-api PATH', 'test-only alternate AST inventory') { |path| options[:ast_api] = path }
end.parse!
manifest = File.expand_path(options[:manifest])
default_manifest = File.join(ROOT, 'docs/lowering/identities.tsv')
fail!('manifest must be the checked-in file or a /tmp tamper copy') unless manifest == default_manifest || manifest.start_with?(File.join(Dir.tmpdir, ''))

ast_source = File.expand_path(options[:ast_api])
fail!('AST inventory must be the checked-in file or a temporary tamper copy') unless
  ast_source == File.join(ROOT, 'docs/lowering/ast_api.tsv') || ast_source.start_with?(File.join(Dir.tmpdir, ''))

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
  identities = case kind
               when 'bashsharp-runtime' then bashsharp_lowering(ROOT)
               when 'ast-api' then ast_api(ROOT, ast_source)
               when 'runtime-obligation' then runtime_obligations(ROOT)
               else first_column(ROOT, source)
               end
  fail!("#{id} has zero identities") if identities.empty?
  fail!("#{id} identities are duplicated") unless identities.uniq.length == identities.length
  actual_digest = Digest::SHA256.hexdigest(identities.join("\n") + "\n")
  fail!("#{id} count #{identities.length}, expected #{expected_count}") unless identities.length == expected_count
  fail!("#{id} identity digest #{actual_digest}, expected #{expected_digest}") unless actual_digest == expected_digest
  puts "IDENTITY PASS #{id}: #{identities.length} #{actual_digest}"
end
puts "IDENTITY MANIFEST PASS: #{rows.length} groups, #{rows.sum { |row| row[3] }} identities"
