# frozen_string_literal: true
# Sprint: #148; Story: #35; Story-ID: 5a5238d8b07c

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/go-full/packet_manifest'

class GoFullPacketManifestTest < Minitest::Test
  PACKET_NAMES = %w[148.1 148.2 148.3 148.4 148.5 148.6 148.7
                    149.1 149.2 149.3 149.4 149.5 149.6 149.7 149.8 149.9 149.10
                    150.1 150.2 150.3 150.4 150.5 150.6 150.7 150.8
                    151.1 151.2 151.3 151.4 151.5 152.1 152.2 152.3 152.4
                    153.1 153.2 153.3 153.4 153.5 153.6 154.1 154.2 154.3
                    155.1 155.2 155.3 155.4 155.5 155.6].freeze

  def setup
    @tmp = Dir.mktmpdir('go-full-packet-v4-')
    @control = File.join(@tmp, 'control')
    @manifest_dir = File.join(@control, 'packet-manifests-v4')
    FileUtils.mkdir_p(@manifest_dir)
    @causal = File.join(@control, 'final-causal-v2.json')
    @index = File.join(@control, 'packet-index-v4.json')
    @candidate = write_file('candidate.json', "candidate\n")
    @inventory_file = write_file('inventory.jsonl', "inventory\n")
    @runner = write_file('runner.rb', "runner\n")
    @projection = File.join(@tmp, 'projection.json')
    @evidence = File.join(@tmp, 'evidence', 'packet-148.7-attempt-001')
    @all_failure_ids = Array.new(GoFullPacketManifest::FAILURE_ROOTS) { |i| format('root:%04d', i) }
    @roots = Array.new(GoFullPacketManifest::OFFICIAL_ROOTS) { |i| { 'id' => format('root:%04d', i), 'axis' => 'testdir' } }
    build_v4
    authenticate
    write_projection
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_file(name, bytes)
    path = File.join(@tmp, name)
    File.binwrite(path, bytes)
    path
  end

  def canonical_write(path, object)
    File.binwrite(path, Corpus.canonical(object) + "\n")
  end

  def packet_ids
    # Keep 148.7 mechanism-only while exercising all 49 real packet names.
    assigned = {}
    cursor = 0
    PACKET_NAMES.each do |name|
      if name == '148.7'
        assigned[name] = []
      else
        assigned[name] = [@all_failure_ids.fetch(cursor)]
        cursor += 1
      end
    end
    assigned['149.1'].concat(@all_failure_ids.drop(cursor))
    assigned.transform_values(&:sort)
  end

  def build_v4(ids_by_packet: packet_ids, causal_ids: @all_failure_ids, scope: GoFullPacketManifest::CLAIM_SCOPE)
    causal = { 'schema' => GoFullPacketManifest::CAUSAL_SCHEMA,
               'failure_partition_is_disjoint_and_complete' => true,
               'sealed_root_count' => GoFullPacketManifest::OFFICIAL_ROOTS,
               'failure_root_count' => causal_ids.length,
               'root_assignments' => causal_ids.map { |id| { 'id' => id } } }
    canonical_write(@causal, causal)
    causal_record = Corpus.file_record(@causal)
    created_at = '2026-09-10T19:55:47.130701+00:00'
    rows = PACKET_NAMES.map do |name|
      ids = ids_by_packet.fetch(name)
      roots_path = File.join(@manifest_dir, "packet-#{name}.roots.txt")
      File.binwrite(roots_path, ids.map { |id| "#{id}\n" }.join)
      root_record = Corpus.file_record(roots_path)
      manifest = { 'schema' => GoFullPacketManifest::MANIFEST_SCHEMA, 'packet' => name,
        'created_at' => created_at, 'causal_partition_sha256' => causal_record.fetch('sha256'),
        'count' => ids.length, 'ids' => ids,
        'root_list' => root_record, 'claim_scope' => scope }
      manifest['mechanism_only_contract'] = "fixture-contract-#{name}" if ids.empty?
      manifest_path = File.join(@manifest_dir, "packet-#{name}.json")
      canonical_write(manifest_path, manifest)
      { 'packet' => name, 'count' => ids.length, 'ids' => ids,
        'root_list_sha256' => root_record.fetch('sha256'), 'manifest_path' => manifest_path,
        'manifest_sha256' => Corpus.digest(manifest_path) }
    end
    index = { 'schema' => GoFullPacketManifest::INDEX_SCHEMA, 'created_at' => created_at,
      'causal_partition' => causal_record, 'assigned_failure_root_count' => GoFullPacketManifest::FAILURE_ROOTS,
      'partition_is_disjoint_and_complete' => true, 'packets' => rows }
    canonical_write(@index, index)
  end

  def authenticate
    @catalog = GoFullPacketManifest.authenticate_index(path: @index,
      expected_sha256: Corpus.digest(@index), causal_partition_path: @causal)
    manifest_sha256 = @catalog.fetch('packets').find { |row| row.fetch('packet') == '148.7' }.dig('manifest', 'sha256')
    @selection = GoFullPacketManifest.select(@catalog, '148.7', @roots,
      expected_manifest_sha256: manifest_sha256)
  end

  def write_projection
    projection = GoFullPacketManifest.projection(selection: @selection,
      attempt: File.basename(@evidence), evidence: @evidence,
      inventory_paths: [@inventory_file], runner_paths: [@runner], candidate_path: @candidate)
    canonical_write(@projection, projection)
  end

  def authenticate_projection(**options)
    GoFullPacketManifest.authenticate_projection(path: @projection,
      expected_sha256: Corpus.digest(@projection), selection: @selection,
      inventory_paths: [@inventory_file], runner_paths: [@runner], candidate_path: @candidate,
      evidence: @evidence, **options)
  end

  def test_real_v4_schemas_and_published_hashes_are_pinned
    assert_equal 'sprint142-leaf-packet-index/v4', GoFullPacketManifest::INDEX_SCHEMA
    assert_equal 'sprint142-leaf-packet-manifest/v4', GoFullPacketManifest::MANIFEST_SCHEMA
    assert_equal 'exact selected failure roots only; no corpus verdict', GoFullPacketManifest::CLAIM_SCOPE
    assert_equal '6e28c53bd3bfddfbfeeb4d88ac6ad76c62f60051772f8940416b497185319f2d', GoFullPacketManifest::PUBLISHED_INDEX_SHA256
    assert_equal 'ec25a4165835a22f288a99d76713bafee46eddce0c8b5a53cd35de6215ce4574', GoFullPacketManifest::PACKET_148_7_SHA256
  end

  def test_authenticates_complete_index_all_manifests_and_mechanism_packet
    assert_equal 49, @catalog.fetch('packets').length
    assert_equal GoFullPacketManifest::FAILURE_ROOTS, @catalog.fetch('packets').sum { |row| row.fetch('count') }
    assert_equal [], @selection.fetch('ids')
    assert_equal 'fixture-contract-148.7', @selection.fetch('mechanism_only_contract')
    reviewed = authenticate_projection
    assert_equal Corpus.digest(@candidate), reviewed.dig('candidate', 'sha256')
    assert_equal false, File.exist?(@evidence)
    assert_raises(Corpus::ContractError) do
      GoFullPacketManifest.select(@catalog, '148.7', @roots, expected_manifest_sha256: '0' * 64)
    end
  end

  def test_manifest_root_list_and_index_mutation_fail_closed
    manifest = @catalog.fetch('packets').first.dig('manifest', 'path')
    File.open(manifest, 'ab') { |stream| stream.write(' ') }
    assert_raises(Corpus::ContractError) { authenticate }
    build_v4
    roots = File.join(@manifest_dir, 'packet-148.1.roots.txt')
    File.open(roots, 'ab') { |stream| stream.write("extra\n") }
    assert_raises(Corpus::ContractError) { authenticate }
    build_v4
    expected = Corpus.digest(@index)
    File.open(@index, 'ab') { |stream| stream.write(' ') }
    assert_raises(Corpus::ContractError) do
      GoFullPacketManifest.authenticate_index(path: @index, expected_sha256: expected, causal_partition_path: @causal)
    end
  end

  def test_overlap_omission_extra_and_case_fold_collision_fail_closed
    mappings = packet_ids
    mappings['148.1'] = [mappings['149.1'].first]
    assert_raises(Corpus::ContractError) { build_v4(ids_by_packet: mappings); authenticate }

    mappings = packet_ids
    omitted = mappings['149.1'].pop
    assert_raises(Corpus::ContractError) { build_v4(ids_by_packet: mappings); authenticate }

    mappings = packet_ids
    mappings['149.1'] << 'root:extra'
    assert_raises(Corpus::ContractError) { build_v4(ids_by_packet: mappings); authenticate }

    causal = @all_failure_ids.dup
    causal[-1] = causal.first.upcase
    mappings = packet_ids
    mappings.each_value { |ids| ids.map! { |id| id == @all_failure_ids.last ? causal.last : id } }
    assert_raises(Corpus::ContractError) { build_v4(ids_by_packet: mappings, causal_ids: causal); authenticate }
    assert omitted
  end

  def test_scope_packet_identity_and_symlink_escape_fail_closed
    build_v4(scope: 'all failures PASS')
    assert_raises(Corpus::ContractError) { authenticate }
    build_v4
    index = JSON.parse(File.read(@index))
    index.fetch('packets').first['packet'] = '148.2'
    canonical_write(@index, index)
    assert_raises(Corpus::ContractError) { authenticate }

    build_v4
    target = File.join(@tmp, 'outside.json')
    FileUtils.mv(File.join(@manifest_dir, 'packet-148.1.json'), target)
    File.symlink(target, File.join(@manifest_dir, 'packet-148.1.json'))
    index = JSON.parse(File.read(@index))
    index.fetch('packets').first['manifest_sha256'] = Corpus.digest(target)
    canonical_write(@index, index)
    assert_raises(Corpus::ContractError) { authenticate }
  end

  def test_projection_rejects_stale_candidate_inventory_runner_and_self
    [@candidate, @inventory_file, @runner].each do |path|
      original = File.binread(path)
      File.open(path, 'ab') { |stream| stream.write('changed') }
      assert_raises(Corpus::ContractError) { authenticate_projection }
      File.binwrite(path, original)
    end
    expected = Corpus.digest(@projection)
    File.open(@projection, 'ab') { |stream| stream.write('changed') }
    assert_raises(Corpus::ContractError) do
      GoFullPacketManifest.authenticate_projection(path: @projection, expected_sha256: expected,
        selection: @selection, inventory_paths: [@inventory_file], runner_paths: [@runner],
        candidate_path: @candidate, evidence: @evidence)
    end
  end

  def test_protected_symlink_case_fold_and_existing_evidence_fail_closed
    protected = File.join(@tmp, 'protected')
    FileUtils.mkdir_p(protected)
    FileUtils.mkdir_p(File.dirname(@evidence))
    File.symlink(protected, @evidence)
    assert_raises(Corpus::ContractError) { authenticate_projection(protected_roots: [protected]) }
    File.unlink(@evidence)
    FileUtils.mkdir_p(@evidence)
    assert_raises(Corpus::ContractError) { authenticate_projection }

    return unless File.exist?(@tmp.upcase)
    FileUtils.remove_entry(@evidence)
    assert_raises(Corpus::ContractError) { authenticate_projection(protected_roots: [@evidence.upcase]) }
  end

  def test_used_projection_attempt_or_evidence_cannot_be_reused
    receipt = write_file('prior.json', Corpus.canonical({ 'projection_sha256' => Corpus.digest(@projection),
      'attempt' => 'different', 'evidence' => File.join(@tmp, 'other') }) + "\n")
    assert_raises(Corpus::ContractError) { authenticate_projection(used_receipts: [receipt]) }
  end

  def test_summary_is_selected_only_and_reauthenticates_every_binding
    selection = authenticate_projection
    summary = GoFullPacketManifest.summary(selection, [], 'source_integrity_after' => true)
    assert_equal false, summary.fetch('corpus_credit')
    assert_equal 'packet-only', summary.fetch('scope')
    assert_raises(Corpus::ContractError) { GoFullPacketManifest.summary(selection, [], 'verdict' => 'PASS') }
    File.open(@runner, 'ab') { |stream| stream.write('changed') }
    assert_raises(Corpus::ContractError) { GoFullPacketManifest.summary(selection, [], {}) }
  end
end
