# frozen_string_literal: true
# Sprint: #148; Story: #35; Story-ID: 5a5238d8b07c

require 'digest'
require 'json'
require ENV.fetch('GO_FULL_CORPUS_LIB', File.expand_path('../corpus/executor.rb', __dir__))
require_relative '../corpus/validate'
require_relative 'subset'

# Authenticates the immutable Sprint 142 leaf-packet index and every manifest
# it names. Mutable execution inputs are deliberately not invented as v4
# fields: they live in a separately reviewed projection whose digest is supplied
# independently by the caller.
module GoFullPacketManifest
  INDEX_SCHEMA = 'sprint142-leaf-packet-index/v4'
  MANIFEST_SCHEMA = 'sprint142-leaf-packet-manifest/v4'
  CAUSAL_SCHEMA = 'sprint142-final-causal-failure-partition/v2'
  PROJECTION_SCHEMA = 'go-full-reviewed-packet-projection/v1'
  RESULT_SCHEMA = 'go-full-packet-result/v1'
  CLAIM_SCOPE = 'exact selected failure roots only; no corpus verdict'
  INDEX_KEYS = %w[assigned_failure_root_count causal_partition created_at packets partition_is_disjoint_and_complete schema].freeze
  INDEX_PACKET_KEYS = %w[count ids manifest_path manifest_sha256 packet root_list_sha256].freeze
  MANIFEST_KEYS = %w[causal_partition_sha256 claim_scope count created_at ids packet root_list schema].freeze
  ROOT_LIST_KEYS = %w[bytes path sha256].freeze
  PROJECTION_KEYS = %w[attempt candidate claim_scope count evidence ids index_sha256 inventory packet runner schema selected_manifest_sha256].freeze
  OFFICIAL_ROOTS = GoFullSubset::OFFICIAL_ROOTS
  FAILURE_ROOTS = 1682
  PACKETS = 49
  PUBLISHED_INDEX_SHA256 = '6e28c53bd3bfddfbfeeb4d88ac6ad76c62f60051772f8940416b497185319f2d'
  PACKET_148_7_SHA256 = 'ec25a4165835a22f288a99d76713bafee46eddce0c8b5a53cd35de6215ce4574'
  SHA256 = /\A[0-9a-f]{64}\z/.freeze
  PACKET = /\A[0-9]+\.[0-9]+\z/.freeze
  ATTEMPT = /\A[a-z0-9][a-z0-9._-]{0,127}\z/.freeze
  CORPUS_SUMMARY_FIELDS = GoFullSubset::CORPUS_SUMMARY_FIELDS

  module_function

  def digest_bytes(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def strict_json(path)
    JSON.parse(File.binread(path))
  rescue Errno::ENOENT, JSON::ParserError => error
    raise Corpus::ContractError, "invalid packet artifact: #{error.message}"
  end

  def exact_keys!(object, keys, label)
    raise Corpus::ContractError, "#{label} is not an object" unless object.is_a?(Hash)
    raise Corpus::ContractError, "unknown or missing #{label} fields" unless object.keys.sort == keys.sort
  end

  def digest!(value, label)
    raise Corpus::ContractError, "invalid #{label} SHA-256" unless value.is_a?(String) && value.match?(SHA256)
    value
  end

  def packet!(value)
    raise Corpus::ContractError, 'invalid packet identifier' unless value.is_a?(String) && value.match?(PACKET)
    value
  end

  def unsymlinked_file!(path, expected_parent:, expected_name:)
    expanded = File.expand_path(path)
    unless File.dirname(expanded) == expected_parent && File.basename(expanded) == expected_name
      raise Corpus::ContractError, 'packet artifact path escaped its canonical directory'
    end
    canonical_parent = GoFullSubset.canonical_path(expected_parent)
    unless !File.symlink?(expanded) && GoFullSubset.canonical_path(expanded) == File.join(canonical_parent, expected_name)
      raise Corpus::ContractError, 'packet artifact path contains a symlink escape'
    end
    expanded
  end

  def file_record!(path, expected = nil, label: 'file')
    record = Corpus.file_record(path)
    digest!(record.fetch('sha256'), label)
    raise Corpus::ContractError, "#{label} changed" if expected && record.fetch('sha256') != expected
    record
  rescue Errno::ENOENT => error
    raise Corpus::ContractError, "missing #{label}: #{error.message}"
  end

  def read_root_list!(record, ids, manifest_dir, packet)
    exact_keys!(record, ROOT_LIST_KEYS, 'root-list')
    path = unsymlinked_file!(record.fetch('path'), expected_parent: manifest_dir,
      expected_name: "packet-#{packet}.roots.txt")
    bytes = File.binread(path)
    expected = ids.map { |id| "#{id}\n" }.join
    raise Corpus::ContractError, 'root-list bytes differ from manifest IDs' unless bytes == expected
    raise Corpus::ContractError, 'root-list byte count differs' unless record.fetch('bytes') == bytes.bytesize
    unless digest!(record.fetch('sha256'), 'root-list') == digest_bytes(bytes)
      raise Corpus::ContractError, 'root-list digest differs'
    end
    file_record!(path)
  rescue Errno::ENOENT, KeyError, TypeError => error
    raise Corpus::ContractError, "invalid root-list: #{error.message}"
  end

  def read_manifest!(index_row, index_dir, created_at, causal_sha256)
    exact_keys!(index_row, INDEX_PACKET_KEYS, 'packet index row')
    packet = packet!(index_row.fetch('packet'))
    manifest_dir = File.join(index_dir, 'packet-manifests-v4')
    path = unsymlinked_file!(index_row.fetch('manifest_path'), expected_parent: manifest_dir,
      expected_name: "packet-#{packet}.json")
    manifest_record = file_record!(path, digest!(index_row.fetch('manifest_sha256'), 'manifest'), label: 'manifest')
    manifest = strict_json(path)
    allowed = MANIFEST_KEYS + (manifest.key?('mechanism_only_contract') ? ['mechanism_only_contract'] : [])
    exact_keys!(manifest, allowed, 'packet manifest')
    raise Corpus::ContractError, 'invalid packet manifest schema' unless manifest.fetch('schema') == MANIFEST_SCHEMA
    raise Corpus::ContractError, 'packet manifest identity differs from index' unless manifest.fetch('packet') == packet
    raise Corpus::ContractError, 'packet manifest creation time differs from index' unless manifest.fetch('created_at') == created_at
    raise Corpus::ContractError, 'packet manifest causal partition differs' unless manifest.fetch('causal_partition_sha256') == causal_sha256
    raise Corpus::ContractError, 'packet manifest attempted a corpus verdict' unless manifest.fetch('claim_scope') == CLAIM_SCOPE
    ids = manifest.fetch('ids')
    count = manifest.fetch('count')
    unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && !id.empty? } && ids == ids.sort && ids.uniq == ids
      raise Corpus::ContractError, 'packet IDs must be sorted unique strings'
    end
    raise Corpus::ContractError, 'packet count differs from IDs' unless count.is_a?(Integer) && count >= 0 && count == ids.length
    unless index_row.fetch('ids') == ids && index_row.fetch('count') == count
      raise Corpus::ContractError, 'packet index IDs or count differ from manifest'
    end
    mechanism = manifest['mechanism_only_contract']
    if mechanism && (!mechanism.is_a?(String) || mechanism.empty? || count != 0)
      raise Corpus::ContractError, 'only an empty packet may name a mechanism-only contract'
    end
    raise Corpus::ContractError, 'empty packet lacks its mechanism-only contract' if count.zero? && !mechanism
    root_list = read_root_list!(manifest.fetch('root_list'), ids, manifest_dir, packet)
    unless index_row.fetch('root_list_sha256') == root_list.fetch('sha256')
      raise Corpus::ContractError, 'index root-list digest differs from manifest'
    end
    { 'packet' => packet, 'ids' => ids, 'count' => count, 'mechanism_only_contract' => mechanism,
      'manifest' => manifest_record, 'root_list' => root_list }
  rescue KeyError, TypeError => error
    raise Corpus::ContractError, "invalid packet manifest: #{error.message}"
  end

  def authenticate_index(path:, expected_sha256:, causal_partition_path:)
    digest!(expected_sha256, 'packet index')
    index_record = file_record!(path, expected_sha256, label: 'packet index')
    index = strict_json(path)
    exact_keys!(index, INDEX_KEYS, 'packet index')
    raise Corpus::ContractError, 'invalid packet index schema' unless index.fetch('schema') == INDEX_SCHEMA
    unless index.fetch('partition_is_disjoint_and_complete') == true
      raise Corpus::ContractError, 'packet index does not assert a complete disjoint partition'
    end
    unless index.fetch('assigned_failure_root_count') == FAILURE_ROOTS
      raise Corpus::ContractError, 'packet index failure denominator differs'
    end

    index_dir = File.dirname(File.expand_path(path))
    causal_meta = index.fetch('causal_partition')
    exact_keys!(causal_meta, ROOT_LIST_KEYS, 'causal partition record')
    causal_path = unsymlinked_file!(causal_meta.fetch('path'), expected_parent: index_dir,
      expected_name: 'final-causal-v2.json')
    unless File.expand_path(causal_partition_path) == causal_path
      raise Corpus::ContractError, 'caller supplied a different causal partition'
    end
    causal_record = file_record!(causal_path, digest!(causal_meta.fetch('sha256'), 'causal partition'), label: 'causal partition')
    raise Corpus::ContractError, 'causal partition byte count differs' unless causal_meta.fetch('bytes') == causal_record.fetch('bytes')
    causal = strict_json(causal_path)
    assignments = causal.fetch('root_assignments')
    unless causal.fetch('schema') == CAUSAL_SCHEMA &&
           causal.fetch('failure_partition_is_disjoint_and_complete') == true &&
           causal.fetch('sealed_root_count') == OFFICIAL_ROOTS &&
           causal.fetch('failure_root_count') == FAILURE_ROOTS && assignments.length == FAILURE_ROOTS
      raise Corpus::ContractError, 'causal failure denominator differs'
    end
    causal_ids = assignments.map { |row| row.fetch('id') }
    unless causal_ids.all? { |id| id.is_a?(String) && !id.empty? }
      raise Corpus::ContractError, 'causal partition IDs must be strings'
    end
    raise Corpus::ContractError, 'causal partition IDs are not unique' unless causal_ids.uniq.length == FAILURE_ROOTS
    unless causal_ids.map(&:downcase).uniq.length == FAILURE_ROOTS
      raise Corpus::ContractError, 'causal partition has case-fold-colliding IDs'
    end

    rows = index.fetch('packets')
    unless rows.is_a?(Array) && rows.length == PACKETS
      raise Corpus::ContractError, 'packet index row count differs'
    end
    packets = rows.map { |row| read_manifest!(row, index_dir, index.fetch('created_at'), causal_record.fetch('sha256')) }
    packet_names = packets.map { |row| row.fetch('packet') }
    sorted_names = packet_names.sort_by { |name| name.split('.').map(&:to_i) }
    unless packet_names == sorted_names && packet_names.uniq == packet_names
      raise Corpus::ContractError, 'packet rows are not numerically sorted and unique'
    end
    ids = packets.flat_map { |row| row.fetch('ids') }
    raise Corpus::ContractError, 'packet partition contains overlap' unless ids.uniq.length == ids.length
    unless ids.map(&:downcase).uniq.length == ids.length
      raise Corpus::ContractError, 'packet partition contains case-fold-colliding IDs'
    end
    unless ids.length == FAILURE_ROOTS && ids.sort == causal_ids.sort
      raise Corpus::ContractError, 'packet partition omits or adds causal failure IDs'
    end
    { 'index' => index_record, 'causal_partition' => causal_record, 'packets' => packets }
  rescue KeyError, TypeError => error
    raise Corpus::ContractError, "invalid packet index: #{error.message}"
  end

  def binding(paths, label)
    records = Array(paths).map { |path| file_record!(path, nil, label: label) }
    canonical = records.map { |record| [File.expand_path(record.fetch('path')), record] }.sort_by(&:first)
    unless canonical.map(&:first).uniq.length == canonical.length
      raise Corpus::ContractError, "duplicate #{label} path"
    end
    { 'files' => canonical.map(&:last), 'sha256' => digest_bytes(Corpus.canonical(canonical.map(&:last))) }
  end

  def projection(selection:, attempt:, evidence:, inventory_paths:, runner_paths:, candidate_path:)
    unless attempt.is_a?(String) && attempt.match?(ATTEMPT) &&
           !attempt.start_with?('product-all-', 'native-', 'full-')
      raise Corpus::ContractError, 'invalid packet attempt identifier'
    end
    inventory = binding(inventory_paths, 'inventory').merge(
      'root_ids_sha256' => selection.fetch('inventory_root_ids_sha256'))
    {
      'schema' => PROJECTION_SCHEMA, 'packet' => selection.fetch('packet'), 'attempt' => attempt,
      'claim_scope' => CLAIM_SCOPE, 'count' => selection.fetch('count'), 'ids' => selection.fetch('ids'),
      'index_sha256' => selection.dig('index', 'sha256'),
      'selected_manifest_sha256' => selection.dig('manifest', 'sha256'),
      'inventory' => inventory, 'runner' => binding(runner_paths, 'runner'),
      'candidate' => file_record!(candidate_path, nil, label: 'candidate'), 'evidence' => File.expand_path(evidence)
    }
  end

  def select(catalog, packet, roots, expected_manifest_sha256:)
    packet!(packet)
    digest!(expected_manifest_sha256, 'selected manifest')
    row = catalog.fetch('packets').find { |candidate| candidate.fetch('packet') == packet }
    raise Corpus::ContractError, 'packet is absent from authenticated index' unless row
    unless row.dig('manifest', 'sha256') == expected_manifest_sha256
      raise Corpus::ContractError, 'selected manifest differs from independently reviewed digest'
    end
    raise Corpus::ContractError, 'complete official inventory is required' unless roots.length == OFFICIAL_ROOTS
    by_id = roots.to_h { |root| [root.fetch('id'), root] }
    raise Corpus::ContractError, 'official inventory contains duplicate IDs' unless by_id.length == OFFICIAL_ROOTS
    unless by_id.keys.map(&:downcase).uniq.length == OFFICIAL_ROOTS
      raise Corpus::ContractError, 'official inventory has case-fold-colliding IDs'
    end
    missing = row.fetch('ids').reject { |id| by_id.key?(id) }
    unless missing.empty?
      raise Corpus::ContractError, "packet ID absent from official inventory: #{missing.first}"
    end
    inventory_root_ids_sha256 = digest_bytes(Corpus.canonical(roots.map { |root| root.fetch('id') }))
    row.merge('index' => catalog.fetch('index'), 'causal_partition' => catalog.fetch('causal_partition'),
      'inventory_root_ids_sha256' => inventory_root_ids_sha256,
      'inventory_root_ids' => roots.map { |root| root.fetch('id') },
      'roots' => row.fetch('ids').map { |id| by_id.fetch(id) })
  rescue KeyError, TypeError => error
    raise Corpus::ContractError, "invalid packet selection: #{error.message}"
  end

  def protected_evidence_path!(evidence, attempt, protected_roots)
    evidence = File.expand_path(evidence)
    raise Corpus::ContractError, 'packet evidence name differs from reviewed attempt' unless File.basename(evidence) == attempt
    canonical = GoFullSubset.canonical_path(evidence)
    Array(protected_roots).each do |root|
      [File.expand_path(root), GoFullSubset.canonical_path(root)].uniq.each do |root_form|
        [evidence, canonical].uniq.each do |evidence_form|
          if GoFullSubset.overlapping?(evidence_form, root_form) ||
             GoFullSubset.filesystem_overlapping?(evidence_form, root_form)
            raise Corpus::ContractError, 'packet evidence overlaps a protected evidence root'
          end
        end
      end
    end
    evidence
  end

  def authenticate_projection(path:, expected_sha256:, selection:, inventory_paths:, runner_paths:,
                              candidate_path:, evidence:, protected_roots: [], used_receipts: [], prepare: true)
    projection_record = file_record!(path, digest!(expected_sha256, 'projection'), label: 'projection')
    reviewed = strict_json(path)
    exact_keys!(reviewed, PROJECTION_KEYS, 'reviewed projection')
    live = projection(selection: selection, attempt: reviewed.fetch('attempt'), evidence: evidence,
      inventory_paths: inventory_paths, runner_paths: runner_paths, candidate_path: candidate_path)
    unless reviewed == live
      raise Corpus::ContractError, 'reviewed projection is stale or binds different execution inputs'
    end
    protected_evidence_path!(evidence, reviewed.fetch('attempt'), protected_roots)
    raise Corpus::ContractError, 'packet evidence already exists' if prepare && File.exist?(evidence)
    evidence_canonical = GoFullSubset.canonical_path(evidence)
    used_receipts.each do |receipt_path|
      receipt = strict_json(receipt_path)
      next unless receipt.is_a?(Hash)
      reused_projection = receipt['projection_sha256'] == projection_record.fetch('sha256')
      reused_attempt = receipt['attempt'] == reviewed.fetch('attempt')
      reused_evidence = receipt['evidence'] && GoFullSubset.canonical_path(receipt['evidence']) == evidence_canonical
      if reused_projection || reused_attempt || reused_evidence
        raise Corpus::ContractError, 'packet attempt or evidence was already used'
      end
    end
    live.merge('projection' => projection_record, 'index' => selection.fetch('index'),
      'inventory_root_ids' => selection.fetch('inventory_root_ids'), 'roots' => selection.fetch('roots'),
      'manifest' => selection.fetch('manifest'), 'root_list' => selection.fetch('root_list'),
      'causal_partition' => selection.fetch('causal_partition'))
  end

  def reauthenticate!(selection)
    %w[projection index manifest root_list causal_partition candidate].each do |key|
      Corpus::Validation.file!(selection.fetch(key))
    end
    %w[inventory runner].each do |key|
      selection.fetch(key).fetch('files').each { |record| Corpus::Validation.file!(record) }
    end
    current_root_ids = selection.fetch('inventory_root_ids')
    unless selection.fetch('inventory').fetch('root_ids_sha256') == digest_bytes(Corpus.canonical(current_root_ids))
      raise Corpus::ContractError, 'official inventory selection changed'
    end
    true
  end

  def summary(selection, rows, common = {})
    forbidden = common.keys & CORPUS_SUMMARY_FIELDS
    unless forbidden.empty?
      raise Corpus::ContractError, 'packet summary attempted corpus fields: ' + forbidden.sort.join(', ')
    end
    ids = rows.map { |row| row.fetch('id') }
    unless ids == selection.fetch('ids') && ids.length == selection.fetch('count')
      raise Corpus::ContractError, 'packet result IDs differ from authenticated selection'
    end
    reauthenticate!(selection)
    common.merge('schema' => RESULT_SCHEMA, 'scope' => 'packet-only', 'claim_scope' => CLAIM_SCOPE,
      'packet' => selection.fetch('packet'), 'attempt' => selection.fetch('attempt'), 'corpus_credit' => false,
      'selected_root_count' => ids.length, 'selected_root_ids' => ids,
      'projection' => selection.fetch('projection'))
  end
end
